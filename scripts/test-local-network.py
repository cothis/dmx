#!/usr/bin/env python3
"""What a launchd-started engine inside dmx.app reports about macOS's local network permission, and
whether that matches what a container actually gets. Holds in either state, so it needs nobody to
answer the prompt, though it may raise one for this app. A shell-started daemon cannot test this: it
inherits the terminal's permission, which is why daemontest never saw the block.

    python3 -I scripts/test-local-network.py path/to/dmx.app
"""

import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

APP = Path(sys.argv[1]).resolve()
BIN = APP / "Contents/MacOS/dmx"
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
LABEL = "io.github.cothis.dmx.localnettest"
DOMAIN = f"gui/{os.getuid()}"
checks = []


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:400]})


def lan_gateway():
    out = subprocess.run(["netstat", "-rn", "-f", "inet"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 4 and f[0] == "default" and re.match(r"en\d+$", f[-1]) and re.match(r"\d+\.\d+\.\d+\.\d+$", f[1]):
            return f[1]
    return None


info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
check("usage_description", ".local" in info.get("NSLocalNetworkUsageDescription", ""), info.get("NSLocalNetworkUsageDescription"))

with tempfile.TemporaryDirectory(prefix="dmxln", dir="/private/tmp") as scratch:
    home = Path(scratch) / "h"
    home.mkdir()
    (home / "guest").symlink_to(GUEST)
    (home / "config.json").write_text(json.dumps({"cpus": 2, "memory": "2G", "shares": [], "idle_timeout": 600}))
    env = {**os.environ, "DMX_HOME": str(home)}
    plist = Path(scratch) / f"{LABEL}.plist"
    plist.write_bytes(plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": [str(BIN), "daemon"],
        "EnvironmentVariables": {"DMX_HOME": str(home)},
        "ProcessType": "Interactive",
        "StandardOutPath": str(home / "launchd.log"),
        "StandardErrorPath": str(home / "launchd.log"),
        "Sockets": {
            "Listeners": {"SockPathName": str(home / "dmx.sock"), "SockPathMode": 0o600},
            "Docker": {"SockPathName": str(home / "docker.sock"), "SockPathMode": 0o600},
        },
    }))

    def dmx(*args, timeout=120):
        try:
            return subprocess.run([str(BIN), *args], capture_output=True, env=env, timeout=timeout)
        except (subprocess.TimeoutExpired, OSError) as e:
            return subprocess.CompletedProcess(args, 124, b"", f"{e}".encode())

    def status():
        try:
            return json.loads(dmx("status", "--json").stdout)
        except ValueError:
            return {}

    def bootout():
        subprocess.run(["launchctl", "bootout", f"{DOMAIN}/{LABEL}"], capture_output=True)

    # bootout returns while the job is still leaving, and a bootstrap then can fail with EIO.
    bootout()
    for attempt in range(10):
        loaded = subprocess.run(["launchctl", "bootstrap", DOMAIN, str(plist)], capture_output=True)
        if loaded.returncode == 0:
            break
        time.sleep(1)
    check("job_loaded", loaded.returncode == 0, loaded.stderr)
    if loaded.returncode != 0:
        # Without the job, dmx would start a daemon of its own: not what this tests.
        print(json.dumps({"ok": False, "checks": checks}, indent=2))
        sys.exit(1)
    daemon = None
    results = {}
    changed = False
    try:
        # A stopped engine says nothing, and so raises no prompt. The socket can appear a moment late.
        stopped = {}
        for attempt in range(10):
            stopped = status()
            if stopped.get("state") == "stopped":
                break
            time.sleep(1)
        check("stopped_says_nothing", stopped.get("state") == "stopped" and stopped.get("local_network") is None, stopped.get("state"))
        r = dmx("exec", "--", "true")
        check("boots_under_launchd", r.returncode == 0, r.stderr[-200:])
        running = status()
        daemon = running.get("pid")
        check("launchd_owns_the_daemon", running.get("launchd") is True and running.get("state") == "running", running.get("state"))
        access = running.get("local_network")
        check("reports_a_state", access in ("allowed", "blocked", "unknown"), access)

        doctor = json.loads(dmx("doctor", "--json").stdout or "{}")
        entry = next((c for c in doctor.get("checks", []) if c["name"] == "local_network"), {})
        check("doctor_agrees", entry.get("ok") is True and doctor.get("ok") is True and (bool(entry.get("hint")) == (access == "blocked")), entry)
        text = dmx("status").stdout.decode()
        check("status_text_says_when_blocked", ("local network:" in text) == (access == "blocked"), text[-300:])
        if access == "blocked":
            log = (home / "logs/daemon.log").read_text()
            check("log_says_when_blocked", "local network:" in log, log[-300:])

        gateway = lan_gateway()
        results = {"access": access, "lan": gateway is not None}
        if gateway is not None:
            # A TCP connection. Blocked is an immediate "no route" (ICMP from dmx). Allowed means
            # wget itself ran and was not told that: the router may answer, refuse or drop it.
            r = dmx("exec", "--", "wget", "-q", "-T", "4", "-O", "/dev/null", f"http://{gateway}/")
            said = (r.stdout + r.stderr).decode(errors="replace").lower()
            no_route = "unreachable" in said or "no route" in said
            ran = r.returncode == 0 or "wget:" in said
            results["tcp"] = said.strip()[-120:]
            # The probe could not tell (a transient error, with a LAN present): nothing to compare.
            results["compared"] = access != "unknown"
            if access != "unknown":
                check("tcp_matches_report", (access == "blocked" and no_route) or (access == "allowed" and ran and not no_route), f"{access}: rc {r.returncode}: {said[-120:]}")
            # The Mac's own multicast DNS name, through the gateway's resolver. Blocked does not
            # promise a failure: the first run of a newly signed build got an answer with its
            # sockets blocked, later runs did not. Allowed does not promise one either, since
            # mDNSResponder decides for itself. So this is recorded, not judged.
            local = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True).stdout.strip()
            r = dmx("exec", "--", "nslookup", "-type=a", f"{local}.local", "192.168.127.1")
            results["local_name_answered"] = b"Address: " in r.stdout.partition(b"answer:")[2]
        # Nothing about public names depends on the permission.
        r = dmx("exec", "--", "nslookup", "-type=a", "github.com", "192.168.127.1")
        check("public_names_resolve", r.returncode == 0 and b"Address: " in r.stdout.partition(b"answer:")[2], r.stdout[-120:])
        # The checks above read the state at different moments, and the owner may answer the prompt.
        last = status().get("local_network")
        check("state_still_reported", last in ("allowed", "blocked", "unknown"), last)
        changed = last in ("allowed", "blocked", "unknown") and access in ("allowed", "blocked", "unknown") and last != access
    finally:
        try:
            dmx("stop")
        finally:
            bootout()
        # The temporary home goes next: wait for launchd and the daemon to let go of it.
        for attempt in range(30):
            job = subprocess.run(["launchctl", "print", f"{DOMAIN}/{LABEL}"], capture_output=True).returncode == 0
            alive = False
            if daemon:
                try:
                    os.kill(daemon, 0)
                    alive = True
                except ProcessLookupError:
                    pass
            if not job and not alive:
                break
            time.sleep(1)
        check("job_gone", not job and not alive, f"job loaded {job}, daemon alive {alive}")

if changed:
    print(json.dumps({"ok": False, "error": "the permission changed during the test; run it again", **results, "checks": checks}, indent=2))
    sys.exit(2)
ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
