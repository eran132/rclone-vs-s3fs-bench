#!/usr/bin/env bash
# Runs every fio profile under configs/fio/ against both /mnt/rclone and /mnt/s3fs.
# Drops page cache between runs. Captures /usr/bin/time -v.
# Outputs JSON to /lab/results/raw/<tool>-<profile>.json
#
# Usage (from host):  docker compose exec bench /lab/scripts/run-bench.sh
#                     docker compose exec bench /lab/scripts/run-bench.sh seq-read     # single profile
set -euo pipefail

BACKEND="${BACKEND:-minio}"
PROFILES_DIR=/lab/configs/fio
RESULTS="/lab/results/raw/${BACKEND}"
mkdir -p "$RESULTS"

drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

run_one() {
    local tool="$1"   # rclone | s3fs
    local profile="$2"
    local mnt="/mnt/${tool}"
    local fio_file="${PROFILES_DIR}/${profile}.fio"
    local out_json="${RESULTS}/${tool}-${profile}.json"
    local out_time="${RESULTS}/${tool}-${profile}.time"

    [[ -f "$fio_file" ]] || { echo "missing $fio_file"; return 1; }
    mountpoint -q "$mnt" || { echo "$mnt not mounted"; return 1; }

    echo
    echo "==== [${tool}] ${profile} ===="
    # Clear any previous artifacts under this mount for the profile
    rm -rf "${mnt}/${profile}.bin" "${mnt}/seq-read.bin" "${mnt}/seq-write.bin" \
           "${mnt}/rand-rw.bin" "${mnt}/smallfiles" 2>/dev/null || true

    # seq-read needs the source file pre-staged
    if [[ "$profile" == "seq-read" ]]; then
        echo "[stage] writing 4G source for seq-read via dd..."
        dd if=/dev/urandom of="${mnt}/seq-read.bin" bs=1M count=4096 status=none
        sync
    fi

    # small-files writes into a subdirectory; fio will not auto-create it
    if [[ "$profile" == "small-files" ]]; then
        mkdir -p "${mnt}/smallfiles"
    fi

    drop_caches

    MNT="$mnt" /usr/bin/time -v -o "$out_time" \
        fio "$fio_file" --output-format=json --output="$out_json" \
        || { echo "fio FAILED for ${tool}/${profile}"; return 2; }

    echo "[ok] ${tool}/${profile} -> ${out_json}"
}

PROFILES=()
if [[ $# -gt 0 ]]; then
    PROFILES=("$@")
else
    for f in "$PROFILES_DIR"/*.fio; do
        PROFILES+=("$(basename "$f" .fio)")
    done
fi

for profile in "${PROFILES[@]}"; do
    for tool in rclone s3fs; do
        run_one "$tool" "$profile" || echo "[warn] continuing past failure"
    done
done

echo
echo "[run-bench] all done. Raw results in ${RESULTS}/"
