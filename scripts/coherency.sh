#!/usr/bin/env bash
# Cross-mount cache-coherency probe.
#
# Mounts the same backend bucket twice via the same FUSE tool — once at
# /mnt/${tool}-A, once at /mnt/${tool}-B (each gets its own VFS cache /
# stat cache). Writes a value via mount A and polls mount B until it sees
# the new value. Reports the stale window in seconds.
#
# Repeats for an UPDATE (overwrite) so we measure both first-publish and
# update-visibility windows.
#
# Run from inside the bench container (after BACKEND=... setup.sh has set
# /root/.config/rclone/rclone.conf and /root/.passwd-s3fs):
#   BACKEND=minio /lab/scripts/coherency.sh
set -euo pipefail

BACKEND="${BACKEND:-minio}"
RESULTS="/lab/results/raw/${BACKEND}/coherency"
mkdir -p "$RESULTS"

case "$BACKEND" in
    minio)
        S3_ENDPOINT=http://minio:9000
        RCLONE_REMOTE=minio
        ;;
    ceph)
        S3_ENDPOINT=http://ceph:8080
        RCLONE_REMOTE=ceph
        ;;
    *) echo "unknown BACKEND $BACKEND"; exit 2 ;;
esac
S3_BUCKET="${S3_BUCKET:-bench}"
POLL_BUDGET_S=120

# Tear down existing mounts if any, set up two fresh per tool
unmount_all() {
    pkill -x rclone 2>/dev/null || true
    pkill -x s3fs 2>/dev/null || true
    sleep 1
    for m in /mnt/rclone-A /mnt/rclone-B /mnt/s3fs-A /mnt/s3fs-B \
             /mnt/rclone /mnt/s3fs; do
        fusermount3 -u "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        rm -rf "$m" 2>/dev/null || true
    done
}

mount_rclone_pair() {
    mkdir -p /mnt/rclone-A /mnt/rclone-B
    for letter in A B; do
        rclone mount "${RCLONE_REMOTE}:${S3_BUCKET}" "/mnt/rclone-${letter}" \
            --allow-other --allow-non-empty \
            --vfs-cache-mode writes \
            --log-file "${RESULTS}/rclone-mount-${letter}.log" --log-level INFO &
        disown $!
    done
    for i in $(seq 1 60); do
        mountpoint -q /mnt/rclone-A && mountpoint -q /mnt/rclone-B && return
        sleep 0.5
    done
    echo "rclone-A/B did not come up"; exit 3
}

mount_s3fs_pair() {
    mkdir -p /mnt/s3fs-A /mnt/s3fs-B
    for letter in A B; do
        s3fs "${S3_BUCKET}" "/mnt/s3fs-${letter}" \
            -o url="$S3_ENDPOINT" \
            -o use_path_request_style \
            -o passwd_file=/root/.passwd-s3fs \
            -o allow_other -o nonempty \
            -o dbglevel=info \
            -o logfile="${RESULTS}/s3fs-mount-${letter}.log"
    done
    for i in $(seq 1 60); do
        mountpoint -q /mnt/s3fs-A && mountpoint -q /mnt/s3fs-B && return
        sleep 0.5
    done
    echo "s3fs-A/B did not come up"; exit 4
}

# Probe: write VAL via mount A; poll mount B every 0.5s up to budget; report seconds.
probe() {
    local tool="$1"
    local phase="$2"   # publish or update
    local val="$3"
    local mntA="/mnt/${tool}-A"
    local mntB="/mnt/${tool}-B"
    local key="coherency-probe.txt"

    echo "[${tool}] phase=${phase} writing '${val}' via ${mntA}"
    echo -n "$val" > "${mntA}/${key}"
    sync

    local t0
    t0=$(date +%s.%N)
    local seen=""
    for i in $(seq 1 $((POLL_BUDGET_S * 2))); do
        if [[ -f "${mntB}/${key}" ]]; then
            seen=$(cat "${mntB}/${key}" 2>/dev/null || true)
            if [[ "$seen" == "$val" ]]; then
                local t1
                t1=$(date +%s.%N)
                local elapsed
                elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
                echo "[${tool}/${phase}] visible after ${elapsed}s"
                echo "${tool},${phase},${elapsed}" >> "${RESULTS}/coherency.csv"
                return
            fi
        fi
        sleep 0.5
    done
    echo "[${tool}/${phase}] NOT visible within ${POLL_BUDGET_S}s (last seen='${seen}')"
    echo "${tool},${phase},timeout" >> "${RESULTS}/coherency.csv"
}

main() {
    : > "${RESULTS}/coherency.csv"
    echo "tool,phase,elapsed_s" >> "${RESULTS}/coherency.csv"

    echo
    echo "============== rclone =============="
    unmount_all
    mount_rclone_pair
    probe rclone publish "v1-$(date +%s)"
    probe rclone update  "v2-$(date +%s)"

    echo
    echo "============== s3fs =============="
    unmount_all
    mount_s3fs_pair
    probe s3fs publish "v1-$(date +%s)"
    probe s3fs update  "v2-$(date +%s)"

    unmount_all
    echo
    echo "[coherency] result CSV at ${RESULTS}/coherency.csv:"
    cat "${RESULTS}/coherency.csv"
}

main "$@"
