#!/usr/bin/env python3
"""Check that the daemon keeps the guest clock on the host's, on the real VM, in a throwaway DMX_HOME.

The guest's counter stands still while the Mac sleeps, and the guest does not follow the Mac's
clock when macOS sets it, so the daemon sets the guest clock (Daemon/GuestClock.swift). This
checks the two halves that do not need the Mac to sleep:

  step:  a guest clock an hour behind is set to the host's within the periodic sync (60 s,
         checked every 15 s) and the daemon logs it;
  slew:  a guest 50 ms ahead is slewed back at 0.5 ms/s by the next periodic sync, with
         CLOCK_REALTIME never going backwards (needs an agent built from this source and a
         Docker image pull; a guest from before the slew steps back, and this check fails).

The guest files come from $DMX_HOME/guest (default ~/.dmx/guest). About 3 minutes.

    python3 -I scripts/test-clock.py [path/to/dmx]
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
IMAGE = "python:3-alpine"

# Runs in the container: sets the clock 50 ms ahead, then watches CLOCK_REALTIME against
# CLOCK_MONOTONIC_RAW, which no slew touches (CLOCK_MONOTONIC is slewed with the realtime clock).
PROBE = r"""
import json, time
raw = lambda: time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
time.clock_settime(time.CLOCK_REALTIME, time.time() + 0.05)
start = raw(); base = time.time() - start; prev = time.time(); back = 0.0
while raw() - start < 130:
    now = time.time(); back = max(back, prev - now); prev = now
    time.sleep(0.001)
print(json.dumps({"moved_ms": (time.time() - raw() - base) * 1000, "worst_back_ms": back * 1000}))
"""

checks = []


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})


def dmx(*args, timeout=120):
    return subprocess.run([str(DMX), *args], capture_output=True, text=True, timeout=timeout, env=ENV)


def guest_offset():
    """Guest clock minus host clock in whole seconds, from `dmx exec date`."""
    host = time.time()
    return int(dmx("exec", "--", "date", "+%s").stdout) - int(host)


def clock_log():
    log = HOME / "logs" / "daemon.log"
    return [line for line in log.read_text().splitlines() if "clock:" in line] if log.exists() else []


HOME = Path(tempfile.mkdtemp(prefix="dmx-clock-", dir=os.path.realpath("/tmp")))
ENV = {**os.environ, "DMX_HOME": str(HOME), "DOCKER_HOST": f"unix://{HOME}/docker.sock"}
(HOME / "guest").symlink_to(GUEST)
try:
    started = dmx("start", "--json")
    check("start", started.returncode == 0, started.stderr.strip()[-200:])

    dmx("exec", "--", "date", "-s", f"@{int(time.time()) - 3600}")
    behind = guest_offset()
    began = time.time()
    while time.time() - began < 90 and abs(guest_offset()) > 1:
        time.sleep(3)
    took = time.time() - began
    logged = [line for line in clock_log() if "periodic" in line and "behind" in line]
    check("step", behind <= -3599 and abs(guest_offset()) <= 1 and logged,
          f"guest {behind} s off before, set after {took:.0f} s; log: {logged[-1:] or 'none'}")

    pulled = subprocess.run(["docker", "pull", "-q", IMAGE], capture_output=True, text=True, timeout=300, env=ENV)
    probe = subprocess.run(["docker", "run", "--rm", "--cap-add", "SYS_TIME", IMAGE, "python3", "-c", PROBE],
                           capture_output=True, text=True, timeout=240, env=ENV)
    try:
        result = json.loads(probe.stdout)
    except ValueError:
        result = {}
    # Slewed: the clock ended earlier than where it was set, by 0.5 ms/s since the sync, and never stepped back.
    ok = pulled.returncode == 0 and result and result["worst_back_ms"] < 1 and -60 < result["moved_ms"] < -5
    check("slew", ok, json.dumps(result) if result else (probe.stderr or pulled.stderr).strip()[-300:])
finally:
    dmx("stop")
    shutil.rmtree(HOME, ignore_errors=True)

print(json.dumps({"ok": all(c["ok"] for c in checks), "checks": checks}, indent=2))
sys.exit(0 if all(c["ok"] for c in checks) else 1)
