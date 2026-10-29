#!/usr/bin/env python3
"""Real-VM menu lifecycle contracts, isolated from the user's engine and Docker config."""
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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


# Cancel a real missing-guest download while its HTTP server still holds the request open.
# Teardown must not provide the wakeup that makes this pass.
with tempfile.TemporaryDirectory(prefix="dmx-cancel-") as cancel_home:
    received, release = threading.Event(), threading.Event()
    class SlowGuest(BaseHTTPRequestHandler):
        def do_GET(self):
            received.set(); release.wait(20)
        def log_message(self, *args): pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), SlowGuest)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    cancel_env = {**os.environ, "DMX_HOME": cancel_home, "DMX_RELEASE_URL": f"http://127.0.0.1:{server.server_port}"}
    start = subprocess.Popen([str(DMX), "start", "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=cancel_env)
    try:
        check("startup_download_reached_server", received.wait(10))
        began = time.monotonic()
        stopped = subprocess.run([str(DMX), "stop", "--json"], capture_output=True, env=cancel_env, timeout=5)
        check("startup_download_cancelled_before_server_close", stopped.returncode == 0 and time.monotonic() - began < 2, stopped.stdout.decode())
        out, err = start.communicate(timeout=5)
        check("cancelled_start_is_normal_shutdown", start.returncode != 0 and json.loads(out).get("error", {}).get("code") == "start_cancelled", out.decode())
    finally:
        if start.poll() is None: start.kill(); start.wait()
        release.set(); server.shutdown(); server.server_close()
        try:
            with socket.socket(socket.AF_UNIX) as cleanup:
                cleanup.settimeout(5); cleanup.connect(str(Path(cancel_home) / "dmx.sock"))
                payload = json.dumps({"id": 1, "method": "quit", "params": {}}).encode()
                cleanup.sendall(struct.pack(">I", len(payload) + 1) + b"\0" + payload); cleanup.recv(4096)
        except OSError: pass
        wait(lambda: not (Path(cancel_home) / "dmx.sock").exists(), 15)


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
            connection.connect(str(home / "dmx.sock"))
            request = json.dumps({"id": 1, "method": "menu_docker_read", "params": {}}).encode()
            connection.sendall(struct.pack(">I", len(request) + 1) + b"\0" + request)
            header = connection.recv(4)
            length = struct.unpack(">I", header)[0]
            ack = b""
            while len(ack) < length:
                ack += connection.recv(length - len(ack))
            check("menu_tunnel", json.loads(ack[1:])["ok"])
            connection.sendall(b"GET /v1.47/containers/json?all=1 HTTP/1.0\r\nHost: docker\r\n\r\n")
            reply = b""
            while chunk := connection.recv(65536):
                reply += chunk
            check("menu_docker_listing", b"200 OK" in reply and json.loads(reply.split(b"\r\n\r\n", 1)[1]) == [])
        check("idle_while_observed", wait(lambda: receipt().get("state") == "stopped", 20), receipt())
        check("normal_stop_has_no_failure", receipt().get("failure") is None)
        refused = call("menu_docker")
        check("menu_cannot_boot_idle_vm", refused.get("ok") is False and refused.get("error", {}).get("code") == "menu_engine_not_running")
        check("menu_release", call("menu_release")["result"] is True)
        check("daemon_exits_after_menu_release", wait(lambda: not alive(pid), 15))
        before = receipt()
        for _ in range(5):
            receipt()
        check("reading_receipt_does_not_restart_engine", not alive(pid) and receipt() == before)
        check("cli_works_without_app", command("start", "--json").returncode == 0)
        cli_pid = receipt()["pid"]
        def docker_cli_probe():
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(30); sock.connect(str(home / "docker.sock"))
                sock.sendall(b"GET /v1.47/containers/json?all=1 HTTP/1.0\r\nHost: docker\r\n\r\n")
                body = b""
                while chunk := sock.recv(65536): body += chunk
                return b"200 OK" in body
        check("independent_docker_cli", docker_cli_probe())
        check("cli_idle_stop", wait(lambda: receipt().get("state") == "stopped", 20))
        check("menu_detach_from_cli_idle", call("menu_release")["result"] is True)
        time.sleep(11)
        check("cli_keepalive_survives_menu", alive(cli_pid) and (home / "docker.sock").exists())
        check("docker_cli_restarts_vm_without_app", docker_cli_probe())
        # End real active use while a passive menu lease is still the last connection.
        # Its later close must preserve the active completion timestamp, not an old idle epoch.
        with socket.socket(socket.AF_UNIX) as passive:
            passive.settimeout(30); passive.connect(str(home / "dmx.sock"))
            payload = json.dumps({"id": 1, "method": "menu_docker_read", "params": {}}).encode()
            passive.sendall(struct.pack(">I", len(payload) + 1) + b"\0" + payload)
            header = passive.recv(4); length = struct.unpack(">I", header)[0]
            ack = b""
            while len(ack) < length: ack += passive.recv(length - len(ack))
            check("passive_overlap_ack", json.loads(ack[1:])["ok"])
            check("active_exec_ends_under_passive_lease", command("exec", "--", "sleep", "4").returncode == 0)
            time.sleep(.1)
        time.sleep(.1)
        after_overlap = call("status")["result"]
        check("active_completion_sets_idle_epoch_under_passive_lease", after_overlap["state"] == "running" and (after_overlap.get("idle_stop_in_s") or 0) >= 2, after_overlap)
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
