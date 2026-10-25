#!/usr/bin/env python3
"""Guest memory and disk integrity while macOS is short of memory, in a throwaway DMX_HOME.

A helper process holds incompressible memory (default: three quarters of the Mac's RAM) so that
macOS compresses and swaps other processes, the VM's guest RAM among them, and busy loops take
half the cores (memory pressure alone rarely showed the bug; with the CPU busy too, most rounds
did). Meanwhile the guest
boots again and again with a damaged superblock, so /init runs `e2fsck -fy`, which reads much of
the disk: the workload that crashed the guest kernel and lost files while the Mac swapped, when
virtio-blk did direct I/O on guest pages (2026-10-25: 18 of 28 boots). Each round checks that the
guest answered, a file written before survived, and the console shows no kernel oops.

Not part of the release checks: the Mac swaps for a few minutes and other programs slow down.
Prints one JSON object and exits non-zero if a check failed.

    python3 -I scripts/test-pressure.py [path/to/dmx] [--rounds N] [--gb G]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOG = r"""
import os, sys, time
chunks = [bytearray(os.urandom(64 << 20)) for _ in range(int(float(sys.argv[1]) * 16))]
print("ready", flush=True)
while True:  # keep the pages in use so that macOS pushes others out instead
    for b in chunks:
        for i in range(0, len(b), 49152):
            b[i] ^= 1
"""

parser = argparse.ArgumentParser()
parser.add_argument("dmx", nargs="?", default=".build/release/dmx")
parser.add_argument("--rounds", type=int, default=12)
parser.add_argument("--gb", type=float)
args = parser.parse_args()
DMX = Path(args.dmx).resolve()
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
ram_gb = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) / (1 << 30)
hog_gb = args.gb or round(ram_gb * 0.75)

HOME = Path(tempfile.mkdtemp(prefix="dmx-pressure-", dir="/tmp"))
(HOME / "guest").symlink_to(GUEST)
ENV = dict(os.environ, DMX_HOME=str(HOME))
checks = []
results = {"hog_gb": hog_gb, "rounds": args.rounds}


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})


def dmx(*a, timeout=60):
    try:
        return subprocess.run([str(DMX), *a], capture_output=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        return None


def stopped():
    """Stops the VM and waits until it is gone: after a crash the daemon is still waiting for the
    agent, and the disk must not change under a running guest."""
    for _ in range(150):
        dmx("stop")
        r = dmx("status", "--json")
        if r and json.loads(r.stdout or b"{}").get("state") == "stopped":
            return True
        time.sleep(1)
    return False


hog, burners = None, []
try:
    dmx("config", "set", "shares", "none")
    r = dmx("exec", "--", "sh", "-c", "echo kept > /var/lib/marker && sync")
    check("setup", r is not None and r.returncode == 0, repr(r and r.stderr))
    hog = subprocess.Popen([sys.executable, "-I", "-c", HOG, str(hog_gb)], stdout=subprocess.PIPE)
    hog.stdout.readline()
    cores = int(subprocess.run(["sysctl", "-n", "hw.ncpu"], capture_output=True, text=True).stdout)
    burners = [subprocess.Popen(["yes"], stdout=subprocess.DEVNULL) for _ in range(cores // 2)]
    results["free_percent_under_pressure"] = int(
        subprocess.run(["memory_pressure", "-Q"], capture_output=True, text=True).stdout.split()[-1].rstrip("%"))
    failures = []
    for i in range(args.rounds):
        if not stopped():
            failures.append(f"round {i}: the VM did not stop")
            break
        with open(HOME / "data.img", "r+b") as image:
            image.seek(1024 + 12)  # s_free_blocks_count_lo: the superblock checksum no longer matches
            image.write((12345 + i).to_bytes(4, "little"))
        r = dmx("exec", "--", "cat", "/var/lib/marker", timeout=60)
        console = (HOME / "logs" / "console.log").read_text(errors="replace")
        oops = [l for l in console.splitlines() if "Unable to handle" in l or "Internal error" in l or "Kernel panic" in l]
        if r is None or r.stdout != b"kept\n" or oops:
            failures.append(f"round {i}: " + ("no answer" if r is None else repr(r.stdout + r.stderr)[:120]) + (f", {oops[0][:100]}" if oops else ""))
    check("integrity_under_pressure", not failures, failures)
finally:
    for p in burners + ([hog] if hog else []):
        p.kill()
    stopped()
    for pid in subprocess.run(["lsof", "-t", str(HOME / "daemon.lock")], capture_output=True, text=True).stdout.split():
        os.kill(int(pid), 15)
    shutil.rmtree(HOME, ignore_errors=True)

ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
