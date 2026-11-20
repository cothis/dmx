#!/usr/bin/env python3
"""Import check: `dmx import` brings a Compose project over from a real second engine.

On the other engine (Colima, OrbStack, Docker Desktop or Rancher Desktop, given with --from) it
builds a small Compose project: an image built there, a named volume with files of another
owner, a private mode, a hard link and a symlink, an anonymous volume from the image's VOLUME, an image pulled by digest,
two networks, a service sharing another's network namespace (`network_mode: service:web`) and
one service left running. Then, into a throwaway DMX_HOME (its own data disk and daemon), it runs
`dmx import --dry-run` (nothing may change), `dmx import --project`, and the same again (all
`exists`). In dmx, `docker compose up -d` from the same directory has to start the project
without recreating anything but the service in web's namespace, and the files, owners, modes, links, the built image, the shared
namespace and the port have to be there; `compose down -v` has to remove the anonymous volume
too. The other engine must be left as it was, helpers included. Prints one JSON object; exits
non-zero if a check failed. About a minute after the first pull.

Uses dmx's own docker CLI and Compose plugin (`dmx tools install`). Host port 20181 is used.

    python3 -I scripts/test-import.py [path/to/dmx] --from colima
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
from pathlib import Path

ENGINES = {
    "docker-desktop": ".docker/run/docker.sock",
    "orbstack": ".orbstack/run/docker.sock",
    "colima": ".colima/default/docker.sock",
    "rancher-desktop": ".rd/docker.sock",
}

parser = argparse.ArgumentParser()
parser.add_argument("dmx", nargs="?", default=".build/release/dmx")
parser.add_argument("--from", dest="source", required=True, help=", ".join(ENGINES) + " or unix:///path")
args = parser.parse_args()

DMX = Path(args.dmx).resolve()
USER_DMX = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx")
DOCKER = str(USER_DMX / "bin" / "docker")
PLUGINS = USER_DMX / "cli-plugins"
SOURCE_SOCKET = args.source[len("unix://"):] if args.source.startswith("unix://") else str(Path.home() / ENGINES[args.source])
PROJECT = "dmximport"
PORT = 20181
ALPINE = "alpine@sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42"  # Bench.image

HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="dmx-import-", dir="/tmp")))
DOCKER_CONFIG = HOME / "docker-config"
DOCKER_CONFIG.mkdir()
(DOCKER_CONFIG / "config.json").write_text(json.dumps({"cliPluginsExtraDirs": [str(PLUGINS)]}))
(HOME / "guest").symlink_to(USER_DMX / "guest")
(HOME / "bin").symlink_to(USER_DMX / "bin")  # dmx import runs $DMX_HOME/bin/docker
BASE = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "BUILDX_", "COMPOSE_"))}
BASE.update(DMX_HOME=str(HOME), DOCKER_CONFIG=str(DOCKER_CONFIG), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
DMX_ENV = {**BASE, "DOCKER_HOST": f"unix://{HOME}/docker.sock"}
SRC_ENV = {**BASE, "DOCKER_HOST": f"unix://{SOURCE_SOCKET}"}
APP = HOME / "app"

COMPOSE = f"""\
name: {PROJECT}
services:
  web:
    build: ./web
    image: {PROJECT}-web:test
    init: true
    command: ["sleep", "600"]
    ports: ["127.0.0.1:{PORT}:80"]
    volumes: ["data:/data"]
    networks: [front, back]
    restart: unless-stopped
  sidecar:
    image: {ALPINE}
    init: true
    command: ["sleep", "600"]
    network_mode: "service:web"
    depends_on: [web]
  worker:
    image: {PROJECT}-web:test
    init: true
    command: ["sleep", "600"]
    volumes: ["data:/data:ro"]
    networks: [back]
volumes:
  data: {{}}
networks:
  front: {{}}
  back: {{}}
"""
DOCKERFILE = f"""\
FROM {ALPINE}
RUN echo built-on-source > /built.txt
VOLUME /cache
"""
FILL = ("mkdir /data/secret && echo hi > /data/secret/f && chown -R 999:999 /data/secret && chmod 700 /data/secret"
        " && ln -s secret/f /data/link && ln /data/secret/f /data/hard && echo anon > /cache/a.txt")

checks = []
results = {"source": args.source}
T0 = time.monotonic()


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:400]})
    return ok


def progress(message):
    print(f"import: {message}", file=sys.stderr, flush=True)


def run(env, *a, timeout=300, cwd=None):
    return subprocess.run(list(a), capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd)


def src(*a, **kw):
    return run(SRC_ENV, DOCKER, *a, **kw)


def dst(*a, **kw):
    return run(DMX_ENV, DOCKER, *a, **kw)


def dmx(*a, timeout=600):
    return run(DMX_ENV, str(DMX), *a, timeout=timeout)


def inventory(docker):
    """What an engine has, by name, without its state (a stopped container stays stopped)."""
    def lines(*a):
        return sorted(docker(*a).stdout.split())
    return {"containers": lines("ps", "-a", "--format", "{{.Names}}:{{.State}}"),
            "images": lines("images", "--format", "{{.Repository}}:{{.Tag}}@{{.ID}}"),
            "volumes": lines("volume", "ls", "-q"), "networks": lines("network", "ls", "--format", "{{.Name}}")}


def daemon_pids():
    out = subprocess.run(["pgrep", "-f", f"{DMX} daemon"], capture_output=True, text=True).stdout
    pids = []
    for pid in out.split():
        env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if f"DMX_HOME={HOME}" in env:
            pids.append(int(pid))
    return pids


def import_json(*extra):
    r = dmx("import", "--from", args.source, "--project", PROJECT, "--json", *extra)
    try:
        return r.returncode, json.loads(r.stdout)
    except json.JSONDecodeError:
        return r.returncode, {"stdout": r.stdout[-300:], "stderr": r.stderr[-300:]}


had_alpine = False
try:
    if not check("docker_tools", os.access(DOCKER, os.X_OK) and (PLUGINS / "docker-compose").exists(),
                 f"{DOCKER} and {PLUGINS}/docker-compose; run `dmx tools install`"):
        raise SystemExit
    info = src("info", "--format", "{{.ServerVersion}} {{.Driver}}")
    if not check("source_answers", info.returncode == 0, info.stderr[-300:] or SOURCE_SOCKET):
        raise SystemExit
    results["source_engine"] = info.stdout.strip()

    progress(f"building the project in {args.source}")
    (APP / "web").mkdir(parents=True)
    (APP / "compose.yaml").write_text(COMPOSE)
    (APP / "web" / "Dockerfile").write_text(DOCKERFILE)
    src("compose", "-p", PROJECT, "down", "-v", "--rmi", "local", cwd=APP, timeout=120)
    had_alpine = src("image", "inspect", ALPINE).returncode == 0
    r = src("compose", "up", "-d", "--build", cwd=APP, timeout=600)
    check("source_up", r.returncode == 0, r.stderr[-300:])
    r = src("compose", "exec", "-T", "web", "sh", "-c", FILL, cwd=APP)
    check("source_fill", r.returncode == 0, r.stderr[-300:])
    r = src("compose", "stop", "web", "sidecar", cwd=APP, timeout=120)
    check("source_stop", r.returncode == 0, r.stderr[-300:])
    before = inventory(src)

    r = dmx("start", "--json")
    check("dmx_start", r.returncode == 0, r.stderr[-300:])
    empty = inventory(dst)

    progress("dmx import --dry-run")
    code, dry = import_json("--dry-run")
    check("dry_run", code == 0 and dry.get("dry_run") and all(i["action"] == "planned" for i in dry.get("items", [])),
          [(i["kind"], i["action"]) for i in dry.get("items", [])] or dry)
    check("dry_run_changes_nothing", inventory(dst) == empty, inventory(dst))

    progress("dmx import --project")
    t = time.monotonic()
    code, rep = import_json()
    results["import_s"] = round(time.monotonic() - t, 1)
    items = rep.get("items", [])
    results["items"] = [f"{i['kind']} {i['name'][:24]} {i['action']}" for i in items]
    kinds = {}
    for i in items:
        if i["action"] == "imported":
            kinds[i["kind"]] = kinds.get(i["kind"], 0) + 1
    check("import_ok", code == 0 and rep.get("ok"), rep.get("error") or [i for i in items if i["action"] != "imported"])
    # Two images (the built one, and alpine by digest for the sidecar), two networks, three
    # containers, the named volume and web's and worker's anonymous /cache.
    check("import_counts", kinds == {"image": 2, "volume": 3, "network": 2, "container": 3}, kinds)
    worker = next((i for i in items if i["name"] == f"{PROJECT}-worker-1"), {})
    check("running_noted", "running in" in (worker.get("detail") or ""), worker)
    check("live_copy_warned", any(f"{PROJECT}_data" in w and "worker" in w for w in rep.get("warnings", [])), rep.get("warnings"))
    check("created_not_started", all(c.endswith(":created") for c in inventory(dst)["containers"]), inventory(dst)["containers"])

    code, again = import_json()
    check("second_run_exists", code == 0 and again.get("items") and all(i["action"] == "exists" for i in again["items"]),
          [(i["kind"], i["action"]) for i in again.get("items", [])])

    progress("docker compose up -d in dmx")
    r = dst("compose", "up", "-d", cwd=APP, timeout=300)
    out = r.stdout + r.stderr
    check("compose_up", r.returncode == 0, out[-300:])
    # Compose hashes `service:web` resolved to web's container ID into the sidecar's config hash;
    # IDs are new in dmx, so the sidecar (only) is recreated, as it would be after web changed.
    others = [line for line in out.splitlines() if "Creat" in line and "sidecar" not in line]
    check("compose_no_recreate", not others, out[-400:])
    sidecar = dst("inspect", f"{PROJECT}-sidecar-1", "--format", "{{.Config.Image}}").stdout.strip()
    check("digest_name_kept", sidecar == ALPINE, sidecar)
    r = dst("compose", "ps", "--format", "{{.Service}}:{{.State}}", cwd=APP)
    check("compose_running", sorted(r.stdout.split()) == ["sidecar:running", "web:running", "worker:running"], r.stdout)

    r = dst("compose", "exec", "-T", "web", "sh", "-c",
            "cat /built.txt; stat -c '%u %g %a' /data/secret; stat -c %h /data/hard; readlink /data/link; cat /data/link; cat /cache/a.txt",
            cwd=APP)
    check("data", r.stdout.split("\n")[:6] == ["built-on-source", "999 999 700", "2", "secret/f", "hi", "anon"], r.stdout + r.stderr[-200:])
    web = dst("inspect", f"{PROJECT}-web-1", "--format", "{{.Id}}").stdout.strip()
    mode = dst("inspect", f"{PROJECT}-sidecar-1", "--format", "{{.HostConfig.NetworkMode}}").stdout.strip()
    check("shared_namespace", web and mode == f"container:{web}", f"{mode} vs web {web[:12]}")
    port = dst("port", f"{PROJECT}-web-1", "80").stdout.strip()
    check("port", port == f"127.0.0.1:{PORT}", port)
    aliases = dst("inspect", f"{PROJECT}-worker-1", "--format", "{{json .NetworkSettings.Networks}}").stdout
    check("service_alias", '"worker"' in aliases, aliases[:200])

    r = dst("compose", "down", "-v", cwd=APP, timeout=120)
    check("compose_down", r.returncode == 0, r.stderr[-300:])
    left = inventory(dst)
    # `down` without --rmi keeps images.
    check("down_removes_everything", not left["containers"] and not left["volumes"]
          and sorted(left["networks"]) == ["bridge", "host", "none"], left)

    after = inventory(src)
    check("source_unchanged", after == before, {k: (before[k], after[k]) for k in before if before[k] != after[k]})
    helpers = src("ps", "-a", "-q", "--filter", "label=dmx.import=helper").stdout.split()
    check("no_source_helpers", not helpers, helpers)
except subprocess.TimeoutExpired as e:
    check("no_timeout", False, f"{e.cmd} timed out after {e.timeout} s")
except SystemExit:
    pass
finally:
    try:
        src("compose", "-p", PROJECT, "down", "-v", "--rmi", "local", cwd=APP, timeout=120)
        if not had_alpine:
            src("rmi", ALPINE, timeout=60)
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
    if not all(c["ok"] for c in checks) and (HOME / "logs").exists():
        logs = Path(tempfile.gettempdir()) / f"dmx-import-logs-{os.getpid()}"
        shutil.copytree(HOME / "logs", logs, dirs_exist_ok=True)
        results["logs"] = str(logs)
    shutil.rmtree(HOME, ignore_errors=True)

results["total_s"] = round(time.monotonic() - T0)
ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
