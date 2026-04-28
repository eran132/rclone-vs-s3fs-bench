#!/usr/bin/env bash
# Run the full bench against both MinIO and Ceph back-to-back, then build a
# side-by-side comparison report.
#
# Run from the bench container:
#   /lab/scripts/compare-backends.sh
#
# Prereq on host:
#   docker compose --profile ceph up -d ceph    # ~60-90s for first boot
#   (the bench container itself is started by `docker compose up -d`)
set -euo pipefail

run_for_backend() {
    local backend="$1"
    echo
    echo "############################################################"
    echo "# Backend: ${backend}"
    echo "############################################################"

    # Tear down any prior mounts and start clean
    pkill -x rclone 2>/dev/null || true
    for m in /mnt/rclone /mnt/s3fs; do
        if mountpoint -q "$m"; then
            fusermount3 -u "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done

    if [[ "$backend" == "ceph" ]]; then
        BACKEND=ceph /lab/scripts/ceph-init.sh
    fi
    BACKEND="$backend" /lab/scripts/setup.sh
    BACKEND="$backend" /lab/scripts/run-bench.sh
    BACKEND="$backend" /lab/scripts/tar-extract.sh
    BACKEND="$backend" /lab/scripts/collect.sh
}

run_for_backend minio
run_for_backend ceph

# Side-by-side report
COMP=/lab/results/REPORT-COMPARISON.md
{
    echo "# rclone vs s3fs-fuse — backend comparison"
    echo
    echo "Generated: $(date -u +%FT%TZ)"
    echo
    echo "Two backends compared on identical hardware/container/workloads."
    echo
    echo "## Throughput (MB/s — higher is better)"
    echo
    echo "| profile | tool | minio | ceph |"
    echo "|---|---|---:|---:|"
    for p in seq-write seq-read rand-rw small-files; do
        for tool in rclone s3fs; do
            mfile="/lab/results/raw/minio/${tool}-${p}.json"
            cfile="/lab/results/raw/ceph/${tool}-${p}.json"
            mbw="—"; cbw="—"
            if jq -e . "$mfile" >/dev/null 2>&1; then
                mbw=$(jq -r '(.jobs[0] | (if .write.bw_bytes>0 then .write else .read end).bw_bytes / 1048576) | .*100|round/100' "$mfile")
            fi
            if jq -e . "$cfile" >/dev/null 2>&1; then
                cbw=$(jq -r '(.jobs[0] | (if .write.bw_bytes>0 then .write else .read end).bw_bytes / 1048576) | .*100|round/100' "$cfile")
            fi
            echo "| $p | $tool | $mbw | $cbw |"
        done
    done

    echo
    echo "## Wall-time (seconds — lower is better)"
    echo
    echo "| run | tool | minio | ceph |"
    echo "|---|---|---:|---:|"
    for p in seq-write seq-read rand-rw small-files tar-extract; do
        for tool in rclone s3fs; do
            mfile="/lab/results/raw/minio/${tool}-${p}.time"
            cfile="/lab/results/raw/ceph/${tool}-${p}.time"
            extract_wall() { grep -E 'Elapsed.*wall' "$1" 2>/dev/null | awk -F': ' '{print $NF}' || echo "—"; }
            mw=$(extract_wall "$mfile" 2>/dev/null || echo "—"); [[ -z "$mw" ]] && mw="—"
            cw=$(extract_wall "$cfile" 2>/dev/null || echo "—"); [[ -z "$cw" ]] && cw="—"
            echo "| $p | $tool | $mw | $cw |"
        done
    done
} > "$COMP"

echo
echo "[compare] wrote $COMP"
