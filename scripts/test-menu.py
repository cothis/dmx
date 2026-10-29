#!/usr/bin/env python3
"""Real-VM menu lifecycle contracts, isolated from the user's engine and Docker config."""
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
checks = []


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})
    if not ok:
        raise AssertionError(name + ": " + str(detail))


def wait(predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.05)
    return False


with tempfile.TemporaryDirectory(prefix="dmx-menu-") as scratch:
    home = Path(scratch)
    (home / "guest").symlink_to(GUEST, target_is_directory=True)
    (home / "config.json").write_text(json.dumps({"cpus": 2, "memory": "2G", "shares": [], "idle_timeout": 3}))
    env = {**os.environ, "DMX_HOME": str(home), "DOCKER_CONFIG": str(home / "docker-config")}

    def command(*args):
        return subprocess.run([str(DMX), *args], capture_output=True, env=env, timeout=150)

    def call(method):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(15)
            connection.connect(str(home / "dmx.sock"))
            body = json.dumps({"id": 1, "method": method, "params": {}}).encode()
            connection.sendall(struct.pack(">I", len(body) + 1) + b"\0" + body)
            def read(count):
                result = b""
                while len(result) < count:
                    chunk = connection.recv(count - len(result))
                    if not chunk:
                        raise EOFError(method)
                    result += chunk
                return result
            length = struct.unpack(">I", read(4))[0]
            return json.loads(read(length)[1:])

    def receipt():
        try:
            return json.loads((home / "run/engine.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    try:
        started = command("start", "--json")
        check("start", started.returncode == 0, started.stderr.decode())
        status = json.loads(started.stdout)
        pid = status["pid"]
        check("hello_capability", call("hello")["result"].get("activity_notifications") is True)
        check("running_receipt", receipt().get("state") == "running" and receipt().get("pid") == pid)
        check("release_cannot_stop_active_vm", call("menu_release")["result"] is False)
        # Loading the menu touches Docker, whose standalone socket normally keeps the daemon
        # resident. The menu release must let it exit again once the VM is stopped.
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30)
            connection.connect(str(home / "docker.sock"))
            connection.sendall(b"GET /v1.47/containers/json?all=1 HTTP/1.0\r\nHost: docker\r\n\r\n")
            reply = b""
            while chunk := connection.recv(65536):
                reply += chunk
            check("menu_docker_listing", b"200 OK" in reply and json.loads(reply.split(b"\r\n\r\n", 1)[1]) == [])
        check("idle_while_observed", wait(lambda: receipt().get("state") == "stopped", 20), receipt())
        check("normal_stop_has_no_failure", receipt().get("failure") is None)
        check("menu_release", call("menu_release")["result"] is True)
        check("daemon_exits_after_menu_release", wait(lambda: not alive(pid), 15))
        before = receipt()
        for _ in range(5):
            receipt()
        check("reading_receipt_does_not_restart_engine", not alive(pid) and receipt() == before)
        check("cli_works_without_app", command("start", "--json").returncode == 0)
        # The custom guest init does not implement BusyBox init's SIGUSR poweroff protocol.
        # -f issues the kernel poweroff syscall, exercising the VMM's unsolicited exit path.
        command("exec", "--", "poweroff", "-f")
        check("guest_poweroff_reported_as_failure", wait(lambda: (receipt().get("failure") or {}).get("code") == "guest_stopped", 10), receipt())
    finally:
        try:
            call("quit")
        except (OSError, EOFError):
            pass
        current = receipt().get("pid")
        if current:
            wait(lambda: not alive(current), 15)

print(json.dumps({"ok": all(c["ok"] for c in checks), "checks": checks}, indent=2))
