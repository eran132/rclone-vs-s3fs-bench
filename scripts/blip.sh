#!/usr/bin/env bash
# Network-blip resilience probe. Starts a 2 GiB rclone copy (or s3fs cp)
# in the background, waits 5 s, then drops all packets to the backend port
# for 30 s using `tc netem`, then restores the link. Measures whether the
# transfer completes and how long total wall time was.
#
# Requires NET_ADMIN cap on bench container.
#
# Run from inside the bench container:
#   BACKEND=minio /lab/scripts/blip.sh rclone
#   BACKEND=minio /lab/scripts/blip.sh s3fs
set -euo pipefail

BACKEND="${BACKEND:-minio}"
TOOL="${1:-rclone}"
RESULTS="/lab/results/raw/${BACKEND}/blip"
mkdir -p "$RESULTS"

case "$BACKEND" in
    minio) BACKEND_PORT=9000 ;;
    ceph)  BACKEND_PORT=8080 ;;
    *) echo "unknown backend $BACKEND"; exit 2 ;;
esac

IFACE=eth0
SRC=/tmp/blip-src.bin
SIZE_MB=2048

echo "[blip] preparing 2 GiB local source"
[[ -s "$SRC" ]] && [[ "$(stat -c%s "$SRC")" == "$((SIZE_MB * 1024 * 1024))" ]] \
    || dd if=/dev/urandom of="$SRC" bs=1M count="$SIZE_MB" status=none

apply_block() {
    echo "[blip] BLOCKING port $BACKEND_PORT on $IFACE"
    tc qdisc add dev "$IFACE" root handle 1: prio 2>/dev/null
    tc filter add dev "$IFACE" parent 1: protocol ip prio 1 \
        u32 match ip dport "$BACKEND_PORT" 0xffff flowid 1:1 2>/dev/null
    tc qdisc add dev "$IFACE" parent 1:1 handle 10: netem loss 100% 2>/dev/null
}

clear_block() {
    echo "[blip] CLEARING tc qdisc"
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
}
trap clear_block EXIT

# Pre-clear in case of stale state
clear_block 2>/dev/null || true

case "$TOOL" in
    rclone)
        DEST="${BACKEND}:${S3_BUCKET}/blip-target.bin"
        rm -f /tmp/blip-rclone.log
        echo "[blip] starting rclone copy in background"
        ( /usr/bin/time -v -o "${RESULTS}/${TOOL}.time" \
            rclone copy "$SRC" "${BACKEND}:${S3_BUCKET}/" --no-check-dest \
                --log-file /tmp/blip-rclone.log --log-level INFO ) &
        WORKER=$!
        ;;
    s3fs)
        # s3fs has no separate "copy" subcommand; cp through the existing mount.
        mountpoint -q /mnt/s3fs || { echo "s3fs not mounted"; exit 3; }
        rm -f /mnt/s3fs/blip-target.bin
        echo "[blip] starting s3fs cp in background"
        ( /usr/bin/time -v -o "${RESULTS}/${TOOL}.time" \
            cp "$SRC" /mnt/s3fs/blip-target.bin ) &
        WORKER=$!
        ;;
    *) echo "TOOL must be rclone or s3fs"; exit 2 ;;
esac

# Schedule the blip
( sleep 5; apply_block; sleep 30; clear_block ) &
BLIP=$!

# Wait for the worker to finish (success or fail)
T0=$(date +%s)
if wait $WORKER; then
    EXIT=0
else
    EXIT=$?
fi
T1=$(date +%s)

# Make sure blip clean-up ran
wait $BLIP 2>/dev/null || true
clear_block

WALL=$((T1 - T0))
{
    echo "tool=${TOOL}"
    echo "backend=${BACKEND}"
    echo "size_MB=${SIZE_MB}"
    echo "blip_window_s=30"
    echo "exit_code=${EXIT}"
    echo "total_wall_s=${WALL}"
    echo "log_tail:"
    [[ -s /tmp/blip-rclone.log ]] && tail -10 /tmp/blip-rclone.log || true
} > "${RESULTS}/${TOOL}.summary"

echo
echo "[blip] ${TOOL} on ${BACKEND}: exit=${EXIT} wall=${WALL}s -> ${RESULTS}/${TOOL}.summary"
cat "${RESULTS}/${TOOL}.summary"
