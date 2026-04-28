#!/usr/bin/env bash
# Unmount, then optionally bring the compose stack down.
# Defaults: keep MinIO data volume so reruns are fast.
#
# Usage (from host):
#   ./benchmark-lab/scripts/teardown.sh           # unmount + compose down
#   ./benchmark-lab/scripts/teardown.sh --purge   # also drop minio-data volume
set -euo pipefail

PURGE=0
if [[ "${1-}" == "--purge" ]]; then PURGE=1; fi

# This script is meant to run on the HOST — call into the container for unmounts.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
cd "$LAB"

if docker compose ps --status running --quiet bench >/dev/null 2>&1; then
    echo "[teardown] unmounting FUSE mounts inside bench container"
    docker compose exec -T bench bash -c '
        for m in /mnt/rclone /mnt/s3fs; do
            if mountpoint -q "$m"; then
                fusermount3 -u "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
            fi
        done
    ' || true
fi

echo "[teardown] docker compose down"
if [[ "$PURGE" -eq 1 ]]; then
    docker compose down -v
    echo "[teardown] purged minio-data volume."
else
    docker compose down
    echo "[teardown] kept minio-data volume (use --purge to wipe)."
fi
