#!/usr/bin/env python3
"""Drive dmx with the stock docker CLI and Compose, on the real VM, in a throwaway DMX_HOME.

Needs `docker` (and the compose plugin, from Homebrew: `brew install docker docker-compose`),
the guest with Docker in it (`make guest`), and the internet (images come from Docker Hub). The
docker CLI talks to $DMX_HOME/docker.sock through DOCKER_HOST and keeps its settings in a
throwaway DOCKER_CONFIG; ~/.docker is not touched. Host ports 20000-20099 are used. Prints one
JSON object and exits non-zero if any check failed.

    python3 -I scripts/test-docker.py [path/to/dmx]
"""

import http.server
import json
import os
import pty
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
DOCKER = shutil.which("docker")
# Homebrew's compose plugin; the docker CLI finds it through cliPluginsExtraDirs.
PLUGINS = ["/opt/homebrew/lib/docker/cli-plugins", "/usr/local/lib/docker/cli-plugins"]
REPO = Path(__file__).resolve().parent.parent

checks = []
results = {}


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:400]})
    return ok


def dmx(*args, timeout=120):
    return subprocess.run([str(DMX), *args], capture_output=True, timeout=timeout, env=ENV)


def docker(*args, stdin=None, timeout=300, cwd=None):
    return subprocess.run([DOCKER, *args], input=stdin, capture_output=True, timeout=timeout, env=ENV, cwd=cwd)


def timed(f, *args, **kwargs):
    started = time.time()
    r = f(*args, **kwargs)
    return r, int((time.time() - started) * 1000)


def status():
    return json.loads(dmx("status", "--json").stdout)


def wait_for(predicate, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(step)
    return False


def daemon_pids():
    out = subprocess.run(["pgrep", "-f", f"{DMX} daemon"], capture_output=True, text=True).stdout
    pids = []
    for pid in out.split():
        env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if f"DMX_HOME={HOME}" in env:
            pids.append(int(pid))
    return pids


def http_get(port, path="/", host="127.0.0.1"):
    try:
        with urllib.request.urlopen(f"http://{host}:{port}{path}", timeout=5) as r:
            return r.read()
    except Exception as e:
        return repr(e).encode()


def forwards():
    return json.loads(dmx("port", "ls", "--json").stdout).get("forwards", [])


def through_pty(argv, script, settle=2.0):
    """Runs argv on a pty, sending each (wait_for_bytes, bytes) of script; returns output and exit code."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(argv[0], argv, ENV)
    out = b""

    def drain(until, seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end and (until is None or until not in out):
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    return

    for until, data in script:
        drain(until, 60)
        try:
            os.write(fd, data)
        except OSError:
            break
    drain(None, settle)
    _, code = os.waitpid(pid, 0)
    os.close(fd)
    return out.decode(errors="replace"), os.waitstatus_to_exitcode(code)


def footprint(label, settle=35):
    """The daemon's footprint once the memory controller had its idle trim (30 s idle)."""
    time.sleep(settle)
    s = status()
    results[f"footprint_{label}_mb"] = s.get("host_footprint_mb")
    results[f"guest_used_{label}_mb"] = s.get("guest_used_mb")


COMPOSE = """\
services:
  web:
    image: busybox
    command: ["sh", "-c", "date > /data/started; exec httpd -f -p 80 -h /www"]
    ports: ["20080:80"]
    volumes:
      - data:/data
      - {site}:/www
  probe:
    image: alpine
    command: ["sleep", "600"]
volumes:
  data: {{}}
"""

DOCKERFILE = """\
FROM alpine
RUN echo built-in-dmx > /built
COPY hello.txt /hello.txt
CMD ["sh", "-c", "cat /built /hello.txt"]
"""

# A short path: Unix socket paths are limited to 104 bytes.
HOME = Path(tempfile.mkdtemp(prefix="dmx-dt-", dir="/tmp"))
DOCKER_CONFIG = HOME / "docker-config"
DOCKER_CONFIG.mkdir()
(DOCKER_CONFIG / "config.json").write_text(json.dumps({"cliPluginsExtraDirs": PLUGINS}))
ENV = {k: v for k, v in os.environ.items() if not k.startswith("DOCKER_")}
ENV.update(DMX_HOME=str(HOME), DOCKER_HOST=f"unix://{HOME}/docker.sock", DOCKER_CONFIG=str(DOCKER_CONFIG))
(HOME / "guest").symlink_to(GUEST)
server = None
try:
    if not check("docker_cli", DOCKER, "install it: brew install docker docker-compose"):
        raise SystemExit
    results["host_load"] = os.getloadavg()[0]

    # Docker's socket is there once a daemon runs; nothing of Docker runs in the guest yet.
    r = dmx("start", "--json")
    check("start", r.returncode == 0 and (HOME / "docker.sock").is_socket(), r.stderr)
    footprint("idle_without_docker")
    r = dmx("exec", "--", "sh", "-c", "pidof dockerd || echo none")
    check("dockerd_lazy", r.stdout.strip() == b"none", r.stdout)

    # First use: unpacks Docker onto the data disk and starts dockerd.
    r, ms = timed(docker, "version", "--format", "{{.Server.Version}}")
    results["first_docker_version_ms"] = ms
    check("docker_version", r.returncode == 0 and r.stdout.strip(), f"{r.stdout!r} {r.stderr!r}")
    results["server_version"] = r.stdout.decode().strip()
    footprint("dockerd_idle")

    r, ms = timed(docker, "run", "--rm", "hello-world")
    results["hello_world_with_pull_ms"] = ms
    check("hello_world", b"Hello from Docker!" in r.stdout, r.stderr)
    r, ms = timed(docker, "run", "--rm", "hello-world")
    results["hello_world_warm_ms"] = ms
    check("hello_world_warm", b"Hello from Docker!" in r.stdout, r.stderr)

    r, ms = timed(docker, "pull", "alpine")
    results["pull_alpine_ms"] = ms
    check("pull", r.returncode == 0, r.stderr)

    # Interactive: a terminal, input, exit status.
    out, code = through_pty([DOCKER, "run", "-it", "--rm", "alpine", "sh"],
                            [(b"# ", b"echo hi-$((40+2))\n"), (b"hi-42", b"exit 3\n")])
    check("run_it", "hi-42" in out and code == 3, f"code {code}: {out[-300:]!r}")

    # docker build of a small Dockerfile with a build context from the Mac.
    ctx = HOME / "build"
    ctx.mkdir()
    (ctx / "Dockerfile").write_text(DOCKERFILE)
    (ctx / "hello.txt").write_text("hello from the mac\n")
    r, ms = timed(docker, "build", "-t", "dmx-test-build", str(ctx))
    results["build_ms"] = ms
    check("build", r.returncode == 0, r.stderr[-400:])
    r = docker("run", "--rm", "dmx-test-build")
    check("build_run", r.stdout == b"built-in-dmx\nhello from the mac\n", r.stdout)

    # Bind mounts: /tmp (a link into /private on the Mac), its real path, and /Users read-only.
    bind = HOME / "bind"
    bind.mkdir()
    (bind / "from-mac").write_text("mac\n")
    r = docker("run", "--rm", "-v", f"{bind}:/b", "alpine", "sh", "-c", "cat /b/from-mac && echo container > /b/from-container")
    check("bind_tmp", r.stdout == b"mac\n" and (bind / "from-container").read_text() == "container\n", f"{r.stdout!r} {r.stderr!r}")
    real = Path("/private") / str(bind).lstrip("/")
    r = docker("run", "--rm", "-v", f"{real}:/b:ro", "alpine", "cat", "/b/from-container")
    check("bind_private", r.stdout == b"container\n", f"{r.stdout!r} {r.stderr!r}")
    r = docker("run", "--rm", "-v", f"{REPO}:/repo:ro", "-w", "/repo", "alpine", "head", "-1", "AGENTS.md")
    check("bind_users_ro", r.stdout == b"# Working on dmx\n", f"{r.stdout!r} {r.stderr!r}")

    # Published ports: forwarded on the Mac while the container runs, where it asked (0.0.0.0 by
    # default, like Docker Desktop), never saved in ports.json.
    r = docker("run", "-d", "--name", "web", "-p", "20081:80", "-p", "127.0.0.1:20082:80", "busybox",
               "sh", "-c", "mkdir /www && echo published > /www/index.html && exec httpd -f -p 80 -h /www")
    check("run_detached", r.returncode == 0, r.stderr)
    ok = wait_for(lambda: http_get(20081) == b"published\n", 10)
    f = {(x["host_address"], x["host_port"]): x for x in forwards()}
    check("published_port", ok and f.get(("0.0.0.0", 20081), {}).get("source") == "docker", f"{http_get(20081)!r} {list(f)}")
    check("published_loopback", http_get(20082) == b"published\n" and ("127.0.0.1", 20082) in f, list(f))
    saved = (HOME / "ports.json").read_text() if (HOME / "ports.json").exists() else "[]"
    check("published_not_saved", "20081" not in saved, saved)
    s = status()
    check("status_containers", s.get("containers") == 1, s.get("containers"))
    footprint("one_container")
    docker("rm", "-f", "web")
    gone = wait_for(lambda: not any(x["host_port"] in (20081, 20082) for x in forwards()), 10)
    check("unpublished", gone and not http_get(20081).startswith(b"published"), forwards())

    # The host from containers: host.docker.internal is the Mac's 127.0.0.1, on the default
    # bridge and on a user-defined network (dockerd's embedded DNS), as with Docker Desktop.
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"hello from the mac\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 20090), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    r = docker("run", "--rm", "alpine", "wget", "-qO-", "http://host.docker.internal:20090/")
    check("host_docker_internal", r.stdout == b"hello from the mac\n", f"{r.stdout!r} {r.stderr!r}")
    docker("network", "create", "dmx-test-net")
    r = docker("run", "--rm", "--network", "dmx-test-net", "alpine", "sh", "-c",
               "wget -qO- http://host.docker.internal:20090/ && nslookup gateway.docker.internal | grep -c 192.168.127.1")
    check("host_docker_internal_network", r.stdout == b"hello from the mac\n1\n", f"{r.stdout!r} {r.stderr!r}")
    r = docker("run", "--rm", "--add-host", "mac:host-gateway", "alpine", "wget", "-qO-", "http://mac:20090/")
    check("host_gateway", r.stdout == b"hello from the mac\n", f"{r.stdout!r} {r.stderr!r}")
    docker("network", "rm", "dmx-test-net")

    # Compose: a named volume, a published port on localhost, a bind mount of a Mac directory.
    app = HOME / "app"
    site = app / "site"
    site.mkdir(parents=True)
    (site / "index.html").write_text("compose on dmx\n")
    (app / "compose.yaml").write_text(COMPOSE.format(site=site))
    r, ms = timed(docker, "compose", "-p", "dmxtest", "up", "-d", cwd=app)
    results["compose_up_ms"] = ms
    check("compose_up", r.returncode == 0, r.stderr[-400:])
    ok = wait_for(lambda: http_get(20080, "/index.html") == b"compose on dmx\n", 15)
    check("compose_port_and_bind", ok, http_get(20080, "/index.html"))
    (site / "index.html").write_text("changed on the mac\n")
    check("compose_bind_live", wait_for(lambda: http_get(20080, "/index.html") == b"changed on the mac\n", 5), http_get(20080, "/index.html"))
    r = docker("compose", "-p", "dmxtest", "exec", "-T", "probe", "wget", "-qO-", "http://web/index.html", cwd=app)
    check("compose_network_dns", r.stdout == b"changed on the mac\n", f"{r.stdout!r} {r.stderr!r}")
    first = docker("compose", "-p", "dmxtest", "exec", "-T", "web", "cat", "/data/started", cwd=app).stdout
    docker("compose", "-p", "dmxtest", "restart", "web", cwd=app)
    kept = docker("compose", "-p", "dmxtest", "exec", "-T", "web", "ls", "/data", cwd=app).stdout
    check("compose_volume", first and kept == b"started\n", f"{first!r} {kept!r}")
    r = docker("compose", "-p", "dmxtest", "down", "-v", cwd=app)
    check("compose_down", r.returncode == 0 and docker("volume", "ls", "-q").stdout.strip() == b"", r.stderr[-300:])

    # A running container keeps the VM up past idle_timeout; once it is gone the VM stops, and
    # the next Docker client boots it and dockerd again (cold start, images kept on the disk).
    dmx("config", "set", "idle_timeout", "3s")
    dmx("stop")
    dmx("start")
    docker("run", "-d", "--name", "sleeper", "busybox", "sleep", "600")
    time.sleep(8)
    s = status()
    check("container_holds_vm", s["state"] == "running" and s.get("containers") == 1, f"{s['state']} {s.get('containers')}")
    docker("rm", "-f", "sleeper")
    stopped = wait_for(lambda: status()["state"] == "stopped", 15)
    check("idle_stop_after_containers", stopped, status()["state"])
    dmx("config", "unset", "idle_timeout")
    # Without launchd nothing else would answer on docker.sock, so the daemon stays (VM stopped).
    time.sleep(12)
    check("standalone_daemon_stays", daemon_pids() and (HOME / "docker.sock").is_socket(), daemon_pids())
    r, ms = timed(docker, "run", "--rm", "hello-world")
    results["hello_world_cold_ms"] = ms
    check("hello_world_cold", b"Hello from Docker!" in r.stdout, r.stderr)
    r, ms = timed(docker, "run", "--rm", "hello-world")
    results["hello_world_warm2_ms"] = ms

    # A standalone daemon that served Docker stays to answer on docker.sock.
    dmx("stop")
    time.sleep(12)
    check("standalone_daemon_after_stop", not daemon_pids() and not (HOME / "docker.sock").exists(), daemon_pids())
except subprocess.TimeoutExpired as e:
    check("no_timeout", False, f"{e.cmd} timed out after {e.timeout} s")
finally:
    if server:
        server.shutdown()
    try:
        docker("compose", "-p", "dmxtest", "down", "-v", timeout=60, cwd=HOME / "app")
    except Exception:
        pass
    for pid in daemon_pids():
        os.kill(pid, signal.SIGTERM)
    wait_for(lambda: not daemon_pids(), 20)
    # The daemon and guest logs outlive the throwaway home when something failed.
    if not all(c["ok"] for c in checks):
        logs = Path(tempfile.gettempdir()) / f"dmx-dockertest-logs-{os.getpid()}"
        shutil.copytree(HOME / "logs", logs, dirs_exist_ok=True)
        results["logs"] = str(logs)
    shutil.rmtree(HOME, ignore_errors=True)

ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
