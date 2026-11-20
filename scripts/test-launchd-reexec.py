#!/usr/bin/env python3
"""launchd socket activation through MallocSettings' re-exec: `dmx daemon` started by launchd sets
MallocSpaceEfficient=1 and executes itself again, keeping its pid; the sockets launchd passed
must still be there for `launch_activate_socket` afterwards.

Bootstraps a launchd agent of its own label (not dmx's), with a throwaway DMX_HOME, from this
build: a dmx client connection starts the daemon, then, with the daemon gone, a Docker client
connection alone starts it again and gets dockerd's answer through the VM. Checks the daemon's
environment, that it says it took launchd's socket, and `dmx status`'s `launchd`. Removes the
agent at the end. Prints one JSON object; exits non-zero if a check failed. About 30 seconds.

    python3 -I scripts/test-launchd-reexec.py [path/to/dmx]
"""

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
USER_DMX = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx")
DOCKER = str(USER_DMX / "bin" / "docker")
# Its own label per run: two runs at once must not take down each other's job.
LABEL = f"io.github.cothis.dmx.reexectest.{os.getpid()}"
DOMAIN = f"gui/{os.getuid()}"
HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="dmx-launchd-", dir="/tmp")))
(HOME / "guest").symlink_to(USER_DMX / "guest")
(HOME / "bin").symlink_to(USER_DMX / "bin")
(HOME / "dc").mkdir()
(HOME / "dc" / "config.json").write_text("{}")
PLIST = HOME / f"{LABEL}.plist"
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "Malloc"))}
ENV.update(DMX_HOME=str(HOME), DOCKER_HOST=f"unix://{HOME}/docker.sock", DOCKER_CONFIG=str(HOME / "dc"))
checks = []


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:300]})


def run(*a, timeout=120):
    return subprocess.run(list(a), capture_output=True, text=True, env=ENV, timeout=timeout)


def job_pid():
    out = subprocess.run(["launchctl", "print", f"{DOMAIN}/{LABEL}"], capture_output=True, text=True).stdout
    return next((int(l.split("=")[1]) for l in out.splitlines() if l.strip().startswith("pid =")), None)


def daemon_log():
    path = HOME / "logs" / "daemon.log"
    return path.read_text(errors="replace") if path.exists() else ""


def status():
    """`dmx status` once the daemon launchd started answers (the first connection starts it)."""
    deadline = time.time() + 20
    while True:
        s = json.loads(run(str(DMX), "status", "--json").stdout or "{}")
        if s.get("pid") or time.time() > deadline:
            return s
        time.sleep(0.5)


def env_of(pid):
    out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    return dict(w.split("=", 1) for w in out.split() if "=" in w and w.split("=", 1)[0].isidentifier())


try:
    # launchd's own environment must not give the daemon the variable, or finding it would not
    # show the re-exec.
    inherited = subprocess.run(["launchctl", "getenv", "MallocSpaceEfficient"], capture_output=True, text=True).stdout.strip()
    check("not_inherited_from_launchd", inherited == "", inherited)
    # As LaunchAgent.plistData writes it, under another label and home.
    PLIST.write_bytes(plistlib.dumps({
        "Label": LABEL, "ProgramArguments": [str(DMX), "daemon"], "EnvironmentVariables": {"DMX_HOME": str(HOME)},
        "Sockets": {"Listeners": {"SockPathName": str(HOME / "dmx.sock"), "SockPathMode": 0o600},
                    "Docker": {"SockPathName": str(HOME / "docker.sock"), "SockPathMode": 0o600}},
        "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
        "ProcessType": "Interactive", "ThrottleInterval": 1, "ExitTimeOut": 75}))
    r = subprocess.run(["launchctl", "bootstrap", DOMAIN, str(PLIST)], capture_output=True, text=True)
    check("bootstrap", r.returncode == 0, r.stderr)
    reply = status()
    pid = job_pid()
    check("started_by_dmx_client", pid is not None and reply.get("pid") == pid, f"launchd pid {pid}, status {reply.get('pid')}")
    check("status_launchd", reply.get("launchd") is True, reply.get("launchd"))
    check("reexec_env", env_of(pid).get("MallocSpaceEfficient") == "1", "")
    log = daemon_log()
    check("took_launchd_socket", f"(launchd, pid {pid})" in log, log[-200:])

    run(str(DMX), "stop")
    os.kill(pid, 15)
    deadline = time.time() + 20
    while job_pid() is not None and time.time() < deadline:
        time.sleep(0.2)
    check("daemon_gone", job_pid() is None, "")
    r = run(DOCKER, "version", "--format", "{{.Server.Version}}", timeout=180)
    pid2 = job_pid()
    check("started_by_docker_client", r.returncode == 0 and r.stdout.strip() != "", (r.stdout + r.stderr)[-200:])
    check("second_reexec_env", pid2 is not None and env_of(pid2).get("MallocSpaceEfficient") == "1", pid2)
    check("second_took_launchd_socket", f"(launchd, pid {pid2})" in daemon_log(), "")
finally:
    run(str(DMX), "stop")
    subprocess.run(["launchctl", "bootout", f"{DOMAIN}/{LABEL}"], capture_output=True)
    subprocess.run(["rm", "-rf", str(HOME)])

ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
