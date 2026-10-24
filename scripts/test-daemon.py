#!/usr/bin/env python3
"""Exercise the dmx daemon end to end on the real VM, in a throwaway DMX_HOME.

The guest files come from $DMX_HOME/guest (default ~/.dmx/guest, symlinked), so run
`make guest` first. Starts no
launchd job; `dmx install` is tested by hand (it writes ~/Library/LaunchAgents). Prints one
JSON object and exits non-zero if any check failed.

    python3 -I scripts/test-daemon.py [path/to/dmx]
"""

import hashlib
import json
import os
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
# The guest of the DMX_HOME this script was started with (default ~/.dmx).
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"

checks = []


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})


def dmx(*args, stdin=None, timeout=60):
    return subprocess.run([str(DMX), *args], input=stdin, capture_output=True, timeout=timeout, env=ENV)


def status():
    return json.loads(dmx("status", "--json").stdout)


def daemon_pids():
    out = subprocess.run(["pgrep", "-f", f"{DMX} daemon"], capture_output=True, text=True).stdout
    pids = []
    for pid in out.split():
        env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if f"DMX_HOME={HOME}" in env:
            pids.append(int(pid))
    return pids


def wait_for(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.1)
    return False


def through_pty(argv, script):
    """Runs argv on a pty, sending each (delay, bytes) of script; returns output and exit code."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(argv[0], argv, ENV)
    out = b""

    def drain(seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    return

    for delay, data in script:
        drain(delay)
        try:
            os.write(fd, data)
        except OSError:
            break
    drain(2)
    _, code = os.waitpid(pid, 0)
    os.close(fd)
    return out.decode(errors="replace"), os.waitstatus_to_exitcode(code)


def daemon_call(method, params):
    """One request on the control socket, without the CLI (for methods it has no command for)."""
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(str(HOME / "dmx.sock"))
        body = json.dumps({"id": 1, "method": method, "params": params}).encode()
        s.sendall(struct.pack(">I", len(body) + 1) + b"\0" + body)
        data = b""
        while len(data) < 4 or len(data) < 4 + struct.unpack(">I", data[:4])[0]:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        return json.loads(data[5:])


def memory_checks(results):
    """Idle trim, trims and the balloon under simulated host pressure, footprint coming back."""
    def memory():
        s = status()
        return s.get("host_footprint_mb") or 0, s.get("memory") or {}

    # 512 MB of clean page cache: an empty zram block device read through, held open so the
    # kernel keeps its cache after dd exits. Reading zeros from zram costs zram nothing.
    fill = ("n=$(cat /sys/class/zram-control/hot_add); echo 1G >/sys/block/zram$n/disksize; "
            "setsid sleep 1000 </dev/zram$n >/dev/null 2>&1 & dd if=/dev/zram$n of=/dev/null bs=1M count=512 2>/dev/null")
    daemon_call("simulate_pressure", {"level": "normal"})
    time.sleep(3)
    idle, _ = memory()
    dmx("exec", "--", "sh", "-c", fill)
    full, m = memory()
    check("memory_cache_filled", m.get("guest_cache_mb", 0) >= 500 and full >= idle + 400, f"footprint {idle} -> {full} MB, {m}")

    # Warning: the guest trims at once.
    daemon_call("simulate_pressure", {"level": "warning"})
    started = time.time()
    back = wait_for(lambda: memory()[0] < idle + 64, 15)
    results["memory_warning_trim_s"] = round(time.time() - started, 1)
    fp, m = memory()
    check("memory_trim_on_warning", back and (m.get("last_trim") or {}).get("reason") == "host pressure warning",
          f"footprint {fp} MB, {m}")

    # Idle: under pressure the guest trims after 5 s without an exec (30 s without pressure).
    dmx("exec", "--", "sh", "-c", fill)
    started = time.time()
    back = wait_for(lambda: memory()[0] < idle + 64, 20)
    results["memory_idle_trim_s"] = round(time.time() - started, 1)
    fp, m = memory()
    check("memory_idle_trim", back and (m.get("last_trim") or {}).get("reason") == "idle", f"footprint {fp} MB, {m}")

    # Critical: zram swap goes on and the balloon caps the guest; normal deflates it.
    daemon_call("simulate_pressure", {"level": "critical"})
    inflated = wait_for(lambda: (memory()[1].get("balloon_mb") or 0) > 1024, 15)
    fp, m = memory()
    results["memory_critical_footprint_mb"] = fp
    check("memory_balloon_on_critical", inflated and fp < idle + 64, f"footprint {fp} MB, {m}")
    daemon_call("simulate_pressure", {"level": "normal"})
    deflated = wait_for(lambda: memory()[1].get("balloon_mb") == 0, 15)
    check("memory_balloon_deflated", deflated, str(memory()[1]))
    daemon_call("simulate_pressure", {"level": None})


# A short path: Unix socket paths are limited to 104 bytes.
HOME = Path(tempfile.mkdtemp(prefix="dmx-test-", dir="/tmp"))
ENV = {**os.environ, "DMX_HOME": str(HOME)}
(HOME / "guest").symlink_to(GUEST)
results = {}
try:
    s = status()
    check("not_running", s["state"] == "not_running" and not daemon_pids(), s["state"])

    started = time.time()
    r = dmx("exec", "--", "uname", "-r")
    results["cold_exec_ms"] = int((time.time() - started) * 1000)
    check("cold_exec", r.returncode == 0 and r.stdout.strip(), f"{r.stdout!r} rc {r.returncode}")

    s = status()
    results["idle_footprint_mb"] = s.get("host_footprint_mb")
    results["guest_used_mb"] = s.get("guest_used_mb")
    check("running", s["state"] == "running" and s["launchd"] is False, s["state"])

    started = time.time()
    r = dmx("exec", "--", "true")
    results["warm_exec_ms"] = int((time.time() - started) * 1000)

    r = dmx("exec", "--", "sh", "-c", "echo out; echo err >&2; exit 7")
    check("exit_and_streams", r.returncode == 7 and r.stdout == b"out\n" and r.stderr == b"err\n", repr(r))

    r = dmx("exec", "-e", "A=b", "-w", "/tmp", "--", "sh", "-c", 'echo "$A $(pwd)"')
    check("env_and_cwd", r.stdout == b"b /tmp\n", repr(r.stdout))

    data = os.urandom(64 << 20)
    r = dmx("exec", "--", "md5sum", stdin=data)
    check("stdin_64mb", r.stdout.split()[:1] == [hashlib.md5(data).hexdigest().encode()], repr(r.stdout[:40]))

    started = time.time()
    r = dmx("exec", "--", "head", "-c", "500000000", "/dev/zero")
    seconds = time.time() - started
    results["stdout_500mb_mb_per_s"] = int(500 / seconds)
    check("stdout_500mb", len(r.stdout) == 500000000, str(len(r.stdout)))
    results["footprint_after_streams_mb"] = status().get("host_footprint_mb")

    r = dmx("exec", "--", "nosuch")
    check("missing_binary", r.returncode == 1 and b"nosuch" in r.stderr, repr(r.stderr))

    # SIGTERM to dmx is passed to the guest process, which decides how to exit.
    p = subprocess.Popen([str(DMX), "exec", "--", "sh", "-c", 'trap "echo term; exit 5" TERM; while :; do sleep 0.1; done'],
                         stdout=subprocess.PIPE, env=ENV)
    time.sleep(1)
    p.send_signal(signal.SIGTERM)
    out, _ = p.communicate(timeout=10)
    check("signal_forwarded", p.returncode == 5 and out == b"term\n", f"rc {p.returncode} {out!r}")

    # A client that dies takes its guest process with it.
    p = subprocess.Popen([str(DMX), "exec", "--", "sleep", "1234"], env=ENV)
    time.sleep(1)
    p.kill()
    p.wait()
    gone = wait_for(lambda: b"sleep 1234" not in dmx("exec", "--", "ps", "-o", "args").stdout, 5)
    check("client_killed", gone, "guest process ended" if gone else "guest process still running")

    out, code = through_pty([str(DMX), "shell"], [
        (1.0, b"echo $((6*7))\n"),
        (0.3, b"sleep 100\n"),
        (0.5, b"\x03"),
        (0.5, b"echo after-$((1+1))\n"),
        (0.3, b"exit 3\n"),
    ])
    check("shell_tty", code == 3 and "42" in out and "^C" in out and "after-2" in out, f"rc {code} {out[-200:]!r}")

    # Memory controller (MemoryController.swift), with the host's pressure level simulated.
    memory_checks(results)

    # Concurrent cold starts end with one daemon.
    dmx("stop")
    pid = daemon_pids()
    wait_for(lambda: not daemon_pids(), 15)
    procs = [subprocess.Popen([str(DMX), "exec", "--", "echo", str(i)], stdout=subprocess.PIPE, env=ENV) for i in range(8)]
    outs = [p.communicate(timeout=60)[0] for p in procs]
    check("concurrent_cold_start", all(o == f"{i}\n".encode() for i, o in enumerate(outs)) and len(daemon_pids()) == 1,
          f"{len(daemon_pids())} daemons")

    # Stop then start again in the same daemon process.
    pid = daemon_pids()
    s = json.loads(dmx("stop", "--json").stdout)
    results["footprint_stopped_mb"] = s.get("host_footprint_mb")
    r = dmx("exec", "--", "true")
    check("restart_in_process", r.returncode == 0 and daemon_pids() == pid and s["state"] == "stopped", f"{s['state']} {pid}")

    # Idle: the VM stops after idle_timeout, then the daemon exits after 10 s.
    dmx("config", "set", "idle_timeout", "2s")
    dmx("stop")
    dmx("start")
    stopped = wait_for(lambda: status()["state"] == "stopped", 10)
    exited = wait_for(lambda: not daemon_pids(), 15)
    check("idle_stop", stopped and exited and not (HOME / "dmx.sock").exists(), f"vm stopped {stopped}, daemon exited {exited}")
finally:
    for pid in daemon_pids():
        os.kill(pid, signal.SIGTERM)
    wait_for(lambda: not daemon_pids(), 15)
    shutil.rmtree(HOME, ignore_errors=True)

ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
