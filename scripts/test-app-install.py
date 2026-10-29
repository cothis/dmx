#!/usr/bin/env python3
"""A real signed app's install/update path, including hostile archives and a running VM."""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
APP = Path(sys.argv[2] if len(sys.argv) > 2 else ".build/dmx.app").resolve()
VERSION = subprocess.check_output([DMX, "--version"], text=True).strip()
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
DOCKER = GUEST.parent / "bin/docker"
checks = []


def check(name, ok, detail=None):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})
    if not ok: raise AssertionError(name + ": " + str(detail))


with tempfile.TemporaryDirectory(prefix="dmx-app-test-", dir="/tmp") as scratch:
    work = Path(scratch); destination = work / "Applications/dmx.app"; bin_dir = work / "bin"
    home = work / "home"; home.mkdir(); (home / "guest").symlink_to(GUEST)
    (home / "config.json").write_text(json.dumps({"cpus": 2, "memory": "2G", "shares": [], "idle_timeout": 600}))
    env = {**os.environ, "DMX_HOME": str(home), "DOCKER_CONFIG": str(work / "docker")}

    def command(executable, *args, ok=True):
        result = subprocess.run([str(executable), *map(str, args), "--json"], capture_output=True, env=env, timeout=160)
        output = json.loads(result.stdout)
        if ok and result.returncode: raise AssertionError(output)
        if not ok and not result.returncode: raise AssertionError("unexpected success: " + str(output))
        return output

    def install(*args, ok=True):
        return command(DMX, "app", "install", *args, "--directory", destination, "--bin-dir", bin_dir, ok=ok)

    result = install("--bundle", APP)
    cli = bin_dir / "dmx"; helper = destination / "Contents/MacOS/dmx"
    digest = hashlib.sha256(helper.read_bytes()).hexdigest()
    check("single_install_app_and_cli", result["ok"] and cli.is_symlink() and cli.resolve() == helper.resolve())
    check("bundled_helper_reports_cli_version", subprocess.check_output([cli, "--version"], text=True).strip() == VERSION)
    install("--bundle", APP)
    check("repeat_install_valid_signature", subprocess.run(["codesign", "--verify", "--deep", "--strict", destination], capture_output=True).returncode == 0)

    damaged = work / "damaged.app"; shutil.copytree(APP, damaged)
    (damaged / "Contents/Resources/LICENSE").write_text("tampered")
    failure = install("--bundle", damaged, ok=False)
    check("damaged_bundle_preserves_install", failure["error"]["code"] == "app_invalid" and hashlib.sha256(helper.read_bytes()).hexdigest() == digest)
    failure = command(DMX, "app", "install", "--bundle", APP, "--directory", destination,
                      "--bin-dir", destination / "Contents/MacOS", ok=False)
    check("cannot_link_cli_inside_signed_app", failure["error"]["code"] == "app_invalid")

    # A complete regular-file archive, then variants changing an actual member's ownership/type.
    members = [("dmx", DMX.read_bytes(), 0o755)] + [("dmx.app/" + str(p.relative_to(APP)), p.read_bytes(), p.stat().st_mode & 0o777)
                                                   for p in sorted(APP.rglob("*")) if p.is_file()]
    def archive(path, extra=None, link_helper=False):
        with tarfile.open(path, "w:gz") as tar:
            for name, data, mode in members:
                info = tarfile.TarInfo(name); info.mode = mode
                if link_helper and name == "dmx.app/Contents/MacOS/dmx":
                    info.type = tarfile.SYMTYPE; info.linkname = str(work / "outside"); tar.addfile(info)
                else:
                    info.size = len(data); tar.addfile(info, io.BytesIO(data))
            if extra:
                info = tarfile.TarInfo(extra); info.size = 6; tar.addfile(info, io.BytesIO(b"attack"))

    outside = work / "outside"; outside.write_text("preserve")
    for label, extra, linked in [("traversal", "dmx.app/../../outside", False), ("duplicate", "dmx.app/Contents/Info.plist", False), ("symlink", None, True)]:
        bad = work / f"{label}.tar.gz"; archive(bad, extra, linked)
        failure = install("--archive", bad, ok=False)
        check("reject_" + label, failure["error"]["code"] == "app_invalid" and outside.read_text() == "preserve" and hashlib.sha256(helper.read_bytes()).hexdigest() == digest)

    release = work / "releases" / ("v" + VERSION); release.mkdir(parents=True)
    packaged = release / f"dmx-{VERSION}-darwin-arm64.tar.gz"; archive(packaged)
    (release / (packaged.name + ".sha256")).write_text(hashlib.sha256(packaged.read_bytes()).hexdigest() + "  " + packaged.name + "\n")
    install("--archive", packaged)
    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Quiet, directory=str(release.parent)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env["DMX_RELEASE_URL"] = f"http://127.0.0.1:{server.server_port}"
    def docker(*args):
        result = subprocess.run([DOCKER, *args], capture_output=True, env={**env, "DOCKER_HOST": "unix://" + str(home / "docker.sock")}, timeout=120)
        if result.returncode: raise AssertionError(result.stderr.decode())
        return result.stdout.strip()
    try:
        started = command(cli, "start")
        pid = started["pid"]
        written = subprocess.run([cli, "exec", "--", "sh", "-c", "echo retained > /var/lib/dmx/update-app-proof"], capture_output=True, env=env, timeout=30)
        check("seed_guest_data", written.returncode == 0, written.stderr.decode())
        container = docker("run", "-d", "--name", "app-update-proof", "-v", "app-update-volume:/proof", "busybox:1.37",
                           "sh", "-c", "echo retained > /proof/marker; exec sleep 600").decode()
        report = command(cli, "update", "--version", VERSION, "--force")
        current = command(cli, "status")
        check("whole_app_update_keeps_running_vm", report["updated"] and Path(report["path"]).resolve() == destination.resolve() and current["pid"] == pid and current["state"] == "running", report)
        probe = subprocess.run([cli, "exec", "--", "cat", "/var/lib/dmx/update-app-proof"], capture_output=True, env=env, timeout=30)
        check("whole_app_update_keeps_guest_data", probe.returncode == 0 and probe.stdout.strip() == b"retained")
        check("whole_app_update_keeps_running_container", docker("inspect", "--format", "{{.Id}} {{.State.Running}}", "app-update-proof").decode() == container + " true")
        check("whole_app_update_keeps_named_volume", docker("exec", "app-update-proof", "cat", "/proof/marker") == b"retained")
        check("whole_app_update_keeps_cli_link_and_signature", cli.is_symlink() and subprocess.run(["codesign", "--verify", "--deep", "--strict", destination], capture_output=True).returncode == 0)
    finally:
        try: command(cli, "stop")
        finally:
            server.shutdown(); server.server_close()
            deadline = time.monotonic() + 15
            while (home / "dmx.sock").exists() and time.monotonic() < deadline: time.sleep(.1)

print(json.dumps({"ok": all(c["ok"] for c in checks), "checks": checks}, indent=2))
