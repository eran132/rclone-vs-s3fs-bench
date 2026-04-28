#!/usr/bin/env bash
# Real-world workload: extract a tarball into each mount and time it.
# Uses a small synthetic tar (10000 tiny files) by default to stay fast.
#
# Usage (from host):  docker compose exec bench /lab/scripts/tar-extract.sh
set -euo pipefail

BACKEND="${BACKEND:-minio}"
RESULTS="/lab/results/raw/${BACKEND}"
mkdir -p "$RESULTS"

TARBALL=/tmp/lab-tree.tar.gz
if [[ ! -f "$TARBALL" ]]; then
    echo "[stage] generating synthetic tree (10000 small files)..."
    rm -rf /tmp/lab-tree && mkdir -p /tmp/lab-tree
    for i in $(seq 1 100); do
        mkdir -p "/tmp/lab-tree/d${i}"
        for j in $(seq 1 100); do
            head -c 4096 /dev/urandom > "/tmp/lab-tree/d${i}/f${j}.bin"
        done
    done
    tar -czf "$TARBALL" -C /tmp lab-tree
    rm -rf /tmp/lab-tree
fi

drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

run_one() {
    local tool="$1"
    local mnt="/mnt/${tool}"
    local out="${RESULTS}/${tool}-tar-extract.time"

    mountpoint -q "$mnt" || { echo "$mnt not mounted"; return 1; }
    rm -rf "${mnt}/lab-tree" 2>/dev/null || true
    drop_caches

    echo "==== [${tool}] tar-extract ===="
    /usr/bin/time -v -o "$out" tar -xzf "$TARBALL" -C "$mnt"
    echo "[ok] ${tool}/tar-extract -> ${out}"
}

for tool in rclone s3fs; do
    run_one "$tool" || echo "[warn] ${tool} failed"
done
