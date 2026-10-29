#!/usr/bin/env python3
"""Measure the running menu process only; leave its menu closed during the sample."""
import argparse
import importlib.util
import json
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("benchmark", Path(__file__).with_name("benchmark.py"))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("pid", type=int, help="the PID of dmx-menu, not the VM daemon")
parser.add_argument("--seconds", type=float, default=45)
args = parser.parse_args()
if not 1 <= args.seconds <= 300:
    parser.error("--seconds must be between 1 and 300")
reader_check = benchmark.check_cpu_reader()
pressure_before = benchmark.pressure()
before = benchmark.usage(args.pid)
started = time.monotonic()
time.sleep(args.seconds)
after = benchmark.usage(args.pid)
elapsed = time.monotonic() - started
print(json.dumps({
    "scope": "menu process only, engine excluded", "interval_s": elapsed,
    "before": before, "after": after,
    "cpu_percent_one_core": 100 * (after["cpu_s"] - before["cpu_s"]) / elapsed,
    "host_pressure_before": pressure_before, "host_pressure_after": benchmark.pressure(),
    "cpu_reader_check": reader_check,
    "instruction": "No UI interaction during sample; memory is ri_phys_footprint in MiB.",
}, indent=2))
