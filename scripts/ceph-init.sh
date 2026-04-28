#!/usr/bin/env bash
# Verify the Ceph demo container is up and the lab user/bucket are usable.
# The quay.io/ceph/demo image creates the user/bucket from CEPH_DEMO_* env vars
# on first boot, so this script is mostly a wait+verify probe.
#
# Run from the bench container:
#   BACKEND=ceph /lab/scripts/ceph-init.sh
set -euo pipefail

# Unconditional assignment: the bench container has minio creds baked into its
# compose env, so we MUST overwrite them here (same bug pattern as setup.sh).
S3_ENDPOINT=http://ceph:8080
S3_ACCESS_KEY=cephlab
S3_SECRET_KEY=cephlabsecret
S3_BUCKET=bench
export S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET

echo "[ceph-init] waiting for RGW at ${S3_ENDPOINT}..."
# RGW returns S3-XML 404 NoSuchBucket for GET /, so any HTTP code with the
# Ceph Server header is proof the daemon is alive. We accept 2xx/3xx/4xx.
ready=0
for i in $(seq 1 120); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "${S3_ENDPOINT}/" 2>/dev/null || true)
    if [[ "$code" =~ ^[234] ]]; then
        echo "[ceph-init] RGW responding (HTTP ${code}) after ${i}s"
        ready=1
        break
    fi
    sleep 1
done

if [[ "$ready" -ne 1 ]]; then
    echo "[ceph-init] RGW never came up. Last attempt:"
    curl -v "${S3_ENDPOINT}/" 2>&1 | tail -10
    exit 3
fi

echo "[ceph-init] verifying bucket via mc"
mc alias set ceph "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" >/dev/null
mc mb -p "ceph/${S3_BUCKET}" 2>/dev/null || true
mc ls "ceph/${S3_BUCKET}" >/dev/null
echo "[ceph-init] bucket ${S3_BUCKET} ready on ceph"
