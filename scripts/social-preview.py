#!/usr/bin/env python3
"""Render the GitHub social-preview image (1280x640) from the bench results.

Side-by-side throughput chart for MinIO and Ceph, plus a title bar.
Run inside the bench container (matplotlib is installed there).

Usage:
    docker compose exec bench python3 /lab/scripts/social-preview.py
"""
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

RAW = Path("/lab/results/raw")
OUT = Path("/lab/.github/social-preview.png")

PROFILES = ["seq-read", "seq-write", "rand-rw", "small-files"]
TOOLS = ["rclone", "s3fs"]
COLORS = {"rclone": "#1f77b4", "s3fs": "#ff7f0e"}


def bw_for(backend: str, tool: str, profile: str) -> float:
    f = RAW / backend / f"{tool}-{profile}.json"
    if not f.exists():
        return 0.0
    data = json.loads(f.read_text())
    job = data["jobs"][0]
    side = job["write"] if job["write"]["bw_bytes"] > 0 else job["read"]
    return side["bw_bytes"] / 1_048_576


def panel(ax, backend: str, title: str):
    width = 0.35
    x = list(range(len(PROFILES)))
    for i, tool in enumerate(TOOLS):
        vals = [bw_for(backend, tool, p) for p in PROFILES]
        ax.bar(
            [xi + (i - 0.5) * width for xi in x],
            vals, width, label=tool, color=COLORS[tool],
        )
    ax.set_xticks(x)
    ax.set_xticklabels(PROFILES, rotation=15, ha="right", fontsize=11)
    ax.set_ylabel("MB/s", fontsize=11)
    ax.set_title(title, fontsize=14, weight="bold")
    ax.legend(loc="upper right", fontsize=10)
    ax.grid(axis="y", linestyle=":", alpha=0.4)


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12.8, 6.4), dpi=100)
    panel(ax1, "minio", "MinIO")
    panel(ax2, "ceph", "Ceph RGW")
    fig.suptitle(
        "rclone mount vs s3fs-fuse — throughput by workload (higher is better)",
        fontsize=15, weight="bold", y=0.98,
    )
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    fig.savefig(OUT, dpi=100, bbox_inches="tight", facecolor="white")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
