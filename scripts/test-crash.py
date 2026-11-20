#!/usr/bin/env python3
"""Guest crash recovery on the real VM: a forced kernel panic (`echo c > /proc/sysrq-trigger`)
must reset the VM rather than leave it spinning, keep the console tail in guest-crash.log, and,
with containers running, boot a new VM that brings back `always` and `unless-stopped` containers
while `no` ones and one stopped with `docker stop` stay exited. Then: a second crash in a row
waits longer (backoff), a crash with nothing running leaves the VM stopped, and `dmx stop`
during the backoff cancels the reboot.

Runs in a throwaway DMX_HOME (its own data disk and daemon) with dmx's own docker CLI
(`dmx tools install`). Needs the guest with Docker in it and the internet (busybox). Host port
20181 is used. Prints one JSON object; exits non-zero if a check failed. About 2 minutes.

    python3 -I scripts/test-crash.py [path/to/dmx]
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
USER_DMX = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx")
DOCKER = str(USER_DMX / "bin" / "docker")
PORT = 20181

HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="dmx-crash-", dir="/tmp")))
(HOME / "guest").symlink_to(USER_DMX / "guest")
(HOME / "docker-config").mkdir()
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "BUILDX_", "COMPOSE_"))}
ENV.update(DMX_HOME=str(HOME), DOCKER_HOST=f"unix://{HOME}/docker.sock", DOCKER_CONFIG=str(HOME / "docker-config"),
           PATH="/usr/bin:/bin:/usr/sbin:/sbin")

checks = []
results = {}


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:400]})
    return ok


def progress(message):
    print(f"crash: {message}", file=sys.stderr, flush=True)


def dmx(*a, timeout=120):
    return subprocess.run([str(DMX), *a], capture_output=True, timeout=timeout, env=ENV)


def docker(*a, timeout=120):
    return subprocess.run([DOCKER, *a], capture_output=True, timeout=timeout, env=ENV)


def status():
    r = dmx("status", "--json", timeout=20)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {}


def daemon_pids():
    out = subprocess.run(["pgrep", "-f", f"{DMX} daemon"], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()
            if f"DMX_HOME={HOME}" in subprocess.run(["ps", "eww", "-o", "command=", "-p", p], capture_output=True, text=True).stdout]


def cpu_seconds(pid):
    """User plus system CPU time of a process, from ps's `time` (m:ss.cc or h:mm:ss)."""
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    total = 0.0
    for part in out.split(":"):
        total = total * 60 + float(part)
    return total


def running_names():
    r = docker("ps", "--format", "{{.Names}}", timeout=30)
    return set(r.stdout.decode().split()) if r.returncode == 0 else None


def states():
    r = docker("ps", "-a", "--format", "{{.Names}} {{.State}}", timeout=30)
    return dict(line.split(" ", 1) for line in r.stdout.decode().splitlines() if " " in line) if r.returncode == 0 else {}


def http_ok():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=2) as r:
            return r.read() == b"crash\n"
    except Exception:
        return False


def wait(predicate, limit):
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def crash():
    """Panics the guest kernel. exec ends when the VM goes away."""
    started = time.monotonic()
    r = dmx("exec", "--", "sh", "-c", "echo c > /proc/sysrq-trigger", timeout=30)
    return started, r


def crash_log():
    path = HOME / "logs" / "guest-crash.log"
    return path.read_text(errors="replace") if path.exists() else ""


BACK = {"c-always", "c-unless"}

try:
    if not check("docker_tools", os.access(DOCKER, os.X_OK), f"{DOCKER}; run `dmx tools install`"):
        raise SystemExit
    r = dmx("start", "--json")
    check("start", r.returncode == 0, r.stderr[-300:])
    pid = status().get("pid")
    check("daemon_pid", pid in daemon_pids(), f"status pid {pid}, daemons {daemon_pids()}")
    r = docker("pull", "busybox", timeout=300)
    check("pull", r.returncode == 0, r.stderr[-300:])
    web = ["sh", "-c", "mkdir -p /www; echo crash > /www/index.html; exec httpd -f -p 80 -h /www"]
    runs = [
        ["--name", "c-always", "--restart", "always", "-p", f"127.0.0.1:{PORT}:80", "busybox", *web],
        ["--name", "c-unless", "--restart", "unless-stopped", "busybox", "sleep", "3600"],
        ["--name", "c-no", "--restart", "no", "busybox", "sleep", "3600"],
        ["--name", "c-unless-stopped", "--restart", "unless-stopped", "busybox", "sleep", "3600"],
    ]
    for a in runs:
        r = docker("run", "-d", "--init", *a)
        check(f"run_{a[1]}", r.returncode == 0, r.stderr[-300:])
    r = docker("stop", "-t", "1", "c-unless-stopped")
    check("stop_c-unless-stopped", r.returncode == 0, r.stderr[-300:])
    check("port_before", wait(http_ok, 10), "")
    results["before_footprint_mb"] = status().get("host_footprint_mb")

    # 1. A panic with containers running: a new VM, and the right containers back.
    progress("crash 1: panic with 3 containers running")
    started, r = crash()
    results["crash1_exec_s"] = round(time.monotonic() - started, 1)
    check("exec_ends", results["crash1_exec_s"] < 20, f"{results['crash1_exec_s']} s, rc {r.returncode}")
    back = wait(lambda: status().get("state") == "running" and BACK <= (running_names() or set()), 90)
    results["crash1_back_s"] = round(time.monotonic() - started, 1)
    check("crash1_containers_back", back, f"after {results['crash1_back_s']} s: {states()}")
    s = status()
    crash_status = s.get("guest_crash") or {}
    results["crash1_status"] = crash_status
    check("same_daemon", s.get("pid") == pid, f"{pid} -> {s.get('pid')}")
    check("status_reason", "kernel reset" in crash_status.get("reason", ""), crash_status)
    check("status_streak_1", crash_status.get("streak") == 1, crash_status)
    st = states()
    results["crash1_states"] = st
    check("no_stays_exited", st.get("c-no", "").startswith("exited"), st)
    check("docker_stopped_stays_exited", st.get("c-unless-stopped", "").startswith("exited"), st)
    check("port_after", wait(http_ok, 15), "")
    text = crash_log()
    check("console_tail_kept", "sysrq triggered crash" in text and "=== guest crash" in text, text[-300:])
    check("console_tail_this_boot", text.count("--- dmx VM boot") == 1, f"{text.count('--- dmx VM boot')} boot markers")
    # The new VM runs normally: no CPU left spinning.
    c0 = cpu_seconds(pid)
    time.sleep(5)
    results["daemon_cpu_after_recovery_pct"] = round((cpu_seconds(pid) - c0) / 5 * 100)
    check("daemon_cpu_quiet", results["daemon_cpu_after_recovery_pct"] < 100, f"{results['daemon_cpu_after_recovery_pct']}%")
    results["after_footprint_mb"] = status().get("host_footprint_mb")

    # 2. Another one right away: twice the wait.
    progress("crash 2: right after the first")
    started, _ = crash()
    pending = wait(lambda: (status().get("guest_crash") or {}).get("streak") == 2 and status(), 15) or {}
    results["crash2_status"] = pending.get("guest_crash")
    log_text = (HOME / "logs" / "daemon.log").read_text(errors="replace")
    check("crash2_backoff", "booting a new VM in 2s" in log_text, [l for l in log_text.splitlines() if "guest crashed" in l][-2:])
    back = wait(lambda: status().get("state") == "running" and BACK <= (running_names() or set()), 90)
    results["crash2_back_s"] = round(time.monotonic() - started, 1)
    check("crash2_containers_back", back, f"after {results['crash2_back_s']} s: {states()}")

    # 3. `dmx stop` during the backoff: no reboot.
    progress("crash 3: dmx stop during the backoff")
    crash()
    wait(lambda: (status().get("guest_crash") or {}).get("streak") == 3, 15)
    r = dmx("stop", "--json")
    check("stop_during_backoff", r.returncode == 0, r.stderr[-300:])
    time.sleep(6)  # the reboot was due 4 s after the crash
    s = status()
    check("stop_cancels_reboot", s.get("state") == "stopped" and (s.get("guest_crash") or {}).get("reboot_in_s") is None, s.get("state"))

    # 4. Nothing running: the VM stays stopped until it is needed.
    progress("crash 4: nothing running")
    r = docker("stop", "-t", "1", "c-always", "c-unless")
    check("stop_all", r.returncode == 0, r.stderr[-300:])
    crash()
    wait(lambda: (status().get("guest_crash") or {}).get("streak") == 4, 15)
    time.sleep(10)
    s = status()
    check("idle_crash_stays_stopped", s.get("state") == "stopped" and (s.get("guest_crash") or {}).get("reboot_in_s") is None,
          f"{s.get('state')} {s.get('guest_crash')}")
    st = states()  # boots the VM for this client
    # As on any dockerd start: `always` comes back even after `docker stop`, the others do not.
    check("idle_crash_containers_stay_stopped", all(st.get(n, "").startswith("exited") for n in ("c-unless", "c-no", "c-unless-stopped")), st)
    check("idle_crash_always_back_on_next_start", st.get("c-always") == "running", st)
    check("same_daemon_at_end", status().get("pid") == pid, "")
except subprocess.TimeoutExpired as e:
    check("no_timeout", False, f"{e.cmd} timed out after {e.timeout} s")
except SystemExit:
    pass
finally:
    try:
        dmx("stop", timeout=60)
    except Exception:
        pass
    for p in daemon_pids():
        os.kill(p, signal.SIGTERM)
    deadline = time.time() + 20
    while daemon_pids() and time.time() < deadline:
        time.sleep(0.2)
    if all(c["ok"] for c in checks):
        subprocess.run(["rm", "-rf", str(HOME)])
    else:
        results["home"] = str(HOME)

results["checks"] = checks
results["passed"] = sum(c["ok"] for c in checks)
results["failed"] = [c for c in checks if not c["ok"]]
print(json.dumps(results, indent=2))
sys.exit(0 if all(c["ok"] for c in checks) else 1)
