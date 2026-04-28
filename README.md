# rclone-vs-s3fs-bench

A reproducible Docker-based benchmark comparing **`rclone mount`** and
**`s3fs-fuse`** as FUSE filesystems on top of S3-compatible object storage.

Two backends, four fio workload profiles, plus a real-world `tar -xzf`
extract. Single shared bench container, identical mount semantics, no
configuration tricks. Raw fio JSON is committed alongside the reports so
you can verify the math.

## TL;DR

In this lab, on this hardware, with default-fair settings, **rclone outperforms
s3fs-fuse on every measured workload, on both backends.** Ratios range from
**1.07× (Ceph seq-read, near-tie)** to **38× (MinIO rand-rw, structural)**.

Read [Caveats](#caveats) before quoting any number.

## Headline (default-fair, n = 1)

| workload | MinIO rclone | MinIO s3fs | rclone × | Ceph rclone | Ceph s3fs | rclone × |
|---|---:|---:|---:|---:|---:|---:|
| seq-read 4 GiB, bs 1M | 105.81 MB/s | 89.34 | 1.18× | 86.00 MB/s | 80.70 | **1.07×** |
| seq-write 4 GiB, bs 1M | 104.03 MB/s | 28.74 | 3.62× | 114.99 MB/s | 32.91 | 3.49× |
| rand-rw 2 GiB, 4k, 70/30 | 4.14 MB/s | 0.11 | **38×** | 3.92 MB/s | 0.11 | **36×** |
| 10000 × 16 KiB writes | 1.82 MB/s | 0.16 | 11× | 1.31 MB/s | 0.11 | 12× |
| tar-extract 10000 files | 48 s | 11 m 12 s | 14× | 51 s | 29 m 06 s | **34×** |

Per-backend reports: [`results/REPORT-minio.md`](results/REPORT-minio.md) ·
[`results/REPORT-ceph.md`](results/REPORT-ceph.md)
· Combined: [`results/REPORT-COMPARISON.md`](results/REPORT-COMPARISON.md)

Bottleneck analysis (CPU pprof + strace + tcpdump):
[`results/profiling/bottleneck-diagnosis.md`](results/profiling/bottleneck-diagnosis.md)

## Why this exists

I wanted to know which FUSE-based S3 mount was actually faster on real
workloads — end-to-end, with raw data, with a methodology I'd be willing
to defend on Hacker News. The most popular blog posts comparing these
tools are old, often cherry-picked, and rarely publish raw numbers.

Production target context: NetApp StorageGRID (no test access yet).
This lab uses MinIO and Ceph RGW as free, on-disk stand-ins.
Numbers do not predict StorageGRID or AWS S3 behavior.

## Methodology (read this before the results)

- **Both tools run in the same container** ([`Dockerfile.bench`](Dockerfile.bench), Ubuntu 24.04).
  No host-side noise.
- **Both backends run as separate compose services.** Same docker network,
  same kernel, same RAM, same disk volume class.
- **Default-fair, not "literal default."** rclone's bare default
  (`--vfs-cache-mode=off`) refuses any client that doesn't open files with
  `O_TRUNC` (e.g. fio). To get a usable comparison vs s3fs-fuse's default
  (which stages writes to disk until close), this lab uses
  `--vfs-cache-mode=writes` on rclone. Documented in
  [`scripts/setup.sh`](scripts/setup.sh).
- **Page cache dropped between runs** (`echo 3 > /proc/sys/vm/drop_caches`)
  so we measure the FUSE layer, not Linux's RAM.
- **Workloads** in [`configs/fio/`](configs/fio/):
  - `seq-read.fio` — 4 GiB, bs 1 MiB, sequential read
  - `seq-write.fio` — 4 GiB, bs 1 MiB, sequential write, fsync_on_close
  - `rand-rw.fio` — 2 GiB, bs 4k, 70/30 R/W mix
  - `small-files.fio` — 10 000 × 16 KiB files, fsync_on_close
- **Real-world workload**: `tar -xzf` of a 10 000-small-file synthetic
  tarball into each mount.
- **Profiling**: rclone is started with `--rc` and pprof'd for 30 s during
  each workload. `strace -c` and `tcpdump` run alongside. See
  [`scripts/profile.sh`](scripts/profile.sh).
- **Phase-1 measurement** of `--s3-disable-checksum` impact via direct
  `rclone copy` (no FUSE), n = 3 reps:
  [`results/phase1/disable-checksum-rclone-copy.log`](results/phase1/disable-checksum-rclone-copy.log).
- **n = 1** for the headline numbers. Re-runs will move the medium-sized
  numbers ±15%. The structural gaps (rand-rw 36×, small-files 11×) won't
  change.

## How to reproduce

Requires Docker. ~5 GiB disk, ~2 GiB RAM during run.

```bash
git clone https://github.com/eran132/rclone-vs-s3fs-bench
cd rclone-vs-s3fs-bench

# 1) build images, bring MinIO + bench up
docker compose up -d --build

# 2) MinIO half
docker compose exec bench /lab/scripts/setup.sh
docker compose exec bench /lab/scripts/run-bench.sh
docker compose exec bench /lab/scripts/tar-extract.sh
docker compose exec bench /lab/scripts/collect.sh

# 3) Ceph half (image is ~1 GB; first boot ~60-90 s)
docker compose --profile ceph up -d ceph
docker compose exec bench bash -c '
    BACKEND=ceph /lab/scripts/ceph-init.sh
    BACKEND=ceph /lab/scripts/setup.sh
    BACKEND=ceph /lab/scripts/run-bench.sh
    BACKEND=ceph /lab/scripts/tar-extract.sh
    BACKEND=ceph /lab/scripts/collect.sh
'

# 4) Cross-backend comparison report
docker compose exec bench /lab/scripts/compare-backends.sh
```

Total wall time: **~2-4 hours** depending on hardware. The s3fs-fuse
rand-rw and small-files profiles dominate the runtime (~95-115 min and
~20-30 min respectively per backend) — that's a real result, not a bug.

To run a single profile only:

```bash
docker compose exec bench /lab/scripts/run-bench.sh seq-write
```

## Phase-0 finding (rclone hot path)

Across `seq-read`, `seq-write`, and `rand-rw`, rclone's CPU profile is
dominated by **MD5 hashing of the cache file at upload time** —
~70 % cum CPU in
[`backend/local/local.go:1164-1184`](https://github.com/rclone/rclone/blob/master/backend/local/local.go#L1164-L1184).
The cached hash is invalidated by every write (modtime changes), so the
upload path re-reads the entire cache file to compute MD5 before each
S3 PUT.

Toggling `--s3-disable-checksum` (skips the hash on multipart) gives a
reproducible **-27 % user CPU**, **-28 % sys CPU** delta on a 4 GiB upload.
Wall-time delta is too noisy on local backends (-31 % to +52 % per rep,
mean -3.8 %) to ship as a publishable number — needs a more
network-bound backend to resolve. See
[`results/profiling/bottleneck-diagnosis.md`](results/profiling/bottleneck-diagnosis.md)
and [`IMPROVEMENT-PLAN.md`](IMPROVEMENT-PLAN.md).

## Caveats

Read these before drawing conclusions.

- **n = 1 per cell.** No error bars on the headline numbers.
- **MinIO ≠ Ceph ≠ StorageGRID ≠ AWS S3.** Each S3 implementation has its
  own latency curve. These results are *not* a prediction of AWS S3
  behavior. Add a real-cloud target if you need a real-cloud answer.
- **Default-fair isn't "literal default."** rclone's bare default
  (`vfs-cache-mode=off`) is incompatible with fio. We use the closest
  analogue to s3fs-fuse's default disk-staging behavior. Justification
  in [`scripts/setup.sh`](scripts/setup.sh).
- **Ceph demo cluster is degraded** (1 OSD, default replication 2). The
  S3 layer functions, but absolute throughput is bounded by single-OSD
  IO. A real Ceph cluster will be different (probably faster on
  parallelism, similar per-request latency).
- **No tuned-vs-tuned round.** s3fs-fuse with `parallel_count=30
  multipart_size=64 use_cache=/tmp` would close some of the gap. rclone
  with `--vfs-cache-mode=full --buffer-size=64M --vfs-read-ahead` would
  go further. Both untested here. Round 2.
- **The `local.Object.Hash` hot path is rclone-internal**, not a property
  of FUSE or S3. It would matter even on a backend with zero network
  latency. The Phase-1 `--s3-disable-checksum` measurement captures it
  cleanly at the CPU level.
- **rclone `cmd/mount/--daemon` + `docker exec -T` was the source of
  several silent failures** during this lab. The scripts work around it
  by running rclone as a bash background job. If you adapt this elsewhere,
  use `&` not `--daemon` under non-TTY shells.

## Layout

```
.
├── docker-compose.yml          # minio + bench + ceph (profile: ceph)
├── Dockerfile.bench            # ubuntu + rclone + s3fs + fio + go + pprof + tcpdump
├── configs/
│   ├── rclone.conf             # [minio] and [ceph] remotes
│   ├── s3fs-passwd / -ceph     # creds (chmod 600 in setup)
│   └── fio/*.fio               # 4 workload profiles
├── scripts/
│   ├── setup.sh                # BACKEND-aware mount of /mnt/{rclone,s3fs}
│   ├── ceph-init.sh            # bootstrap user/bucket on RGW
│   ├── run-bench.sh            # all fio profiles × both tools
│   ├── tar-extract.sh          # 10000-file real-world workload
│   ├── profile.sh              # pprof + strace + tcpdump on a single rclone workload
│   ├── compare-backends.sh     # full both-backend run + cross-backend report
│   ├── collect.sh              # raw JSON → REPORT-{backend}.md + charts
│   ├── plot.py                 # matplotlib chart renderer
│   └── teardown.sh             # unmount + compose down
├── results/
│   ├── REPORT-minio.md         # MinIO numbers + charts
│   ├── REPORT-ceph.md          # Ceph numbers + charts
│   ├── REPORT-COMPARISON.md    # side-by-side
│   ├── charts/{minio,ceph}/    # PNG charts
│   ├── raw/{minio,ceph}/       # fio JSON + /usr/bin/time -v outputs
│   ├── phase1/                 # --s3-disable-checksum measurement
│   └── profiling/              # pprof + strace + tcpdump per workload
├── IMPROVEMENT-PLAN.md         # Phase 0/1/2/3 rclone improvement plan
└── README.md
```

## Future rounds

- **Tuned-vs-tuned.** Each tool with its recommended high-throughput config.
- **AWS S3 / Backblaze B2 / Cloudflare R2.** When real-cloud creds are
  available.
- **NetApp StorageGRID.** Production target. Awaiting test access.
- **Concurrent-mount stress.** N FUSE clients × M files; what does memory
  look like, what's the audit-log volume on the server side, what
  recovers cleanly when a backend node restarts.
- **Phase-1 patch attempt.** Incremental hashing in `vfs/vfscache` so the
  upload path doesn't have to re-read the cache file. Deferred until the
  wall-time benefit is reproducible on a non-local backend. Plan in
  [`IMPROVEMENT-PLAN.md`](IMPROVEMENT-PLAN.md).

## Contributing / feedback

Issues and PRs welcome. If you reproduce this on different hardware or
a different backend, please open an issue with the raw `results/` JSON.
The headline ratios are interesting only as long as they're verifiable.

## License

[MIT](LICENSE)
