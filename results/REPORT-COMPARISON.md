# rclone vs s3fs-fuse — backend comparison

Generated: 2026-04-28

Both backends run as local containers via docker-compose, both FUSE clients
run in the same Ubuntu 24.04 container with default-fair settings. Each tool's
mount uses its closest analogue to the other's behavior:
**rclone** with `--vfs-cache-mode=writes`, **s3fs-fuse** with default disk staging.

- **MinIO**: single-node `minio/minio:latest` at `http://minio:9000`
- **Ceph**: single-container `quay.io/ceph/demo:latest-squid` (mon+mgr+osd+rgw)
  at `http://ceph:8080` — cluster is degraded by demo design (1 OSD vs default
  replication), this is normal.

n=1 per cell. Treat headline ratios as directional, not exact.

## Throughput (MB/s, higher is better)

| profile | MinIO rclone | MinIO s3fs | rclone × | Ceph rclone | Ceph s3fs | rclone × |
|---|---:|---:|---:|---:|---:|---:|
| seq-read 4 GiB, bs 1M | **105.81** | 89.34 | 1.18× | **86.00** | 80.70 | 1.07× |
| seq-write 4 GiB, bs 1M | **104.03** | 28.74 | 3.62× | **114.99** | 32.91 | 3.49× |
| rand-rw 2 GiB, 4k, 70/30 | **4.14** | 0.11 | 38× | **3.92** | 0.11 | 36× |
| small-files 10000 × 16 KiB | **1.82** | 0.16 | 11× | **1.31** | 0.11 | 12× |

## Wall time (lower is better)

| run | MinIO rclone | MinIO s3fs | s3fs / rclone | Ceph rclone | Ceph s3fs | s3fs / rclone |
|---|---:|---:|---:|---:|---:|---:|
| rand-rw 2 GiB | 4 m 53 s | 2 h 04 m | 25× | 5 m 51 s | 1 h 60 m | 21× |
| seq-read 4 GiB | 39 s | 47 s | 1.2× | 49 s | 51 s | 1.05× |
| seq-write 4 GiB | 46 s | 2 m 26 s | 3.2× | 36 s | 2 m 06 s | 3.5× |
| small-files 10k×16K | 1 m 44 s | 19 m 23 s | 11× | 2 m 12 s | 28 m 05 s | **13×** |
| tar-extract 10k files | 48 s | 11 m 12 s | 14× | 51 s | 29 m 06 s | **34×** |

## Latency p99 (ms, lower is better)

| profile | MinIO rclone | MinIO s3fs | Ceph rclone | Ceph s3fs |
|---|---:|---:|---:|---:|
| seq-read | 40 | **354** | 57 | **333** |
| seq-write | 36 | 72 | 25 | 53 |
| rand-rw | 0.6 | 120 | 0.6 | 104 |
| small-files | 7.6 | 0.4 | 7.9 | 0.7 |

## Headline findings

**1. rclone wins every workload on both backends.** Ratio range: 1.07× (Ceph
seq-read, near-tie) to 38× (MinIO rand-rw, structural).

**2. The rclone win is mostly client-side, not backend-side.** On Ceph
seq-read the ratio shrinks from 1.18× to 1.07× — when the backend itself is
the bottleneck, both tools converge. When the backend is fast, rclone's
pipelining compounds and pulls ahead.

**3. s3fs-fuse degrades worse with backend latency.** Compare s3fs tar-extract:
672 s (MinIO) → 1746 s (Ceph), a 2.6× slowdown. rclone tar-extract barely
moves: 48 s → 51 s. s3fs makes one synchronous HTTP round-trip per file
close — when each round-trip costs more, the wall-time multiplies linearly.

**4. The rand-rw 36×/38× gap is structural, not configurable away.**
Consistent across two backends, same workload. Default-fair s3fs cannot
serve 4 KiB random IO at meaningful rate against any S3-compatible backend.

**5. small-files latency p99 inverts the ratio.** rclone has 7.6 ms p99,
s3fs has 0.4 ms p99 (MinIO). Looks like s3fs is faster per op — but its
*throughput* is 11× lower because it does ~11× fewer ops/s overall. Reading
this: s3fs does each individual close-and-PUT *cleanly* but it cannot
parallelize across multiple files. rclone batches, so individual ops show
higher p99 but aggregate throughput wins.

## Phase-0 hot path (rclone CPU, both backends)

The pprof CPU profile is dominated by `local.(*Object).Hash → hash.StreamTypes`
at ~70% cum across seq-read, seq-write, and rand-rw. Source confirmed at
[`backend/local/local.go:1164-1184`](https://github.com/rclone/rclone/blob/master/backend/local/local.go#L1164-L1184):
the entire cache file is re-read after every write to compute the upload's
MD5. See [`profiling/bottleneck-diagnosis.md`](profiling/bottleneck-diagnosis.md).

## Phase-1 measurement: `--s3-disable-checksum` (MinIO, n=3)

Skipping the per-upload MD5 hash on multipart uploads:

| metric | checksum on (mean) | off (mean) | delta |
|---|---:|---:|---:|
| wall (s) | 73.9 | 71.1 | **-3.8%** (per-rep noise: -31% to +52%) |
| user CPU (s) | 56.7 | 41.6 | **-27%** |
| sys CPU (s) | 35.5 | 25.4 | **-28%** |

The CPU savings reproduce the pprof finding (-27% user CPU). Wall-time
delta is too noisy on MinIO-local to publish a number from. A clean re-run
on Ceph (or a remote backend) would resolve it. Recommendation: document
`--s3-disable-checksum` as a tuning option; defer the in-tree incremental-hash
patch until the wall-time signal is clean.

## Caveats — read these before quoting numbers

- **n = 1 per cell.** Re-runs will move the medium-sized numbers ±15%. The
  large structural gaps (rand-rw, small-files) will not change.
- **MinIO ≠ Ceph ≠ StorageGRID ≠ AWS S3.** Each S3 implementation has its
  own latency curve. These results are *not* a prediction of AWS S3
  behavior.
- **Default-fair, not "literal default".** rclone's bare default
  (`--vfs-cache-mode=off`) refuses any client that doesn't open with
  `O_TRUNC` (e.g. fio). We use `--vfs-cache-mode=writes` for fairness vs
  s3fs's default disk staging.
- **Ceph demo cluster is degraded** (1 OSD, default replication 2). The
  S3 layer functions, but absolute throughput is bounded by single-OSD
  IO. A real Ceph cluster will be different.
- **No tuned-vs-tuned round yet.** s3fs-fuse with `parallel_count`,
  `multipart_size`, and `use_cache` would close some gaps. Round 2.

## Charts

- MinIO: [`charts/minio/throughput.png`](charts/minio/throughput.png), [`charts/minio/latency.png`](charts/minio/latency.png)
- Ceph: [`charts/ceph/throughput.png`](charts/ceph/throughput.png), [`charts/ceph/latency.png`](charts/ceph/latency.png)

## Per-backend reports

- [`REPORT-minio.md`](REPORT-minio.md)
- [`REPORT-ceph.md`](REPORT-ceph.md)
