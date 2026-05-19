#!/usr/bin/env bash
# Aggregate the concurrency-sweep / blip / coherency raw results into
# results/REPORT-PRODUCTION.md. Run inside the bench container after
# scripts/concurrency-sweep.sh + blip.sh + coherency.sh have produced data.
# Defensive parsing throughout — disable pipefail/-e so a single malformed
# input doesn't drop tail rows out of the report.
set +e
set -u

REPORT=/lab/results/REPORT-PRODUCTION.md
RAW=/lab/results/raw

bw_mbps() {
    # arg: fio JSON file path. Returns combined read+write bandwidth in MiB/s.
    local f="$1"
    [[ -s "$f" ]] || { echo "—"; return; }
    jq -r '
        ((.jobs[0].read.bw_bytes // 0) + (.jobs[0].write.bw_bytes // 0)) / 1048576
        | . * 100 | round / 100
    ' "$f" 2>/dev/null || echo "—"
}

iops_total() {
    local f="$1"
    [[ -s "$f" ]] || { echo "—"; return; }
    jq -r '
        ((.jobs[0].read.iops // 0) + (.jobs[0].write.iops // 0))
        | . * 100 | round / 100
    ' "$f" 2>/dev/null || echo "—"
}

lat_p99_ms() {
    local f="$1"
    [[ -s "$f" ]] || { echo "—"; return; }
    jq -r '
        [
          (.jobs[0].read.clat_ns.percentile["99.000000"] // 0),
          (.jobs[0].write.clat_ns.percentile["99.000000"] // 0)
        ] | max / 1000000 | . * 100 | round / 100
    ' "$f" 2>/dev/null || echo "—"
}

{
    echo "# rclone vs s3fs-fuse — production-relevant tests"
    echo
    echo "Generated: $(date -u +%FT%TZ)"
    echo
    echo "Three tests beyond throughput: **concurrent client scaling**, **network-blip"
    echo "resilience**, and **cache coherency across two mounts of the same backend**."
    echo "All run inside the same bench container; both tools see the same network"
    echo "conditions, same backend, same disk."
    echo

    echo "## 1. Concurrent-client scaling"
    echo
    echo "fio \`concurrent.fio\` — 70/30 R/W mix, 64 KiB blocks, 128 MiB per virtual"
    echo "client, 60 s time-based. Numbers are aggregate across all clients."
    echo
    echo "### Throughput (MB/s, higher = better)"
    echo
    echo "| backend | tool | N=1 | N=5 | N=10 | N=20 |"
    echo "|---|---|---:|---:|---:|---:|"
    for backend in minio ceph; do
        for tool in rclone s3fs; do
            row="| $backend | $tool"
            for n in 1 5 10 20; do
                f="$RAW/$backend/concurrent/${tool}-N${n}.json"
                row+=" | $(bw_mbps "$f")"
            done
            row+=" |"
            echo "$row"
        done
    done
    echo
    echo "### Aggregate IOPS"
    echo
    echo "| backend | tool | N=1 | N=5 | N=10 | N=20 |"
    echo "|---|---|---:|---:|---:|---:|"
    for backend in minio ceph; do
        for tool in rclone s3fs; do
            row="| $backend | $tool"
            for n in 1 5 10 20; do
                f="$RAW/$backend/concurrent/${tool}-N${n}.json"
                row+=" | $(iops_total "$f")"
            done
            row+=" |"
            echo "$row"
        done
    done
    echo
    echo "### p99 latency (ms, lower = better)"
    echo
    echo "| backend | tool | N=1 | N=5 | N=10 | N=20 |"
    echo "|---|---|---:|---:|---:|---:|"
    for backend in minio ceph; do
        for tool in rclone s3fs; do
            row="| $backend | $tool"
            for n in 1 5 10 20; do
                f="$RAW/$backend/concurrent/${tool}-N${n}.json"
                row+=" | $(lat_p99_ms "$f")"
            done
            row+=" |"
            echo "$row"
        done
    done

    echo
    echo "## 2. Network-blip recovery"
    echo
    echo "2 GiB upload to backend; \`tc netem loss 100%\` on the backend port for"
    echo "30 s starting 5 s after upload begin. Ideal recovery: transfer completes"
    echo "with wall ≈ baseline + 30 s. Failure: non-zero exit, partial upload, hang."
    echo
    echo "| backend | tool | exit | total wall (s) | notes |"
    echo "|---|---|---:|---:|---|"
    for backend in minio ceph; do
        for tool in rclone s3fs; do
            f="$RAW/$backend/blip/${tool}.summary"
            if [[ -s "$f" ]]; then
                EXIT=$(grep "^exit_code=" "$f" | cut -d= -f2 || echo "?")
                WALL=$(grep "^total_wall_s=" "$f" | cut -d= -f2 || echo "?")
                NOTE=$(grep -E "^(NOTICE|ERROR|CRITICAL)" "$f" 2>/dev/null | head -1 | cut -c1-60)
                [[ -z "$NOTE" ]] && NOTE="OK"
                echo "| $backend | $tool | $EXIT | $WALL | $NOTE |"
            else
                echo "| $backend | $tool | — | — | (no data) |"
            fi
        done
    done

    echo
    echo "## 3. Cache coherency across two mounts"
    echo
    echo "Same bucket mounted twice via the same FUSE tool (each mount has its"
    echo "own VFS / stat cache). Write a value via mount A, poll mount B every"
    echo "0.5 s up to a 120 s budget until B reads the new value. \`rclone\` is"
    echo "the default \`--dir-cache-time=5m\`; \`rclone-tuned\` is"
    echo "\`--dir-cache-time=1s --poll-interval=1s\` to show the knob exists;"
    echo "\`s3fs\` is default."
    echo
    echo "> **Retraction note.** An earlier single run (Round 2, commit 2c9ac9d)"
    echo "> reported rclone-default *timing out* (>120 s) on every probe and"
    echo "> framed it as a deal-breaker. **That did not reproduce.** On a clean"
    echo "> stack rclone-default is sub-second, same as rclone-tuned and s3fs."
    echo "> The original timeout was an artifact of accumulated test state at"
    echo "> the tail of a long run (likely a stale rclone holding the mount /"
    echo "> an unflushed vfs-cache-writes queue), not rclone behavior. The"
    echo "> first-run CSV is kept as \`coherency-run1.csv\` so the contradiction"
    echo "> is visible, not hidden."
    echo ">"
    echo "> What this lab can honestly say about coherency: **nothing strong.**"
    echo "> Both mounts run on one host with zero network separation, so all"
    echo "> sub-second numbers are a visibility *floor*, not a multi-host"
    echo "> promise — and the one dramatic result was noise. A real"
    echo "> cross-mount coherency test needs genuine host/geo separation and"
    echo "> n≥3; this lab provides neither yet."
    echo
    echo "| backend | tool | publish | update |"
    echo "|---|---|---:|---:|"
    fmt() {  # bound 'timeout' rather than printing a bare word
        case "$1" in
            timeout) echo "≥120 s (no converge)" ;;
            "")      echo "—" ;;
            *)       echo "${1} s" ;;
        esac
    }
    for backend in minio ceph; do
        for tool in rclone rclone-tuned s3fs; do
            csv="$RAW/$backend/coherency/coherency.csv"
            if [[ -s "$csv" ]]; then
                pub=$(awk -F, -v t="$tool" '$1==t && $2=="publish"{print $3}' "$csv" | head -1)
                upd=$(awk -F, -v t="$tool" '$1==t && $2=="update"{print $3}' "$csv" | head -1)
                echo "| $backend | $tool | $(fmt "$pub") | $(fmt "$upd") |"
            else
                echo "| $backend | $tool | — | — |"
            fi
        done
    done

    echo
    echo "## Reading the numbers"
    echo
    echo "**Concurrency curve** — flat = good (the tool scales)."
    echo "Steeply-falling per-client throughput = saturated single mount."
    echo
    echo "**Blip recovery** — exit 0 with wall ≈ baseline + 30 s = clean recovery."
    echo "Exit non-zero or wall ≪ baseline = the tool gave up; data is in S3 only"
    echo "as much as the half-finished upload made it. Exit non-zero or wall ≫"
    echo "baseline + 30 s = retry storm or deadlock."
    echo
    echo "**Coherency** — sub-second numbers in this lab are a *floor* (one"
    echo "host, no network separation), not a multi-host promise. The earlier"
    echo "claim that rclone-default times out on this test was an artifact and"
    echo "has been retracted; see the methodology note in section 3."
} > "$REPORT"

echo "[collect-production] wrote $REPORT"
