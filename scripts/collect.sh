#!/usr/bin/env bash
# Aggregate JSON outputs from results/raw into a markdown REPORT.md and
# trigger plot.py to generate PNG charts.
#
# Usage (from host):  docker compose exec bench /lab/scripts/collect.sh
set -euo pipefail

BACKEND="${BACKEND:-minio}"
RAW="/lab/results/raw/${BACKEND}"
REPORT="/lab/results/REPORT-${BACKEND}.md"

if [[ ! -d "$RAW" ]]; then
    echo "no results for BACKEND=${BACKEND} at ${RAW} — run scripts/run-bench.sh first"
    exit 1
fi
cd "$RAW"

if ! ls *.json >/dev/null 2>&1; then
    echo "no JSON files yet — run scripts/run-bench.sh first"
    exit 1
fi

{
    echo "# rclone vs s3fs-fuse — benchmark report (backend: ${BACKEND})"
    echo
    echo "Generated: $(date -u +%FT%TZ)"
    echo
    echo "Backend: \`${BACKEND}\` (local docker-compose), bucket \`bench\`."
    echo "Both tools run inside the same Ubuntu 24.04 container with default settings."
    echo
    echo "## Throughput & latency (fio)"
    echo
    echo "| profile | tool | bw_MBps | iops | lat_avg_ms | lat_p99_ms |"
    echo "|---|---|---:|---:|---:|---:|"
    for f in *.json; do
        # Skip non-JSON files (e.g., fio error output saved with .json extension)
        if ! jq -e . "$f" >/dev/null 2>&1; then
            echo "| ${f%.json} | (run failed — see raw/) | — | — | — | — |"
            continue
        fi
        tool=$(echo "$f" | cut -d- -f1)
        profile=$(echo "$f" | sed -E 's/^[^-]+-(.+)\.json$/\1/')
        # Prefer write stats if present, else read.
        jq -r --arg tool "$tool" --arg profile "$profile" '
            .jobs[0] as $j
            | (if ($j.write.bw_bytes // 0) > 0 then $j.write else $j.read end) as $s
            | [$profile, $tool,
               (($s.bw_bytes // 0) / 1048576 | . * 100 | round / 100),
               ($s.iops // 0 | . * 100 | round / 100),
               (($s.clat_ns.mean // 0) / 1000000 | . * 100 | round / 100),
               (($s.clat_ns.percentile["99.000000"] // 0) / 1000000 | . * 100 | round / 100)
              ]
            | "| \(.[0]) | \(.[1]) | \(.[2]) | \(.[3]) | \(.[4]) | \(.[5]) |"
        ' "$f"
    done | sort

    shopt -s nullglob
    time_files=( *.time )
    shopt -u nullglob
    if (( ${#time_files[@]} > 0 )); then
        echo
        echo "## Wall-time & CPU (/usr/bin/time -v)"
        echo
        echo "| run | tool | wall | user_s | sys_s | max_rss_KB |"
        echo "|---|---|---:|---:|---:|---:|"
        for t in "${time_files[@]}"; do
            tool=$(echo "$t" | cut -d- -f1)
            run=$(echo "$t" | sed -E 's/^[^-]+-(.+)\.time$/\1/')
            wall=$(grep -E 'Elapsed.*wall' "$t" | awk -F': ' '{print $NF}' || echo "?")
            user=$(grep -E 'User time' "$t" | awk -F': ' '{print $NF}' || echo "?")
            sys=$(grep -E 'System time' "$t" | awk -F': ' '{print $NF}' || echo "?")
            rss=$(grep -E 'Maximum resident' "$t" | awk -F': ' '{print $NF}' || echo "?")
            echo "| $run | $tool | $wall | $user | $sys | $rss |"
        done | sort
    fi

    echo
    echo "## Charts"
    echo
    echo "![throughput](charts/throughput.png)"
    echo
    echo "![latency](charts/latency.png)"
} > "$REPORT"

echo "[collect] report written -> $REPORT"

if command -v python3 >/dev/null 2>&1 && [[ -f /lab/scripts/plot.py ]]; then
    echo "[collect] generating charts..."
    CHARTS="/lab/results/charts/${BACKEND}"
    mkdir -p "$CHARTS"
    python3 /lab/scripts/plot.py "$RAW" "$CHARTS" || echo "[warn] plot.py failed"
fi

echo "[collect] done."
