# rclone vs s3fs-fuse — benchmark report (backend: ceph)

Generated: 2026-04-28T07:54:08Z

Backend: `ceph` (local docker-compose), bucket `bench`.
Both tools run inside the same Ubuntu 24.04 container with default settings.

## Throughput & latency (fio)

| profile | tool | bw_MBps | iops | lat_avg_ms | lat_p99_ms |
|---|---|---:|---:|---:|---:|
| rand-rw | rclone | 3.92 | 1004.36 | 0.3 | 0.59 |
| rand-rw | s3fs | 0.11 | 27.51 | 27.92 | 104.33 |
| seq-read | rclone | 86 | 86 | 11.61 | 56.89 |
| seq-read | s3fs | 80.7 | 80.7 | 12.38 | 333.45 |
| seq-write | rclone | 114.99 | 114.99 | 8.63 | 25.03 |
| seq-write | s3fs | 32.91 | 32.91 | 10.35 | 52.69 |
| small-files | rclone | 1.31 | 84.1 | 0.87 | 7.9 |
| small-files | s3fs | 0.11 | 7.03 | 0.29 | 0.69 |

## Wall-time & CPU (/usr/bin/time -v)

| run | tool | wall | user_s | sys_s | max_rss_KB |
|---|---|---:|---:|---:|---:|
| rand-rw | rclone | 5:50.73 | 5.54 | 68.01 | 29160 |
| rand-rw | s3fs | 1:59:52 | 16.66 | 70.73 | 29396 |
| seq-read | rclone | 0:48.56 | 0.54 | 5.49 | 29432 |
| seq-read | s3fs | 0:51.43 | 0.21 | 4.83 | 29164 |
| seq-write | rclone | 0:36.20 | 0.39 | 10.48 | 29460 |
| seq-write | s3fs | 2:05.50 | 0.80 | 12.07 | 29544 |
| small-files | rclone | 2:12.13 | 2.06 | 13.82 | 34208 |
| small-files | s3fs | 28:04.79 | 4.09 | 14.36 | 34048 |
| tar-extract | rclone | 0:51.08 | 1.12 | 6.57 | 2580 |
| tar-extract | s3fs | 29:06.21 | 0.90 | 6.34 | 2612 |

## Charts

![throughput](charts/throughput.png)

![latency](charts/latency.png)
