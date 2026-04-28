# rclone vs s3fs-fuse — benchmark report (backend: minio)

Generated: 2026-04-26T09:52:27Z

Backend: `minio` (local docker-compose), bucket `bench`.
Both tools run inside the same Ubuntu 24.04 container with default settings.

## Throughput & latency (fio)

| profile | tool | bw_MBps | iops | lat_avg_ms | lat_p99_ms |
|---|---|---:|---:|---:|---:|
| rand-rw | rclone | 4.14 | 1058.99 | 0.28 | 0.57 |
| rand-rw | s3fs | 0.11 | 27.39 | 28.14 | 120.06 |
| seq-read | rclone | 105.81 | 105.81 | 9.44 | 40.11 |
| seq-read | s3fs | 89.34 | 89.34 | 11.18 | 354.42 |
| seq-write | rclone | 104.03 | 104.03 | 9.54 | 36.44 |
| seq-write | s3fs | 28.74 | 28.74 | 7.86 | 71.83 |
| small-files | rclone | 1.82 | 116.17 | 0.86 | 7.57 |
| small-files | s3fs | 0.16 | 10.14 | 0.23 | 0.44 |

## Wall-time & CPU (/usr/bin/time -v)

| run | tool | wall | user_s | sys_s | max_rss_KB |
|---|---|---:|---:|---:|---:|
| rand-rw | rclone | 4:52.66 | 5.19 | 47.51 | 29552 |
| rand-rw | s3fs | 2:03:47 | 17.41 | 71.29 | 29448 |
| seq-read | rclone | 0:39.39 | 0.26 | 4.49 | 29452 |
| seq-read | s3fs | 0:46.66 | 0.25 | 5.49 | 29440 |
| seq-write | rclone | 0:46.04 | 0.56 | 10.51 | 29484 |
| seq-write | s3fs | 2:26.01 | 1.05 | 10.15 | 29276 |
| small-files | rclone | 1:44.24 | 1.98 | 13.55 | 34248 |
| small-files | s3fs | 19:23.09 | 2.84 | 10.04 | 34132 |
| tar-extract | rclone | 0:47.63 | 1.09 | 5.55 | 2624 |
| tar-extract | s3fs | 11:12.13 | 0.92 | 4.34 | 2588 |

## Charts

![throughput](charts/throughput.png)

![latency](charts/latency.png)
