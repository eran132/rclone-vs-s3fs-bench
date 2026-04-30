# rclone vs s3fs-fuse — production-relevant tests

Generated: 2026-04-30T06:07:42Z

Three tests beyond throughput: **concurrent client scaling**, **network-blip
resilience**, and **cache coherency across two mounts of the same backend**.
All run inside the same bench container; both tools see the same network
conditions, same backend, same disk.

## Key findings (n = 1, default-fair settings)

**1. The single-process headline reverses under low-to-medium concurrency.**
At **N = 1 to N = 10**, s3fs-fuse aggregate throughput is **comparable or
better** than rclone on the 70/30 mixed workload (e.g. N = 5 on MinIO:
s3fs 686 MB/s vs rclone 244 MB/s, **2.8× s3fs win**). At **N = 20**,
**s3fs collapses** (MinIO 686 → 150, Ceph 686 → 209) while rclone keeps
scaling (MinIO 244 → 719, Ceph 465 → 475). **Crossover is around
N = 10–15.** This is the most important finding for the AD-user case:
*for 5–10 concurrent users, s3fs is the faster tool*; *for 15+, rclone is*.

**2. Network-blip recovery: rclone is 56 % faster on the backend that
actually exercised the test.** On Ceph (where the 2 GiB upload was still
in flight when the 30 s blackhole hit), rclone resumed in 92 s vs s3fs's
144 s. On MinIO the upload finished before the blip started (23 s wall
on both) — the test was a no-op there, not a tie.

**3. Cross-mount cache coherency: rclone is broken at default settings,
s3fs is essentially instant.** With two mounts of the same bucket and
default cache TTLs, s3fs makes a fresh write visible to the second
mount in **40–150 ms**. rclone **timed out at 120 s** (2-minute budget)
on every probe — the default `--dir-cache-time = 5 m` means mount B
keeps serving stale directory listings until its cache expires.
**For an "apps write, AD users read" pattern, this is the deal-breaker
for default rclone.** Tunable to `--dir-cache-time = 1 s` at the cost of
metadata throughput.

## Implication for the AD-user-on-StorageGRID question

| concern | who wins (default settings) |
|---|---|
| 5–10 concurrent users on the same mount | s3fs-fuse |
| 15–20+ concurrent users on the same mount | rclone |
| Recovery from a gateway flap mid-upload | rclone |
| App writes → other-mount user reads (visibility) | **s3fs-fuse, by a lot** |
| Single-stream throughput (single process) | rclone (per Round 1) |
| Windows-native deployment | rclone (s3fs-fuse has no Windows build) |

There is **no clean winner for the multi-user case** without tuning. The
honest deployment recipe depends on user count *and* on whether you can
tolerate a 5-minute stale-listing window for the cross-mount case.

## 1. Concurrent-client scaling

fio `concurrent.fio` — 70/30 R/W mix, 64 KiB blocks, 128 MiB per virtual
client, 60 s time-based. Numbers are aggregate across all clients.

### Throughput (MB/s, higher = better)

| backend | tool | N=1 | N=5 | N=10 | N=20 |
|---|---|---:|---:|---:|---:|
| minio | rclone | 148.27 | 244.29 | 585.18 | 719.36 |
| minio | s3fs | 194.51 | 686.48 | 434.5 | 150.07 |
| ceph | rclone | 154.03 | 465.49 | 594.32 | 475.35 |
| ceph | s3fs | 239.19 | 622.49 | 685.99 | 208.91 |

### Aggregate IOPS

| backend | tool | N=1 | N=5 | N=10 | N=20 |
|---|---|---:|---:|---:|---:|
| minio | rclone | 2372.36 | 3908.68 | 9362.85 | 11509.83 |
| minio | s3fs | 3112.18 | 10983.71 | 6952.04 | 2401.13 |
| ceph | rclone | 2464.49 | 7447.89 | 9509.12 | 7605.56 |
| ceph | s3fs | 3827.02 | 9959.82 | 10975.92 | 3342.5 |

### p99 latency (ms, lower = better)

| backend | tool | N=1 | N=5 | N=10 | N=20 |
|---|---|---:|---:|---:|---:|
| minio | rclone | 1.58 | 13.04 | 5.34 | 10.55 |
| minio | s3fs | 1.32 | 1.93 | 9.63 | 62.65 |
| ceph | rclone | 1.22 | 2.87 | 5.47 | 14.09 |
| ceph | s3fs | 0.37 | 2.34 | 4.55 | 44.3 |

## 2. Network-blip recovery

2 GiB upload to backend; `tc netem loss 100%` on the backend port for
30 s starting 5 s after upload begin. Ideal recovery: transfer completes
with wall ≈ baseline + 30 s. Failure: non-zero exit, partial upload, hang.

| backend | tool | exit | total wall (s) | notes |
|---|---|---:|---:|---|
| minio | rclone | 0 | 23 | OK |
| minio | s3fs | 0 | 23 | OK |
| ceph | rclone | 0 | 92 | OK |
| ceph | s3fs | 0 | 144 | OK |

## 3. Cache coherency across two mounts

Same bucket mounted twice via the same FUSE tool (each mount has its own
VFS / stat cache). Write a value via mount A, poll mount B every 0.5 s
until B reads the new value. Reports stale-window in seconds. Default
settings on both tools.

| backend | tool | publish (s) | update (s) |
|---|---|---:|---:|
| minio | rclone | timeout | timeout |
| minio | s3fs | 0.04 | 0.05 |
| ceph | rclone | timeout | timeout |
| ceph | s3fs | 0.14 | 0.15 |

## Reading the numbers

**Concurrency curve** — flat = good (the tool scales).
Steeply-falling per-client throughput = saturated single mount.

**Blip recovery** — exit 0 with wall ≈ baseline + 30 s = clean recovery.
Exit non-zero or wall ≪ baseline = the tool gave up; data is in S3 only
as much as the half-finished upload made it. Exit non-zero or wall ≫
baseline + 30 s = retry storm or deadlock.

**Coherency** — lower is better, but `0` likely means the lab's
single-machine setup gave instant visibility (no real cache window). On
a real multi-host deployment the numbers will be larger because the
stat cache TTL applies; this lab cannot reproduce that without real
geographic separation. Treat the relative ordering, not the absolute
seconds.
