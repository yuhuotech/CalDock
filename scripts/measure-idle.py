#!/usr/bin/env python3
"""Measure CPU-time deltas and RSS of one running CalDock, without permissions."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("pid", type=int)
parser.add_argument("--seconds", type=int, default=20)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
if not 1 <= args.seconds <= 60:
    parser.error("--seconds must be between 1 and 60")


def snapshot():
    output = subprocess.check_output(
        ["ps", "-p", str(args.pid), "-o", "time=,rss="], text=True
    ).split()
    parts = output[0].split(":")
    cpu = sum(float(part) * 60 ** index for index, part in enumerate(reversed(parts)))
    return {"cpu_seconds": cpu, "rss_mib": round(int(output[1]) / 1024, 2)}


start = snapshot()
began = time.monotonic()
time.sleep(args.seconds)
end = snapshot()
elapsed = time.monotonic() - began
report = {
    "pid": args.pid,
    "sample_seconds": round(elapsed, 3),
    "average_cpu_percent_one_core": round(max(0, end["cpu_seconds"] - start["cpu_seconds"]) / elapsed * 100, 3),
    "start": start,
    "end": end,
    "note": "RSS includes shared/mapped pages; use footprint for physical footprint. Short samples are not battery-life benchmarks.",
}
rendered = json.dumps(report, ensure_ascii=False, indent=2)
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered + "\n")
print(rendered)
