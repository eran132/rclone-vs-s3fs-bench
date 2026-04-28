#!/usr/bin/env bash
# Bring up the lab from inside the bench container:
#   - waits for the chosen S3 backend (BACKEND=minio|ceph)
#   - creates the bench bucket (MinIO only — Ceph bucket is bootstrapped by
#     scripts/ceph-init.sh on the ceph container)
#   - mounts rclone at /mnt/rclone
#   - mounts s3fs   at /mnt/s3fs
#
# Run on the HOST as:  docker compose exec bench /lab/scripts/setup.sh
set -euo pipefail

# Backend selection: minio (default) or ceph. Switching backend changes the
# S3 endpoint, credentials, rclone remote name, and s3fs password file.
BACKEND="${BACKEND:-minio}"
# Unconditional assignment: the compose file bakes minio defaults into the
# bench container's env, so we MUST overwrite them when BACKEND=ceph (otherwise
# s3fs ends up pointed at minio with ceph credentials).
case "$BACKEND" in
    minio)
        S3_ENDPOINT=http://minio:9000
        S3_ACCESS_KEY=minioadmin
        S3_SECRET_KEY=minioadmin
        S3_BUCKET=bench
        RCLONE_REMOTE=minio
        S3FS_PASSWD_SRC=/lab/configs/s3fs-passwd
        ;;
    ceph)
        S3_ENDPOINT=http://ceph:8080
        S3_ACCESS_KEY=cephlab
        S3_SECRET_KEY=cephlabsecret
        S3_BUCKET=bench
        RCLONE_REMOTE=ceph
        S3FS_PASSWD_SRC=/lab/configs/s3fs-passwd-ceph
        ;;
    *)
        echo "BACKEND must be minio or ceph (got: $BACKEND)" >&2
        exit 2
        ;;
esac
export S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET
echo "[setup] BACKEND=${BACKEND}  endpoint=${S3_ENDPOINT}  bucket=${S3_BUCKET}"

echo "[setup] waiting for backend at ${S3_ENDPOINT}..."
case "$BACKEND" in
    minio)
        # MinIO has /minio/health/live which returns 200
        for i in $(seq 1 90); do
            curl -fsS "${S3_ENDPOINT}/minio/health/live" >/dev/null 2>&1 && break
            sleep 1
        done
        ;;
    ceph)
        # Ceph RGW returns S3-XML 404 on /. Any 2xx/3xx/4xx means alive.
        for i in $(seq 1 120); do
            code=$(curl -s -o /dev/null -w '%{http_code}' "${S3_ENDPOINT}/" 2>/dev/null || true)
            [[ "$code" =~ ^[234] ]] && break
            sleep 1
        done
        ;;
esac

echo "[setup] configuring mc + ensuring bucket ${S3_BUCKET}"
mc alias set lab "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" >/dev/null
mc mb -p "lab/${S3_BUCKET}" 2>/dev/null || true
mc ls "lab/${S3_BUCKET}" >/dev/null

# rclone config (copy in writable location so we can chmod, etc.)
mkdir -p /root/.config/rclone
cp /lab/configs/rclone.conf /root/.config/rclone/rclone.conf

# s3fs password file (must be 0600)
cp "$S3FS_PASSWD_SRC" /root/.passwd-s3fs
chmod 600 /root/.passwd-s3fs

mkdir -p /mnt/rclone /mnt/s3fs

# Unmount stale mounts (idempotent), kill any prior FUSE clients, then make
# sure the mountpoint directories are empty — both rclone and s3fs refuse to
# mount onto a non-empty dir by default.
pkill -x rclone 2>/dev/null || true
pkill -x s3fs 2>/dev/null || true
sleep 1
for m in /mnt/rclone /mnt/s3fs; do
    fusermount3 -u "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
done
# Recreate mountpoints fresh — a torn-down FUSE may leave stub files behind
rm -rf /mnt/rclone /mnt/s3fs
mkdir -p /mnt/rclone /mnt/s3fs

echo "[setup] mounting rclone (${RCLONE_REMOTE}) -> /mnt/rclone"
# Run rclone as a bash background job (NOT --daemon: under `docker exec -T` the
# daemon fork closes stdin and terminates the parent shell mid-script).
# --vfs-cache-mode=writes stages writes to a local cache until close — needed for
# clients (like fio) that don't use O_TRUNC. This is the closest analogue to
# s3fs's default behavior (stages to /tmp until close), so it's the fair
# default-vs-default starting point.
rclone mount "${RCLONE_REMOTE}:${S3_BUCKET}" /mnt/rclone \
    --allow-other \
    --allow-non-empty \
    --dir-cache-time 5s \
    --vfs-cache-mode writes \
    --log-file "/lab/results/raw/rclone-mount-${BACKEND}.log" \
    --log-level INFO &
disown $!

# Wait until the mount actually appears, fail fast if it doesn't
for i in $(seq 1 30); do
    mountpoint -q /mnt/rclone && break
    sleep 0.5
done

echo "[setup] mounting s3fs -> /mnt/s3fs"
s3fs "${S3_BUCKET}" /mnt/s3fs \
    -o url="${S3_ENDPOINT}" \
    -o use_path_request_style \
    -o passwd_file=/root/.passwd-s3fs \
    -o allow_other \
    -o nonempty \
    -o dbglevel=info \
    -o logfile="/lab/results/raw/s3fs-mount-${BACKEND}.log"

# Verify (abort on either mount failure)
sleep 1
if ! mountpoint -q /mnt/rclone; then
    echo "[setup] FAIL: rclone is not a mountpoint. Tail of mount log:"
    tail -20 "/lab/results/raw/rclone-mount-${BACKEND}.log" 2>/dev/null || true
    exit 4
fi
echo "[setup] rclone OK"
if ! mountpoint -q /mnt/s3fs; then
    echo "[setup] FAIL: s3fs is not a mountpoint. Tail of mount log:"
    tail -20 "/lab/results/raw/s3fs-mount-${BACKEND}.log" 2>/dev/null || true
    exit 5
fi
echo "[setup] s3fs   OK"
ls -la /mnt/rclone /mnt/s3fs
echo "[setup] done."
