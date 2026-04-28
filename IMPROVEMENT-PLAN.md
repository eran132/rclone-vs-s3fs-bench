# rclone improvement plan

Target: make `rclone mount` outperform `s3fs-fuse` on the lab's workload mix.
Publishing v1: this repo only. AWS pass deferred until creds arrive.

## Phase 0 — baseline + bottleneck diagnosis

Goal: a 1-page evidence brief naming the top 2-3 bottlenecks by workload.

| Step | What | Tool | Output |
|---|---|---|---|
| 0.1 | Default-fair lab run (in flight) | `run-bench.sh` + `tar-extract.sh` | `results/REPORT.md`, `results/raw/*.json` |
| 0.2 | CPU profile per workload | `profile.sh seq-write/seq-read/rand-rw/small-files` | `results/profiling/<p>/cpu.pprof` + `cpu-top.txt` + `cpu.svg` |
| 0.3 | Heap profile per workload | same | `heap.pprof`, `heap-top.txt` |
| 0.4 | Syscall histogram | strace -c during workload | `strace-summary.txt` |
| 0.5 | Network packet capture | tcpdump on :9000 | `minio.pcap`, `tcpdump-summary.txt` |
| 0.6 | Goroutine snapshot at peak | rclone rc | `goroutine.txt` |
| 0.7 | Synthesis | manual | `bottleneck-diagnosis.md` (this folder) |

Diagnostic questions Phase 0 must answer:
- Where does CPU time go for each workload? (FUSE marshaling, S3 SDK serialization, GC, crypto, copy, etc.)
- How many syscalls per MiB transferred? Read/write/stat/getxattr ratios.
- How many MinIO requests per workload? Are they parallel or serialized?
- How big are the GC pauses? Heap alloc rate?
- Is there a single goroutine bottleneck (mutex contention)?

## Phase 1 — low-effort wins (default + docs)

Each candidate below is ≤ ~200 LOC and stays within rclone's design. The
**chosen one** depends on Phase 0 evidence.

| Candidate | Triggered when | Implementation outline | Expected delta |
|---|---|---|---|
| Auto-promote `vfs-cache-mode off` → `writes` on first non-O_TRUNC open | Today rclone returns EPERM here. Easy "just works" win. | In `vfs/write.go` (or wherever `WriteFileHandle` lives), detect the EPERM path and auto-create a writes-mode handle for that file with a `--vfs-cache-mode-auto` opt-out flag. | Removes a footgun, no perf change directly but moves the default closer to "fair" |
| Larger default `--buffer-size` (16M → 64M) | Phase 0 shows sequential seq-write/read CPU-idle waiting on small reads | One-line default change + benchmark | +20–40% on seq-read |
| Default-on `--vfs-read-ahead` for `full` mode | Phase 0 shows readahead off-by-default leaves throughput on the table | Default flag value | +30%+ on seq-read with `full` |
| Connection-pool warmup at mount time | Phase 0 tcpdump shows the first N requests pay TLS handshake serially | At mount, fire a HEAD on bucket × N where N = `--transfers`. Tiny code change in `cmd/mount/`. | -2 to -5s first-request latency, mostly visible on cold mounts |
| Stat-cache pre-population on `readdir` | Phase 0 shows HEAD-per-stat after a listdir | When `readdir` returns entries, populate the stat cache from the listing's metadata so subsequent `Lstat()` is local. | Big win on tar-extract, find, ls -l |
| Negative stat cache (404 LRU) | Phase 0 shows `find` does many HEAD→404s | LRU of recently-404'd paths, invalidated on writes in the same dir | Big win on `find`, `git status` |

**Selection rule:** at least one of these MUST tie to a number from Phase 0 — no
"this should be fast" hand-waves. We ship the one with the largest measurable
delta in the lab.

## Phase 1 — workflow

1. Branch the rclone repo (we are already in it).
2. Implement the chosen change behind a flag (default-off until proven).
3. Build the patched binary inside the bench container (mount source, `go build`).
4. Re-run `run-bench.sh` against the patched mount. Capture before/after
   numbers in `results/raw/before/` and `results/raw/after/`.
5. If delta is significant (>5% on its target workload, no regression
   elsewhere), file a GitHub issue on rclone proposing the change. PR after
   maintainer interest is positive.
6. Whether or not it merges, the result lives in this repo's report.

## Out of scope for v1

- Phase 2 (kernel writeback cache, splice, multi-stream upload-on-close,
  HTTP/2 to S3). Each is its own design doc + larger PR.
- Phase 3 (architectural — io_uring, page-cache integration). Months of work
  and may not merge upstream.
- AWS / B2 / R2 cloud target runs.
- s3fs-fuse improvements (we evaluated; not the target).
- Public posting (blog / forum / HN).

## Working agreements

- One change at a time. Mixing two patches makes attribution impossible.
- Every change must show a number in the lab. "It feels faster" doesn't ship.
- Default-off flags first; default-on after a proven win + 2 reproductions.
- Don't regress any other workload. If a patch wins on seq-read but loses on
  small-files, that's a tradeoff doc, not a default change.
