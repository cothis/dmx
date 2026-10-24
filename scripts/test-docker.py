#!/usr/bin/env python3
"""Drive dmx with the stock docker CLI, Compose and Buildx, on the real VM, in a throwaway DMX_HOME.

Uses only the docker tools dmx provides (`dmx tools install`, pinned and sha256-checked), never
Homebrew's: they are installed once into $DMX_HOME/cache/docker-tools (the cache the guest build
uses; ~115 MB the first time) and called by absolute path. Needs the guest with Docker in it
(`make guest`) and the internet (images come from Docker Hub). The docker CLI talks to
$DMX_HOME/docker.sock through DOCKER_HOST and keeps its settings in a throwaway DOCKER_CONFIG, and
links go into a throwaway HOME; ~/.docker and ~/.local/bin are not touched. Host ports
20000-20099 and 21053-21082 are used. Prints one JSON object and exits non-zero if any check failed.

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
# dmx's own docker tools, kept between runs (pinned, so a cache is safe): the DMX_HOME that
# `dmx tools install` installs into for this test.
TOOLS = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "cache" / "docker-tools"
DOCKER = str(TOOLS / "bin" / "docker")
REPO = Path(__file__).resolve().parent.parent

checks = []
results = {}


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:400]})
    return ok


def dmx(*args, timeout=120):
    return subprocess.run([str(DMX), *args], capture_output=True, timeout=timeout, env=ENV)


def docker(*args, stdin=None, timeout=300, cwd=None, env_extra=None):
    return subprocess.run([DOCKER, *args], input=stdin, capture_output=True, timeout=timeout, env={**ENV, **(env_extra or {})}, cwd=cwd)


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


def udp_echo(port, payload, tries=20):
    """Sends a datagram to the Mac's port until one comes back; returns the reply or None."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(1)
        for _ in range(tries):
            s.sendto(payload, ("127.0.0.1", port))
            try:
                return s.recv(65536)
            except socket.timeout:
                continue
    return None


def check_udp():
    """A published UDP port: datagrams from the Mac reach the container and replies come back,
    one stream per peer, as on Docker Desktop."""
    try:
        r = docker("run", "-d", "--name", "udp-echo", "-p", "127.0.0.1:21053:53/udp", "busybox",
                   "udpsvd", "0", "53", "dd", "bs=65536")  # cat would read datagrams 4 KB at a time
        check("udp_run", r.returncode == 0, r.stderr)
        got = udp_echo(21053, b"ping over udp")
        f = [x for x in forwards() if x["host_port"] == 21053]
        check("udp_published", got == b"ping over udp" and f and f[0].get("protocol") == "udp", f"{got!r} {f}")
        big = os.urandom(8192)  # macOS sends at most 9216 bytes (net.inet.udp.maxdgram)
        check("udp_large_datagram", udp_echo(21053, big) == big)
        check("udp_second_peer", udp_echo(21053, b"another peer") == b"another peer")
    finally:
        docker("rm", "-f", "udp-echo")
    check("udp_unpublished", wait_for(lambda: not any(x["host_port"] == 21053 for x in forwards()), 10), forwards())


TAKEN_COMPOSE = """\
services:
  web:
    image: busybox
    command: ["sleep", "600"]
    ports: ["21081:80"]
"""


def check_port_taken():
    """A host port another program listens on fails `docker run -p` and `docker compose up` with
    Docker Desktop's error; once it is free, the port answers as soon as `docker run` returns."""
    blocker = socket.socket()
    blocker.bind(("127.0.0.1", 21081))
    blocker.listen()
    try:
        r = docker("run", "-d", "--name", "taken", "-p", "21081:80", "busybox", "sleep", "600")
        state = docker("inspect", "-f", "{{.State.Status}}", "taken").stdout.strip()
        check("port_taken_run", r.returncode != 0 and b"Ports are not available" in r.stderr and b"21081" in r.stderr, r.stderr)
        check("port_taken_not_running", state == b"created", state)
        docker("rm", "-f", "taken")
        # Attached with --rm: the CLI waits for the container to be removed, as dockerd does after
        # a failed start.
        r = docker("run", "--rm", "--name", "taken-rm", "-p", "127.0.0.1:21081:80", "busybox", "true", timeout=60)
        gone = docker("inspect", "taken-rm").returncode != 0
        check("port_taken_run_rm", r.returncode != 0 and b"Ports are not available" in r.stderr and gone, r.stderr)
        app = HOME / "taken"
        app.mkdir()
        (app / "compose.yaml").write_text(TAKEN_COMPOSE)
        r = docker("compose", "-p", "dmxtaken", "up", "-d", cwd=app)
        check("port_taken_compose", r.returncode != 0 and b"Ports are not available" in r.stderr, r.stderr[-400:])
        docker("compose", "-p", "dmxtaken", "down", cwd=app)
    finally:
        blocker.close()
    try:
        r = docker("run", "-d", "--name", "at-once", "-p", "127.0.0.1:21081:80", "busybox",
                   "sh", "-c", "mkdir /www && echo at-once > /www/index.html && exec httpd -f -p 80 -h /www")
        # httpd itself needs a moment after the start; the port was listened on before it.
        ok = r.returncode == 0 and wait_for(lambda: http_get(21081) == b"at-once\n", 5)
        check("port_free_again", ok, f"{r.stderr!r} {http_get(21081)!r}")
    finally:
        docker("rm", "-f", "at-once")


def check_restart_policy():
    """A container with a restart policy comes back when the VM boots, without a Docker client; one
    stopped with `docker stop` does not bring dockerd up at boot."""
    try:
        r = docker("run", "-d", "--name", "keeper", "--restart", "unless-stopped", "-p", "127.0.0.1:21082:80", "busybox",
                   "sh", "-c", "mkdir -p /www && echo kept > /www/index.html && exec httpd -f -p 80 -h /www")
        check("restart_policy_run", r.returncode == 0, r.stderr)
        dmx("stop")
        dmx("start")
        started = time.time()
        back = wait_for(lambda: http_get(21082) == b"kept\n", 120, step=0.5)
        results["restart_policy_back_ms"] = int((time.time() - started) * 1000)
        s = status()
        check("restart_policy_at_boot", back and s.get("containers") == 1, f"{http_get(21082)!r} {s.get('containers')}")
        docker("stop", "keeper")
        dmx("stop")
        dmx("start")
        time.sleep(5)
        r = dmx("exec", "--", "sh", "-c", "pidof dockerd || echo none")
        check("no_dockerd_after_docker_stop", r.stdout.strip() == b"none", r.stdout)
    finally:
        docker("rm", "-f", "keeper")


def check_amd64():
    """An amd64 image through qemu-x86_64, which now comes from docker.img."""
    r = docker("run", "--rm", "--platform", "linux/amd64", "alpine", "uname", "-m")
    check("amd64_image", r.stdout.strip() == b"x86_64", f"{r.stdout!r} {r.stderr[-300:]!r}")


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

# BuildKit only: two stages, and a cache mount that keeps its contents when the step reruns
# (a new N; --no-cache would give the step a fresh cache mount too).
MULTISTAGE = """\
FROM alpine AS build
ARG N
RUN --mount=type=cache,target=/cache echo run >> /cache/runs && wc -l < /cache/runs | tr -d ' ' > /count
FROM busybox
COPY --from=build /count /count
CMD ["cat", "/count"]
"""

COMPOSE_BUILD = """\
services:
  built:
    build: .
    image: dmx-test-compose-build
"""

# A short path: Unix socket paths are limited to 104 bytes.
HOME = Path(tempfile.mkdtemp(prefix="dmx-dt-", dir="/tmp"))
DOCKER_CONFIG = HOME / "docker-config"
DOCKER_CONFIG.mkdir()
# A home of its own for the links `dmx tools install` makes, first on PATH; Homebrew's docker and
# plugins are never used: the CLI runs by absolute path, and only dmx's plugin directory is listed.
USER_HOME = HOME / "home"
LINKS = USER_HOME / ".local" / "bin"
ENV = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "BUILDX_", "COMPOSE_"))}
ENV.update(DMX_HOME=str(HOME), DOCKER_HOST=f"unix://{HOME}/docker.sock", DOCKER_CONFIG=str(DOCKER_CONFIG),
           HOME=str(USER_HOME), PATH=f"{LINKS}:{TOOLS / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin")
(HOME / "guest").symlink_to(GUEST)
server = None
try:
    results["host_load"] = os.getloadavg()[0]

    # dmx's docker tools: installed (or found present, sha256 checked) in the tools home, linked
    # into the throwaway ~/.local/bin, plugins listed in the throwaway docker config.
    r, ms = timed(subprocess.run, [str(DMX), "tools", "install", "--json"], capture_output=True, timeout=900,
                  env={**ENV, "DMX_HOME": str(TOOLS)})
    results["tools_install_ms"] = ms
    report = json.loads(r.stdout or b"{}")
    results["tools_downloaded_mb"] = sum(t.get("downloaded_bytes", 0) for t in report.get("tools", [])) >> 20
    if not check("tools_install", r.returncode == 0 and Path(DOCKER).is_file(), r.stdout[-400:] + r.stderr[-400:]):
        raise SystemExit
    check("tools_on_path", report.get("dmx_docker_on_path") and shutil.which("docker", path=ENV["PATH"]) == str(LINKS / "docker"),
          report.get("docker_on_path"))
    config = json.loads((DOCKER_CONFIG / "config.json").read_text())
    check("tools_plugins_config", config.get("cliPluginsExtraDirs") == [str(TOOLS / "cli-plugins")], config)
    r = docker("version", "--format", "{{.Client.Version}}")
    results["client_version"] = r.stdout.decode().strip()
    check("client_is_dmx", r.stdout.strip() == b"29.9.2", f"{r.stdout!r} {r.stderr!r}")
    r = docker("compose", "version", "--short")
    check("compose_version", r.stdout.strip() == b"5.6.1", f"{r.stdout!r} {r.stderr!r}")
    r = docker("buildx", "version")
    check("buildx_version", b" v0.38.1 " in r.stdout, f"{r.stdout!r} {r.stderr!r}")

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

    # Both plugins are dmx's copies, found through cliPluginsExtraDirs.
    r = docker("info", "--format", "{{json .ClientInfo.Plugins}}")
    plugins = {p.get("Name"): p.get("Path", "") for p in json.loads(r.stdout or b"[]") if isinstance(p, dict)}
    check("plugins_from_dmx", all(plugins.get(n, "").startswith(str(TOOLS)) for n in ("compose", "buildx")), plugins)

    # docker build of a small Dockerfile with a build context from the Mac: BuildKit through the
    # buildx plugin and dockerd's built-in BuildKit (the default builder, docker driver).
    r = docker("buildx", "ls")
    check("buildx_ls", r.returncode == 0 and b"docker" in r.stdout and b"running" in r.stdout, f"{r.stdout!r} {r.stderr!r}")
    ctx = HOME / "build"
    ctx.mkdir()
    (ctx / "Dockerfile").write_text(DOCKERFILE)
    (ctx / "hello.txt").write_text("hello from the mac\n")
    r, ms = timed(docker, "build", "-t", "dmx-test-build", str(ctx))
    results["build_ms"] = ms
    check("build", r.returncode == 0, r.stderr[-400:])
    check("build_is_buildkit", b"building with" in r.stderr and b"Step 1/" not in r.stdout + r.stderr, r.stderr[:300])
    r = docker("run", "--rm", "dmx-test-build")
    check("build_run", r.stdout == b"built-in-dmx\nhello from the mac\n", r.stdout)
    # The same build without cache, with BuildKit and with the deprecated legacy builder (timing only).
    r, ms = timed(docker, "build", "--no-cache", "-t", "dmx-test-build", str(ctx))
    results["build_buildkit_no_cache_ms"] = ms
    r, ms = timed(docker, "build", "--no-cache", "-t", "dmx-test-build-legacy", str(ctx), env_extra={"DOCKER_BUILDKIT": "0"})
    results["build_legacy_no_cache_ms"] = ms if r.returncode == 0 else None

    # Multi-stage with a cache mount: the second run of the step sees what the first left.
    multi = HOME / "multi"
    multi.mkdir()
    (multi / "Dockerfile").write_text(MULTISTAGE)
    r, ms = timed(docker, "build", "--build-arg", f"N={time.time()}", "-t", "dmx-test-multi", str(multi))
    results["build_multistage_ms"] = ms
    first = docker("run", "--rm", "dmx-test-multi").stdout.strip()
    r2 = docker("build", "--build-arg", f"N={time.time()}", "-t", "dmx-test-multi", str(multi))
    second = docker("run", "--rm", "dmx-test-multi").stdout.strip()
    check("build_cache_mount", r.returncode == 0 and r2.returncode == 0 and first.isdigit() and second.isdigit()
          and int(second) == int(first) + 1, f"{first!r} {second!r} {r.stderr[-300:]!r} {r2.stderr[-300:]!r}")

    # docker compose build (Compose hands it to Buildx).
    cb = HOME / "compose-build"
    cb.mkdir()
    (cb / "Dockerfile").write_text(DOCKERFILE)
    (cb / "hello.txt").write_text("hello from compose\n")
    (cb / "compose.yaml").write_text(COMPOSE_BUILD)
    r, ms = timed(docker, "compose", "-p", "dmxtestbuild", "build", cwd=cb)
    results["compose_build_ms"] = ms
    out = docker("run", "--rm", "dmx-test-compose-build").stdout
    check("compose_build", r.returncode == 0 and out == b"built-in-dmx\nhello from compose\n", f"{out!r} {r.stderr[-300:]!r}")

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
    check_udp()
    check_port_taken()
    check_amd64()

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

    check_restart_policy()

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
