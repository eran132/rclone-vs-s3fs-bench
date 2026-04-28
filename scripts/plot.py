#!/usr/bin/env python3
"""Plot throughput + latency charts from fio JSON results.

Usage: plot.py <raw_dir> <out_dir>
"""
import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def parse(raw_dir: Path):
    rows = []
    for f in sorted(raw_dir.glob("*.json")):
        tool, profile = f.stem.split("-", 1)
        data = json.loads(f.read_text())
        job = data["jobs"][0]
        side = job["write"] if job["write"]["bw_bytes"] > 0 else job["read"]
        rows.append({
            "tool": tool,
            "profile": profile,
            "bw_MBps": side["bw_bytes"] / 1_048_576,
            "iops": side["iops"],
            "lat_avg_ms": side["clat_ns"]["mean"] / 1_000_000,
            "lat_p99_ms": side["clat_ns"].get("percentile", {}).get("99.000000", 0) / 1_000_000,
        })
    return rows


def grouped_bar(rows, key, ylabel, title, out):
    profiles = sorted({r["profile"] for r in rows})
    tools = ["rclone", "s3fs"]
    width = 0.35
    x = range(len(profiles))

    fig, ax = plt.subplots(figsize=(8, 5))
    for i, tool in enumerate(tools):
        vals = []
        for p in profiles:
            v = next((r[key] for r in rows if r["tool"] == tool and r["profile"] == p), 0)
            vals.append(v)
        ax.bar([xi + (i - 0.5) * width for xi in x], vals, width, label=tool)
    ax.set_xticks(list(x))
    ax.set_xticklabels(profiles, rotation=20, ha="right")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend()
    ax.grid(axis="y", linestyle=":", alpha=0.5)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)
    print(f"wrote {out}")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    raw = Path(sys.argv[1])
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)

    rows = parse(raw)
    if not rows:
        print("no rows — nothing to plot")
        return

    grouped_bar(rows, "bw_MBps", "MB/s", "Throughput by profile (higher = better)", out / "throughput.png")
    grouped_bar(rows, "lat_avg_ms", "ms", "Mean completion latency (lower = better)", out / "latency.png")


if __name__ == "__main__":
    main()
