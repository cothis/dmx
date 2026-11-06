#!/usr/bin/env python3
"""Check that the daemon keeps the guest clock on the host's, on the real VM, in a throwaway DMX_HOME.

The guest's counter stands still while the Mac sleeps, and the guest does not follow the Mac's
clock when macOS sets it, so the daemon sets the guest clock (Daemon/GuestClock.swift). This
checks the two halves that do not need the Mac to sleep:

  step:  a guest clock an hour behind is set to the host's within the periodic sync (60 s,
         checked every 15 s) and the daemon logs it;
  slew:  a guest 50 ms ahead is slewed back at 0.5 ms/s by the next periodic sync, with
         CLOCK_REALTIME never going backwards (needs an agent built from this source and a
         Docker image pull; a guest from before the slew steps back, and this check fails);
  stale: with dmx-agent stopped for 1.5 s at a time, a sync that waits behind it must not set
         the clock to the time it was sent, which steps it back by the wait (0.4.7's first
         version did; measuring, then moving the clock relatively does not).

The guest files come from $DMX_HOME/guest (default ~/.dmx/guest). About 3 minutes.

    python3 -I scripts/test-clock.py [path/to/dmx]
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
IMAGE = "python:3-alpine"

# Watches CLOCK_REALTIME for steps back while the agent is paused again and again.
WATCH = r"""
import json, time
start = time.monotonic(); prev = time.time(); back = 0.0
while time.monotonic() - start < 100:
    now = time.time(); back = max(back, prev - now); prev = now
    time.sleep(0.001)
print(json.dumps({"worst_back_ms": back * 1000}))
"""
PAUSE = "a=$(pidof dmx-agent); i=0; while [ $i -lt 55 ]; do kill -STOP $a; sleep 1.5; kill -CONT $a; sleep 0.2; i=$((i+1)); done"

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


class HostSteps:
    """The Mac's own clock going back while a check runs: macOS's timed steps it after an NTP
    answer (seen twice an hour apart on this Mac, -2.05 and -1.86 s), and the guest rightly
    follows. A guest step back is dmx's fault only beyond what the host did."""

    def __enter__(self):
        self.back, self.done = 0.0, False
        self.thread = threading.Thread(target=self.watch, daemon=True)
        self.thread.start()
        return self

    def watch(self):
        prev = time.time()
        while not self.done:
            now = time.time()
            self.back = max(self.back, prev - now)
            prev = now
            time.sleep(0.001)

    def __exit__(self, *_):
        self.done = True
        self.thread.join()

    @property
    def ms(self):
        return self.back * 1000


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
    with HostSteps() as host:
        probe = subprocess.run(["docker", "run", "--rm", "--cap-add", "SYS_TIME", IMAGE, "python3", "-c", PROBE],
                               capture_output=True, text=True, timeout=240, env=ENV)
    try:
        result = json.loads(probe.stdout)
    except ValueError:
        result = {}
    # Slewed: the clock ended earlier than where it was set, by 0.5 ms/s since the sync, and never stepped back.
    ok = pulled.returncode == 0 and result and result["worst_back_ms"] < (host.ms + 50 if host.ms else 1) and (host.ms > 0 or -60 < result["moved_ms"] < -5)
    check("slew", ok, (json.dumps(result) if result else (probe.stderr or pulled.stderr).strip()[-300:]) + f"; host stepped back {host.ms:.1f} ms")

    with HostSteps() as host:
        watch = subprocess.Popen(["docker", "run", "--rm", IMAGE, "python3", "-c", WATCH],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
        time.sleep(3)
        paused = dmx("exec", "--", "sh", "-c", PAUSE, timeout=200)
        out, err = watch.communicate(timeout=200)
    try:
        result = json.loads(out)
    except ValueError:
        result = {}
    stale = [line for line in clock_log() if "ahead" in line or "behind" in line][-2:]
    # Following a host step back is right, plus a quick measurement's 50 ms; otherwise nothing may go back.
    check("stale", paused.returncode == 0 and result and result["worst_back_ms"] < (host.ms + 50 if host.ms else 1),
          (json.dumps(result) if result else err.strip()[-300:]) + f"; host stepped back {host.ms:.1f} ms; log: {stale}")
finally:
    dmx("stop")
    shutil.rmtree(HOME, ignore_errors=True)

print(json.dumps({"ok": all(c["ok"] for c in checks), "checks": checks}, indent=2))
sys.exit(0 if all(c["ok"] for c in checks) else 1)
