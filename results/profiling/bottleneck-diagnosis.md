# rclone Phase 0 — bottleneck diagnosis

**Inputs:** [`results/REPORT.md`](../REPORT.md) (default-fair fio numbers) +
[`profiling/<workload>/`](.) (pprof + strace + tcpdump per workload) +
direct source verification of the hot path.

## Headline

The single dominant CPU hot path across 3 of 4 workloads is **MD5 hashing of
the cache file at upload time** — an unconditional re-read of the locally-cached
file before it is shipped to S3.

```
operations.Copy → multiThreadCopy → s3.OpenChunkWriter → s3.prepareUpload →
local.(*Object).Hash → hash.StreamTypes
```

This appears at **~70% cum** in `cpu.pprof` for `seq-read`, `rand-rw`, and
implicitly drives `seq-write` once the cache flushes. The seq-write own pprof
window captured FUSE write-path (76% in `bazil.org/fuse/fs.Server.serve`,
59% in `pwrite` to the cache disk) because the upload happens after the fio
timer ends — `tcpdump` confirmed only 14 packets to MinIO during the seq-write
capture window.

## Source confirmation

[`backend/local/local.go:1164-1184`](https://github.com/rclone/rclone/blob/master/backend/local/local.go#L1164-L1184)
is the actual code:

```go
if changed || !hashFound {
    var fd *os.File
    fd, err = file.Open(o.path)
    ...
    hashes, err = hash.StreamTypes(readers.NewContextReader(ctx, in), hash.NewHashSet(r))
}
```

Whenever the cache file's mtime/size is newer than the cached hash (i.e. always,
right after a write), rclone opens the file and runs the requested hash type
over its full contents. For seq-write 4 GiB, that's a 4 GiB sequential re-read
of the cache disk *immediately after* a 4 GiB write — pure CPU+disk overhead
on top of the actual S3 PUT.

## Phase 1 measurement: `--s3-disable-checksum`

[`backend/s3/s3.go:4880`](https://github.com/rclone/rclone/blob/master/backend/s3/s3.go#L4880) gates the hash for
multipart uploads behind the existing `--s3-disable-checksum` flag. So the
hypothesis is testable without code changes: if the hash is the bottleneck,
flipping that flag should produce a measurable speedup on multipart uploads.

**Test:** 3× `rclone copy` of a 4 GiB urandom file to MinIO, with and without
the flag, alternating to absorb thermal/cache noise. Same machine, same
network path, same backend. See
[`disable-checksum-rclone-copy.log`](../phase1/disable-checksum-rclone-copy.log).

| metric | checksum on (mean of 3) | checksum off (mean of 3) | delta |
|---|---:|---:|---:|
| **wall (s)** | 73.91 | 71.12 | -3.8% (noisy: -31% to +52% per-rep) |
| **user CPU (s)** | 56.74 | 41.56 | **-27%** |
| **sys CPU (s)** | 35.49 | 25.40 | **-28%** |
| max RSS (KB) | ~73,000 | ~74,000 | flat |

## Interpretation

- The **CPU savings are real and reproducible** (-27% user, -28% sys). The
  pprof story holds up under direct measurement.
- The **wall-time benefit is ambiguous on MinIO-local** because n=3 is not
  enough to overcome I/O jitter on the MinIO data path; the -22 s of CPU we
  saved is partially absorbed by the local disk's own variance.
- On a **more network-bound backend** (StorageGRID over LAN, or Ceph RGW with
  injected latency), CPU-saved-per-byte should convert more cleanly into
  wall-time-saved. We can't claim that delta from this run.
- This means the hash bottleneck is real for **CPU-constrained clients**
  (small VMs, many concurrent FUSE mounts on one host) and **less visible on
  a fast, local, single-tenant box**.

## Phase 1 decision

**Recommend documenting `--s3-disable-checksum` as a tuning option for
high-throughput backup/migration workloads where integrity is verified out of
band. Defer the incremental-hash code patch until we have a backend where the
wall-time signal is clean.** Three reasons:

1. The wall-time delta on MinIO-local is too noisy to defend in a publishable
   number. We'd be claiming a win we can't reproduce reliably.
2. The next planned backend (Ceph RGW with `tc netem` latency) is the natural
   place to re-run this test. If Ceph shows a clean wall delta, the
   incremental-hash patch becomes a real upstream contribution. If Ceph also
   shows noise, the patch is a CPU-only win and harder to motivate.
3. We should not blindly default `--s3-disable-checksum` on — it removes
   end-to-end integrity verification on the upload path. That's a real
   correctness tradeoff, not a free perf knob.

## Other candidates surfaced by Phase 0 (deferred)

- **AWS SDK middleware chain at 33% cum on small-files.** Per-PUT overhead in
  retry/sign/header middleware. Not rclone-controllable; would need upstream
  `aws-sdk-go-v2` work.
- **FUSE `Server.serve` at 76% on seq-write.** Per-op marshalling cost in
  `bazil.org/fuse`. The lever here is `FUSE_CAP_WRITEBACK_CACHE` so the kernel
  batches small writes — Phase 2 territory, larger PR.
- **`futex` saturation in strace.** 99.9% futex was an artifact of strace
  attaching only to the parent thread without `-f`. Profile harness fix queued.

## Profile-harness gaps to fix before re-running on Ceph

1. `strace -c -f` (follow forks/threads) instead of `strace -c`.
2. Pre-stage `seq-read` *before* opening the pprof window so the read pprof
   actually captures the read path, not the upload of the staged file.
3. Force a `vfs/forget` + drain wait *after* fio for `seq-write`, then take a
   second pprof — that captures the upload path that this run missed.
4. Increase pprof sample to 60 s for `rand-rw` (4m52s wall — 30 s window only
   sees a slice).
