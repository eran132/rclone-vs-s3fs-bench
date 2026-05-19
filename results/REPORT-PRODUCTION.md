# rclone vs s3fs-fuse — production-relevant tests

Generated: 2026-05-19T21:11:27Z

Three tests beyond throughput: **concurrent client scaling**, **network-blip
resilience**, and **cache coherency across two mounts of the same backend**.
All run inside the same bench container; both tools see the same network
conditions, same backend, same disk.

## ⚠ Retraction (2026-05-20)

An earlier version of this report (Round 2, commit `2c9ac9d`) framed
**rclone cross-mount coherency as a "deal-breaker"** with a 120 s timeout
on every probe vs s3fs's 40–150 ms. **A clean rerun showed rclone at 0.03 s**,
indistinguishable from s3fs and from the tuned variant. The original
result did not reproduce. It was an artifact of accumulated test state
at the tail of a long run, not rclone behavior. The dramatic finding is
**retracted**; the original CSVs are kept as `coherency-run1.csv` next to
the current `coherency.csv` so the contradiction is visible.

The same n=1 noise hit the **Ceph blip** numbers: rclone 92 s → 36 s and
s3fs 144 s → 51 s on rerun. The "rclone recovers 56 % faster" claim from
Round 2 does not survive a second sample.

## Key findings (n = 1 each cell, treat as directional only)

**The one robust finding from Round 2** is the concurrent-client crossover
on the same mount:

- **N = 1–10**: s3fs-fuse is competitive or faster on the 70/30 mixed workload.
- **N = 20**: s3fs-fuse **collapses** (e.g. MinIO 686 → 150 MB/s, Ceph 686 → 209 MB/s) while rclone keeps scaling.
- Crossover band: **N ≈ 10 (MinIO), N ≈ 15 (Ceph)**.

This reproduced across two different S3 backends in the same run, which
gives it more credibility than a single-cell number. **It is still n = 1
per cell** — the *shape* is trustworthy, the exact crossover N is not.

**Everything else here is unfit for publication at n = 1.** That includes:

- Coherency — retracted above.
- Blip recovery — Ceph numbers moved 2–3× between runs; MinIO is finally
  a real test now (8 GiB upload through a 30 s blackhole, rclone 183 s vs
  s3fs 226 s) but is still a single sample.
- Per-N latency p99 — sensitive to single outliers in 60 s windows.

**What this lab needs before the next publishing pass:**

1. n ≥ 3 per cell, report median + interquartile range.
2. A genuine multi-host coherency setup (separate hosts, separate caches,
   measurable network delay) so the result actually tests cross-mount
   semantics rather than single-host instant visibility.
3. Each cell run from a clean stack so accumulated state cannot create
   another phantom finding.

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
| minio | rclone | 0 | 183 | OK |
| minio | s3fs | 0 | 226 | OK |
| ceph | rclone | 0 | 36 | OK |
| ceph | s3fs | 0 | 51 | OK |

## 3. Cache coherency across two mounts

Same bucket mounted twice via the same FUSE tool (each mount has its
own VFS / stat cache). Write a value via mount A, poll mount B every
0.5 s up to a 120 s budget until B reads the new value. `rclone` is
the default `--dir-cache-time=5m`; `rclone-tuned` is
`--dir-cache-time=1s --poll-interval=1s` to show the knob exists;
`s3fs` is default.

> **Retraction note.** An earlier single run (Round 2, commit 2c9ac9d)
> reported rclone-default *timing out* (>120 s) on every probe and
> framed it as a deal-breaker. **That did not reproduce.** On a clean
> stack rclone-default is sub-second, same as rclone-tuned and s3fs.
> The original timeout was an artifact of accumulated test state at
> the tail of a long run (likely a stale rclone holding the mount /
> an unflushed vfs-cache-writes queue), not rclone behavior. The
> first-run CSV is kept as `coherency-run1.csv` so the contradiction
> is visible, not hidden.
>
> What this lab can honestly say about coherency: **nothing strong.**
> Both mounts run on one host with zero network separation, so all
> sub-second numbers are a visibility *floor*, not a multi-host
> promise — and the one dramatic result was noise. A real
> cross-mount coherency test needs genuine host/geo separation and
> n≥3; this lab provides neither yet.

| backend | tool | publish | update |
|---|---|---:|---:|
| minio | rclone | 0.03 s | 0.01 s |
| minio | rclone-tuned | 0.02 s | 0.01 s |
| minio | s3fs | 0.05 s | 0.06 s |
| ceph | rclone | 0.03 s | 0.01 s |
| ceph | rclone-tuned | 0.02 s | 0.01 s |
| ceph | s3fs | 0.10 s | 0.10 s |

## Reading the numbers

**Concurrency curve** — flat = good (the tool scales).
Steeply-falling per-client throughput = saturated single mount.

**Blip recovery** — exit 0 with wall ≈ baseline + 30 s = clean recovery.
Exit non-zero or wall ≪ baseline = the tool gave up; data is in S3 only
as much as the half-finished upload made it. Exit non-zero or wall ≫
baseline + 30 s = retry storm or deadlock.

**Coherency** — sub-second numbers in this lab are a *floor* (one
host, no network separation), not a multi-host promise. The earlier
claim that rclone-default times out on this test was an artifact and
has been retracted; see the methodology note in section 3.
