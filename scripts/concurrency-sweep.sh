#!/usr/bin/env bash
# Sweep the concurrent.fio profile at N = 1, 5, 10, 20 against both /mnt/rclone
# and /mnt/s3fs. 60s time-based runtime per N. Outputs JSON per (tool, N) under
# results/raw/${BACKEND}/concurrent/.
#
# Run from inside the bench container:
#   BACKEND=minio /lab/scripts/concurrency-sweep.sh
#   BACKEND=ceph  /lab/scripts/concurrency-sweep.sh
set -euo pipefail

BACKEND="${BACKEND:-minio}"
PROFILE=/lab/configs/fio/concurrent.fio
RESULTS="/lab/results/raw/${BACKEND}/concurrent"
mkdir -p "$RESULTS"

CLIENTS=(1 5 10 20)
[[ -n "${CLIENTS_OVERRIDE:-}" ]] && read -r -a CLIENTS <<< "$CLIENTS_OVERRIDE"

drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

run_one() {
    local tool="$1"   # rclone | s3fs
    local n="$2"
    local mnt="/mnt/${tool}"
    local out="${RESULTS}/${tool}-N${n}.json"
    local timefile="${RESULTS}/${tool}-N${n}.time"

    [[ -d "$mnt" ]] && mountpoint -q "$mnt" || { echo "$mnt not mounted"; return 1; }

    # Clean prior conc artifacts
    rm -f "${mnt}"/conc.*.bin 2>/dev/null || true

    drop_caches
    echo "==== [${tool}] N=${n} ===="
    NUMJOBS=$n MNT="$mnt" /usr/bin/time -v -o "$timefile" \
        fio "$PROFILE" --output-format=json --output="$out" \
        || { echo "fio FAILED for ${tool}/N=${n}"; return 2; }
    echo "[ok] ${tool}/N=${n} -> ${out}"
}

for n in "${CLIENTS[@]}"; do
    for tool in rclone s3fs; do
        run_one "$tool" "$n" || echo "[warn] continuing past failure"
    done
done

echo
echo "[concurrency-sweep] done. Results in ${RESULTS}/"
