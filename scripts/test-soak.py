#!/usr/bin/env python3
"""Soak check: hundreds of `docker run --rm` and Compose up/down cycles on the real VM, then what
is left against the start.

Runs in a throwaway DMX_HOME (its own data disk and daemon) with dmx's own docker CLI and Compose
plugin (`dmx tools install`, from ~/.dmx or $DMX_HOME), never Homebrew's. Needs the guest with
Docker in it and the internet (alpine and busybox from Docker Hub). Host port 20180 is used.

After a warm-up (pulls, a few runs and Compose cycles, so lazy start-up is not counted), it waits
for the memory controller's idle sweep and records a baseline; then the cycles, the same wait and
the same record: host footprint and guest memory, the daemon's open fds and threads, dockerd's,
containerd's and dmx-agent's fds, threads and RSS in the guest, and what should be gone
(containers, networks, volumes, veths, mounts, shims, port forwards). Prints one JSON object; exits non-zero if a check
failed. Opt-in, not part of selftest: about 4 minutes.

    python3 -I scripts/test-soak.py [path/to/dmx] [--runs 300] [--compose 50]
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("dmx", nargs="?", default=".build/release/dmx")
parser.add_argument("--runs", type=int, default=300)
parser.add_argument("--compose", type=int, default=50)
parser.add_argument("--sample-every", type=int, default=50, help="record fds and threads every N runs")
args = parser.parse_args()

DMX = Path(args.dmx).resolve()
USER_DMX = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx")
GUEST = USER_DMX / "guest"
DOCKER = str(USER_DMX / "bin" / "docker")
PLUGINS = USER_DMX / "cli-plugins"
PORT = 20180

# realpath: /tmp is a link to /private/tmp, and the daemon's DMX_HOME must match what pgrep sees.
HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="dmx-soak-", dir="/tmp")))
DOCKER_CONFIG = HOME / "docker-config"
DOCKER_CONFIG.mkdir()
(DOCKER_CONFIG / "config.json").write_text(json.dumps({"cliPluginsExtraDirs": [str(PLUGINS)]}))
(HOME / "guest").symlink_to(GUEST)
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "BUILDX_", "COMPOSE_"))}
ENV.update(DMX_HOME=str(HOME), DOCKER_HOST=f"unix://{HOME}/docker.sock", DOCKER_CONFIG=str(DOCKER_CONFIG),
           PATH="/usr/bin:/bin:/usr/sbin:/sbin")

# init: a PID 1 that passes SIGTERM on, so `down` does not wait out its 10 s grace.
COMPOSE = f"""\
services:
  web:
    image: busybox
    init: true
    command: ["sh", "-c", "echo soak > /www/index.html; exec httpd -f -p 80 -h /www"]
    ports: ["127.0.0.1:{PORT}:80"]
    volumes: ["data:/www"]
  worker:
    image: alpine
    init: true
    command: ["sleep", "600"]
volumes:
  data: {{}}
"""

checks = []
results = {"runs": args.runs, "compose_cycles": args.compose}


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:400]})
    return ok


def progress(message):
    print(f"soak: {message}", file=sys.stderr, flush=True)


def dmx(*a, timeout=120):
    return subprocess.run([str(DMX), *a], capture_output=True, timeout=timeout, env=ENV)


def docker(*a, timeout=300, cwd=None):
    return subprocess.run([DOCKER, *a], capture_output=True, timeout=timeout, env=ENV, cwd=cwd)


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


def host_fds(pid):
    """Open descriptors of the daemon by lsof type (REG, KQUEUE, unix, IPv4, ...)."""
    out = subprocess.run(["lsof", "-n", "-P", "-p", str(pid), "-F", "ft"], capture_output=True, text=True).stdout
    kinds, fd = {}, None
    for line in out.splitlines():
        if line.startswith("f"):
            fd = line[1:]
        elif line.startswith("t") and fd is not None and fd.isdigit():
            kinds[line[1:]] = kinds.get(line[1:], 0) + 1
    return sum(kinds.values()), kinds


def host_threads(pid):
    out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout
    return max(0, len(out.splitlines()) - 1)


GUEST_PROBE = r"""
for name in dockerd containerd dmx-agent; do
  pid=$(pidof $name | cut -d' ' -f1)
  if [ -z "$pid" ]; then echo "$name - - -"; continue; fi
  fds=$(ls /proc/$pid/fd | wc -l)
  threads=$(awk '/^Threads:/ {print $2}' /proc/$pid/status)
  rss=$(awk '/^VmRSS:/ {print $2}' /proc/$pid/status)
  echo "$name $fds $threads $rss"
done
# User processes have a command line; kernel threads (kworkers come and go) do not. /proc files
# read as size 0, so the test reads them.
user=0; kernel=0; names=""
for d in /proc/[0-9]*; do
  if [ -n "$(tr -d '\\0' < $d/cmdline 2>/dev/null | head -c 1)" ]; then user=$((user + 1)); names="$names $(cat $d/comm 2>/dev/null)"; else kernel=$((kernel + 1)); fi
done
echo "user_processes $user"
echo "kernel_threads $kernel"
echo "names$names"
echo "shims $(pidof containerd-shim-runc-v2 | wc -w)"
echo "veths $(ls /sys/class/net | grep -c '^veth')"
echo "mounts $(wc -l < /proc/mounts)"
echo "netns $(ls /run/docker/netns 2>/dev/null | wc -l)"
"""


def guest_probe():
    r = dmx("exec", "--", "sh", "-c", GUEST_PROBE)
    out = {}
    for line in r.stdout.decode().splitlines():
        parts = line.split()
        if len(parts) == 4:
            out[parts[0]] = {k: (int(v) if v.isdigit() else None) for k, v in zip(("fds", "threads", "rss_kb"), parts[1:])}
        elif len(parts) == 2 and parts[1].isdigit():
            out[parts[0]] = int(parts[1])
        elif parts and parts[0] == "names":
            out["user_process_names"] = sorted(parts[1:])
    return out


def docker_counts():
    def count(*a):
        r = docker(*a, "-q")
        return len(r.stdout.split()) if r.returncode == 0 else None
    return {"containers": count("ps", "-a"), "networks": count("network", "ls"), "volumes": count("volume", "ls"),
            "forwards": len(json.loads(dmx("port", "ls", "--json").stdout or b"{}").get("forwards", []))}


def quick(pid):
    fds, _ = host_fds(pid)
    g = guest_probe()
    return {"daemon_fds": fds, "daemon_threads": host_threads(pid),
            **{f"{n}_rss_mb": round((g.get(n) or {}).get("rss_kb", 0) / 1024) for n in ("dockerd", "containerd")}}


def settle(label, limit=150):
    """Waits for the memory controller's idle sweep (30 s without activity and a quiet guest CPU,
    checked every 5 s), then 10 s for free page reporting to hand back what it freed. A fixed
    35 s wait sometimes measured just before the trim: 423 and 529 MB where the trimmed VM held
    about 240. Returns the footprint every second meanwhile."""
    progress(f"{label}: waiting for the idle sweep")
    started = time.monotonic()
    first = (status().get("memory") or {}).get("sweeps") or 0
    swept_at, samples = None, []
    while time.monotonic() - started < limit:
        time.sleep(1)
        s = status()
        m = s.get("memory") or {}
        at = round(time.monotonic() - started, 1)
        samples.append({"s": at, "footprint_mb": s.get("host_footprint_mb"), "guest_used_mb": s.get("guest_used_mb"),
                        "guest_cache_mb": m.get("guest_cache_mb"), "trims": m.get("trims"), "sweeps": m.get("sweeps")})
        if swept_at is None and (m.get("sweeps") or 0) > first:
            swept_at = at
        if swept_at is not None and at - swept_at >= 10:
            break
    return swept_at, samples


def snapshot(pid, label):
    """Everything, once the idle sweep handed back what the guest freed."""
    swept_at, samples = settle(label)
    s = status()
    fds, kinds = host_fds(pid)
    snap = {"host_footprint_mb": s.get("host_footprint_mb"), "guest_used_mb": s.get("guest_used_mb"),
            "idle_sweep_after_s": swept_at, "settle": samples,
            "daemon_fds": fds, "daemon_fd_kinds": kinds, "daemon_threads": host_threads(pid),
            "guest": guest_probe(), **docker_counts()}
    progress(f"{label}: {snap['host_footprint_mb']} MB (swept after {swept_at} s), guest {snap['guest_used_mb']} MB, "
             f"daemon {fds} fds / {snap['daemon_threads']} threads")
    return snap


def run_once():
    r = docker("run", "--rm", "alpine", "true", timeout=60)
    return r.returncode == 0, r.stderr[-300:]


def compose_cycle(app):
    up = docker("compose", "-p", "dmxsoak", "up", "-d", "--wait", timeout=120, cwd=app)
    body = b""
    for _ in range(50):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=2) as r:
                body = r.read()
                break
        except Exception:
            time.sleep(0.1)
    down = docker("compose", "-p", "dmxsoak", "down", "-v", timeout=120, cwd=app)
    ok = up.returncode == 0 and body == b"soak\n" and down.returncode == 0
    return ok, f"up {up.returncode} {up.stderr[-200:]!r} body {body!r} down {down.returncode} {down.stderr[-200:]!r}"


def soak(pid, app, runs, cycles, timeline):
    """Runs and Compose cycles interleaved: one cycle after every runs/cycles runs."""
    failures, run_ms, compose_ms = [], [], []
    every = max(1, runs // max(1, cycles)) if cycles else None
    done_cycles = 0
    for i in range(1, runs + 1):
        started = time.monotonic()
        ok, detail = run_once()
        run_ms.append((time.monotonic() - started) * 1000)
        if not ok:
            failures.append(f"run {i}: {detail!r}")
        if every and i % every == 0 and done_cycles < cycles:
            started = time.monotonic()
            ok, detail = compose_cycle(app)
            compose_ms.append((time.monotonic() - started) * 1000)
            done_cycles += 1
            if not ok:
                failures.append(f"compose {done_cycles}: {detail}")
        if i % args.sample_every == 0 or i == runs:
            timeline.append({"runs": i, "compose": done_cycles, "s": round(time.monotonic() - T0, 1), **quick(pid)})
            progress(f"{i}/{runs} runs, {done_cycles}/{cycles} compose cycles, {len(failures)} failures, "
                     f"{timeline[-1]['daemon_fds']} fds / {timeline[-1]['daemon_threads']} threads, "
                     f"dockerd {timeline[-1]['dockerd_rss_mb']} MB")
    while done_cycles < cycles:
        started = time.monotonic()
        ok, detail = compose_cycle(app)
        compose_ms.append((time.monotonic() - started) * 1000)
        done_cycles += 1
        if not ok:
            failures.append(f"compose {done_cycles}: {detail}")
    return failures, run_ms, compose_ms


def median(values):
    v = sorted(values)
    return round(v[len(v) // 2]) if v else None


T0 = time.monotonic()
try:
    if not check("docker_tools", os.access(DOCKER, os.X_OK) and (PLUGINS / "docker-compose").exists(),
                 f"{DOCKER} and {PLUGINS}/docker-compose; run `dmx tools install`"):
        raise SystemExit
    r = dmx("start", "--json")
    check("start", r.returncode == 0, r.stderr[-300:])
    pid = status().get("pid")
    pids = daemon_pids()
    check("daemon_pid", pid in pids, f"status pid {pid}, daemons {pids}")
    results["daemon_pid"] = pid

    app = HOME / "app"
    app.mkdir()
    (app / "compose.yaml").write_text(COMPOSE)
    progress("warm-up: pulls, 10 runs, 2 compose cycles")
    for image in ("alpine", "busybox"):
        r = docker("pull", image)
        check(f"pull_{image}", r.returncode == 0, r.stderr[-300:])
    warm, _, _ = soak(pid, app, 10, 2, [])
    check("warm_up", not warm, warm[:3])

    before = snapshot(pid, "before")
    results["before"] = before
    timeline = [{"runs": 0, "compose": 0, "s": round(time.monotonic() - T0, 1), **quick(pid)}]
    started = time.monotonic()
    failures, run_ms, compose_ms = soak(pid, app, args.runs, args.compose, timeline)
    results["soak_s"] = round(time.monotonic() - started)
    results["run_ms"] = {"median": median(run_ms), "max": round(max(run_ms)) if run_ms else None}
    results["compose_cycle_ms"] = {"median": median(compose_ms), "max": round(max(compose_ms)) if compose_ms else None}
    results["timeline"] = timeline
    check("all_cycles_ok", not failures, f"{len(failures)} failed: {failures[:3]}")

    after = snapshot(pid, "after")
    results["after"] = after
    check("idle_sweep", before["idle_sweep_after_s"] is not None and after["idle_sweep_after_s"] is not None,
          f"before {before['idle_sweep_after_s']} s, after {after['idle_sweep_after_s']} s")
    check("daemon_alive", status().get("pid") == pid, "the daemon kept its pid")

    # Nothing the cycles made is left.
    for key in ("containers", "networks", "volumes", "forwards"):
        check(f"left_{key}", after[key] == before[key], f"{before[key]} -> {after[key]}")
    for key in ("shims", "veths", "mounts", "netns", "user_processes"):
        b, a = before["guest"].get(key), after["guest"].get(key)
        extra = ""
        if key == "user_processes":
            gone = list(before["guest"].get("user_process_names", []))
            new = []
            for n in after["guest"].get("user_process_names", []):
                if n in gone:
                    gone.remove(n)
                else:
                    new.append(n)
            extra = f", new {new}, gone {gone}"
        check(f"left_guest_{key}", a is not None and b is not None and a <= b, f"{b} -> {a}{extra}")
    # Descriptors and threads come back; a little slack for pooled connections and workers.
    check("daemon_fds", after["daemon_fds"] <= before["daemon_fds"] + 4,
          f"{before['daemon_fds']} -> {after['daemon_fds']} ({before['daemon_fd_kinds']} -> {after['daemon_fd_kinds']})")
    check("daemon_threads", after["daemon_threads"] <= before["daemon_threads"] + 4,
          f"{before['daemon_threads']} -> {after['daemon_threads']}")
    for name in ("dockerd", "containerd", "dmx-agent"):
        b, a = before["guest"].get(name) or {}, after["guest"].get(name) or {}
        check(f"guest_{name}_fds", a.get("fds") is not None and b.get("fds") is not None and a["fds"] <= b["fds"] + 8,
              f"{b.get('fds')} -> {a.get('fds')}")
        check(f"guest_{name}_threads", a.get("threads") is not None and b.get("threads") is not None and a["threads"] <= b["threads"] + 8,
              f"{b.get('threads')} -> {a.get('threads')}")
    # Memory: what the cycles leave behind, not their peak.
    fb, fa = before["host_footprint_mb"], after["host_footprint_mb"]
    check("host_footprint", fa is not None and fb is not None and fa <= fb + 64, f"{fb} -> {fa} MB")
    gb, ga = before["guest_used_mb"], after["guest_used_mb"]
    check("guest_used", ga is not None and gb is not None and ga <= gb + 64, f"{gb} -> {ga} MB")
except subprocess.TimeoutExpired as e:
    check("no_timeout", False, f"{e.cmd} timed out after {e.timeout} s")
except SystemExit:
    pass
finally:
    try:
        docker("compose", "-p", "dmxsoak", "down", "-v", timeout=60, cwd=HOME / "app")
    except Exception:
        pass
    # No `dmx quit`: stop the VM, then the daemon, and wait for it before deleting its home.
    try:
        dmx("stop", timeout=60)
    except Exception:
        pass
    for p in daemon_pids():
        os.kill(p, signal.SIGTERM)
    deadline = time.time() + 20
    while daemon_pids() and time.time() < deadline:
        time.sleep(0.2)
    if not all(c["ok"] for c in checks):
        logs = Path(tempfile.gettempdir()) / f"dmx-soak-logs-{os.getpid()}"
        shutil.copytree(HOME / "logs", logs, dirs_exist_ok=True)
        results["logs"] = str(logs)
    shutil.rmtree(HOME, ignore_errors=True)

results["total_s"] = round(time.monotonic() - T0)
ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
