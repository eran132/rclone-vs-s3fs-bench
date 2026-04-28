#!/usr/bin/env bash
# Phase-0 profiling harness for rclone.
#
# Re-mounts rclone with --rc enabled so /debug/pprof is exposed, then runs a
# named fio profile while capturing:
#   - CPU pprof    (30s sample)
#   - heap pprof   (post-run)
#   - strace -c    (syscall histogram of the rclone process)
#   - tcpdump      (packets to/from MinIO)
# Outputs to /lab/results/profiling/<profile>/
#
# Usage (from host):
#   docker compose exec bench /lab/scripts/profile.sh seq-write
#   docker compose exec bench /lab/scripts/profile.sh small-files
set -euo pipefail

PROFILE="${1:-seq-write}"
PROFILES_DIR=/lab/configs/fio
FIO_FILE="${PROFILES_DIR}/${PROFILE}.fio"
[[ -f "$FIO_FILE" ]] || { echo "no such profile: $PROFILE"; exit 2; }

OUT="/lab/results/profiling/${PROFILE}"
mkdir -p "$OUT"

: "${S3_ENDPOINT:?missing}"
: "${S3_BUCKET:?missing}"
RC_PORT=5572

# 1) clean slate: kill any prior rclone, unmount stale mount
echo "[profile] killing any prior rclone, unmounting any current rclone mount"
pkill -x rclone 2>/dev/null || true
if mountpoint -q /mnt/rclone; then
    fusermount3 -u /mnt/rclone 2>/dev/null || umount -l /mnt/rclone 2>/dev/null || true
fi
sleep 1

# Run rclone as a bash background job (NOT --daemon: --daemon races with --rc on bind).
echo "[profile] mounting rclone with --rc on :${RC_PORT}"
rclone mount "minio:${S3_BUCKET}" /mnt/rclone \
    --allow-other \
    --vfs-cache-mode writes \
    --rc --rc-no-auth --rc-addr "0.0.0.0:${RC_PORT}" \
    --log-file "${OUT}/rclone-mount.log" --log-level INFO &
RCLONE_PID=$!

# Wait for rc HTTP to come up (also confirms mount is alive)
for i in $(seq 1 60); do
    if curl -fsS "http://localhost:${RC_PORT}/debug/pprof/" >/dev/null 2>&1; then break; fi
    sleep 0.5
done

if ! curl -fsS "http://localhost:${RC_PORT}/debug/pprof/" >/dev/null 2>&1; then
    echo "[profile] rclone never came up. Mount log:"
    cat "${OUT}/rclone-mount.log"
    exit 3
fi
echo "[profile] rclone pid=${RCLONE_PID}"

# 2) start strace -c in background (will summarize when rclone exits OR we kill -2)
echo "[profile] starting strace -c on pid ${RCLONE_PID}"
strace -c -p "$RCLONE_PID" 2> "${OUT}/strace-summary.txt" &
STRACE_PID=$!

# 3) start tcpdump on the bench<->minio path (port 9000)
echo "[profile] starting tcpdump"
tcpdump -i any -w "${OUT}/minio.pcap" -s 96 'tcp port 9000' >/dev/null 2>&1 &
TCPDUMP_PID=$!

# 4) start CPU pprof capture (30 s) in background
echo "[profile] starting CPU pprof (30s)"
( curl -s -o "${OUT}/cpu.pprof" "http://localhost:${RC_PORT}/debug/pprof/profile?seconds=30" ) &
PPROF_PID=$!

# 5) drop caches, run the fio workload
echo "[profile] running fio profile: ${PROFILE}"
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# Pre-stage for seq-read
if [[ "$PROFILE" == "seq-read" ]]; then
    echo "[profile] staging 1G source for seq-read..."
    dd if=/dev/urandom of=/mnt/rclone/seq-read.bin bs=1M count=1024 status=none
    sync
fi

MNT=/mnt/rclone /usr/bin/time -v -o "${OUT}/fio.time" \
    fio "$FIO_FILE" --output-format=json --output="${OUT}/fio.json" || true

# 6) capture heap pprof immediately after run
echo "[profile] capturing heap pprof"
curl -s -o "${OUT}/heap.pprof" "http://localhost:${RC_PORT}/debug/pprof/heap" || true
curl -s -o "${OUT}/goroutine.txt" "http://localhost:${RC_PORT}/debug/pprof/goroutine?debug=1" || true

# 7) wait for the 30s CPU sample to finish
wait "$PPROF_PID" 2>/dev/null || true

# 8) stop strace (SIGINT -> it prints the summary)
kill -INT "$STRACE_PID" 2>/dev/null || true
wait "$STRACE_PID" 2>/dev/null || true

# 9) stop tcpdump
kill -INT "$TCPDUMP_PID" 2>/dev/null || true
wait "$TCPDUMP_PID" 2>/dev/null || true

# 10) render quick summaries (text top + svg) if go-tool pprof is present
if command -v go >/dev/null 2>&1; then
    echo "[profile] rendering pprof summaries"
    go tool pprof -text -cum -nodecount=30 "${OUT}/cpu.pprof" \
        > "${OUT}/cpu-top.txt" 2>/dev/null || true
    go tool pprof -text -cum -nodecount=30 "${OUT}/heap.pprof" \
        > "${OUT}/heap-top.txt" 2>/dev/null || true
    if command -v dot >/dev/null 2>&1; then
        go tool pprof -svg -output "${OUT}/cpu.svg" "${OUT}/cpu.pprof" 2>/dev/null || true
    fi
fi

# 11) one-line tcpdump summary
if [[ -s "${OUT}/minio.pcap" ]]; then
    pkts=$(tcpdump -r "${OUT}/minio.pcap" 2>/dev/null | wc -l)
    echo "tcpdump captured ${pkts} packets to/from MinIO" > "${OUT}/tcpdump-summary.txt"
fi

# 12) tear down rclone so the next iteration starts clean
echo "[profile] unmounting rclone"
fusermount3 -u /mnt/rclone 2>/dev/null || umount -l /mnt/rclone 2>/dev/null || true
kill "$RCLONE_PID" 2>/dev/null || true
wait "$RCLONE_PID" 2>/dev/null || true

echo "[profile] done. Outputs:"
ls -la "$OUT"
