#!/usr/bin/env python3
"""Pinned Docker image workloads on the real dmx VM, for arm64 and amd64.

`--pin` resolves only registry metadata and writes image-matrix.json; normal runs pull only
the recorded per-platform digests. Uses dmx's verified CLI, an isolated Docker config and
DMX_HOME, no host shares, two CPUs and a 4G ceiling. stdout is a JSON report; progress is stderr.
Failures and timeouts remain failures, including known x86 page-size incompatibilities.
`--state-dir /tmp/dmx-images-X` keeps image layers for a focused rerun (`--image java`).
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PINS = ROOT / "scripts/image-matrix.json"
IMAGES = {
    "alpine": ("library/alpine", "3.24"),
    "debian": ("library/debian", "trixie-slim"),
    "ubuntu": ("library/ubuntu", "24.04"),
    "python": ("library/python", "3.14-slim"),
    "node": ("library/node", "24-alpine"),
    "nginx": ("library/nginx", "stable-alpine"),
    "redis": ("library/redis", "8-alpine"),
    "postgres": ("library/postgres", "18-alpine"),
    "java": ("library/eclipse-temurin", "21-jdk-jammy"),
}
PLATFORMS = ("linux/arm64", "linux/amd64")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")


def progress(message):
    print(message, file=sys.stderr, flush=True)


def pin_images():
    """Trust the registry's TLS for metadata; verify each manifest against its digest."""
    pins = {"schema": 1, "pinned_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "images": {}}
    for name, (repo, tag) in IMAGES.items():
        url = "https://auth.docker.io/token?" + urllib.parse.urlencode({
            "service": "registry.docker.io", "scope": f"repository:{repo}:pull"})
        with urllib.request.urlopen(url, timeout=30) as r:
            token = json.load(r)["token"]

        def manifest(ref):
            request = urllib.request.Request(f"https://registry-1.docker.io/v2/{repo}/manifests/{ref}", headers={
                "Authorization": f"Bearer {token}",
                "Accept": ", ".join(["application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
                                     "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"]),
            })
            with urllib.request.urlopen(request, timeout=30) as r:
                body = r.read(8 << 20)
                digest = "sha256:" + hashlib.sha256(body).hexdigest()
                if digest != r.headers.get("Docker-Content-Digest") or (DIGEST.fullmatch(ref) and ref != digest):
                    raise ValueError(f"manifest digest mismatch for {repo}:{ref}")
            return json.loads(body), digest

        index, digest = manifest(tag)
        entry = {"repository": repo, "tag": tag, "index_digest": digest, "platforms": {}}
        for platform in PLATFORMS:
            system, arch = platform.split("/")
            matches = [m for m in index["manifests"] if m.get("platform", {}).get("os") == system
                       and m["platform"].get("architecture") == arch
                       and m["platform"].get("variant", "v8" if arch == "arm64" else "") in ("", "v8")]
            if len(matches) != 1 or not DIGEST.fullmatch(matches[0]["digest"]):
                raise ValueError(f"expected one {platform} manifest for {repo}:{tag}")
            child, child_digest = manifest(matches[0]["digest"])
            if "layers" not in child or not DIGEST.fullmatch(child["config"]["digest"]):
                raise ValueError(f"invalid image manifest for {repo}:{tag}")
            entry["platforms"][platform] = child_digest
        pins["images"][name] = entry
        progress(f"pinned {name}: {repo}:{tag} {digest}")
    PINS.write_text(json.dumps(pins, indent=2) + "\n")


PYTHON = r"""
import json, mmap, os, sqlite3, tempfile
with tempfile.TemporaryDirectory() as d:
    path = d + '/db'
    c = sqlite3.connect(path)
    assert c.execute('pragma journal_mode=wal').fetchone()[0] == 'wal'
    c.execute('pragma mmap_size=1048576')
    c.execute('create table data (n integer)')
    c.executemany('insert into data values (?)', [(n,) for n in range(10000)])
    c.commit(); c.close()
    c = sqlite3.connect(path)
    assert c.execute('select sum(n) from data').fetchone()[0] == 49995000
    c.close()
    with open(d + '/map', 'w+b') as f:
        f.truncate(65536)
        with mmap.mmap(f.fileno(), 65536) as m:
            m[4096:4100] = b'dmx!'; m.flush()
            try: m.flush(4096, 4096); partial = True
            except (OSError, ValueError): partial = False
    print(json.dumps({'sqlite_wal': True, 'mmap_full_flush': True,
                      'pagesize': mmap.PAGESIZE, 'flush_4k_offset': partial}))
"""

NODE = r"""
const { Worker } = require('node:worker_threads');
const fs = require('node:fs');
let sum = 0; for (let i = 0; i < 1000000; i++) sum += i;
if (sum !== 499999500000) throw Error('JIT sum');
const code = Buffer.from('0061736d010000000105016000017f030201000707010372756e00000a06010400412a0b', 'hex');
if (new WebAssembly.Instance(new WebAssembly.Module(code)).exports.run() !== 42) throw Error('Wasm');
fs.writeFileSync('/tmp/data', 'persist');
new Worker(`const {parentPort}=require('node:worker_threads');parentPort.postMessage(42)`, {eval:true})
 .on('message', n => {if(n !== 42 || fs.readFileSync('/tmp/data','utf8') !== 'persist') throw Error('worker'); console.log('node-jit-wasm-worker-ok')});
"""

JAVA = r"""
import java.nio.*; import java.nio.channels.*; import java.nio.file.*;
public class Smoke {
 public static void main(String[] args) throws Exception {
  long sum=0; for(int r=0;r<100;r++) for(int i=0;i<100000;i++) sum+=i;
  if(sum!=499995000000L) throw new AssertionError(sum);
  Thread t=new Thread(()->{if(Math.sqrt(1764)!=42) throw new AssertionError();}); t.start(); t.join();
  try(var f=FileChannel.open(Path.of("/tmp/mapped"), StandardOpenOption.CREATE, StandardOpenOption.READ, StandardOpenOption.WRITE)) {
   f.position(65535); f.write(ByteBuffer.wrap(new byte[]{0}));
   var m=f.map(FileChannel.MapMode.READ_WRITE,0,65536); m.putInt(4096,42); m.force();
   m.force(4096,4096); if(m.getInt(4096)!=42) throw new AssertionError();
  }
  System.out.println("java-jit-thread-mmap-ok");
 }
}
"""


class Matrix:
    def __init__(self, binary, state):
        self.binary = str(binary)
        self.state = state
        self.tools = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "cache/docker-tools"
        self.docker = str(self.tools / "bin/docker")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "BUILDX_", "COMPOSE_"))}
        self.env.update(DMX_HOME=str(state), DOCKER_HOST=f"unix://{state}/docker.sock",
                        DOCKER_CONFIG=str(state / "docker-config"), HOME=str(state / "user-home"),
                        PATH=f"{self.tools / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin")
        (state / "docker-config").mkdir(exist_ok=True)
        (state / "user-home").mkdir(exist_ok=True)
        self.case = None
        self.platform = None
        self.qemu_guest_base = None

    def cli(self, *args, **kw):
        if self.qemu_guest_base and self.platform == "linux/amd64" and args[0] in ("run", "exec"):
            args = (args[0], "-e", "QEMU_GUEST_BASE=" + self.qemu_guest_base, *args[1:])
        return self.call(self.docker, *args, **kw)

    def dmx(self, *args, **kw):
        return self.call(self.binary, *args, **kw)

    def call(self, *args, stdin=None, timeout=180, env=None, combined=False):
        r = subprocess.run(args, input=stdin, capture_output=True, timeout=timeout, env=env or self.env)
        if r.returncode:
            raise RuntimeError(f"exit {r.returncode}: {' '.join(args[:5])}\n{r.stdout.decode(errors='replace')[-1500:]}\n{r.stderr.decode(errors='replace')[-3000:]}")
        return (r.stdout + (r.stderr if combined else b"")).decode(errors="replace").strip()

    def start(self):
        progress("verifying dmx's Docker tools")
        self.dmx("tools", "install", "--json", env={**self.env, "DMX_HOME": str(self.tools)}, timeout=900)
        self.dmx("start", "--json")
        return self.cli("version", "--format", "{{.Client.Version}} / {{.Server.Version}}")

    def stop(self):
        if not (self.state / "dmx.sock").exists():
            return
        # quit stops the daemon too, so temporary state is not removed under a live process.
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(30); s.connect(str(self.state / "dmx.sock"))
            body = json.dumps({"id": 1, "method": "quit", "params": {}}).encode()
            s.sendall(struct.pack(">I", len(body) + 1) + b"\0" + body)
            while s.recv(65536): pass
        deadline = time.monotonic() + 30
        while (self.state / "dmx.sock").exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        if (self.state / "dmx.sock").exists():
            raise RuntimeError("daemon did not exit; state kept")

    def run(self, image, platform, *argv, detach=False, stdin=None):
        return self.cli("run", *( ["-d"] if detach else ["-i"] if stdin else [] ), "--pull", "never",
                        "--platform", platform, "--name", self.case, "--network", "none", "--memory", "1g",
                        "--cpus", "2", "--pids-limit", "256", "--ulimit", "core=0:0", image, *argv, stdin=stdin)

    def ready(self, *argv, timeout=90):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try: return self.cli("exec", self.case, *argv, timeout=10)
            except (RuntimeError, subprocess.TimeoutExpired) as e: last = str(e)
            state = json.loads(self.cli("inspect", self.case))[0]["State"]
            if not state["Running"]: raise RuntimeError(f"container stopped: {state}")
            time.sleep(0.5)
        raise RuntimeError(f"readiness timed out: {last}")

    def workload(self, name, image, platform):
        if name in ("alpine", "debian", "ubuntu"):
            out = self.run(image, platform, "sh", "-c", "uname -m; getconf PAGESIZE 2>/dev/null || true; printf dmx | sha256sum")
            assert hashlib.sha256(b"dmx").hexdigest() in out, out
            return out
        if name == "python":
            out = json.loads(self.run(image, platform, "python", "-c", PYTHON))
            assert out["sqlite_wal"] and out["mmap_full_flush"], out
            return out
        if name == "node":
            out = self.run(image, platform, "node", "-e", NODE)
            assert out == "node-jit-wasm-worker-ok", out
            return out
        if name == "java":
            out = self.run(image, platform, "sh", "-c", "cat >/tmp/Smoke.java; javac /tmp/Smoke.java && java -Xmx256m -cp /tmp Smoke", stdin=JAVA.encode())
            assert out == "java-jit-thread-mmap-ok", out
            return out
        if name == "nginx":
            self.run(image, platform, detach=True)
            self.ready("nginx", "-t")
            self.cli("exec", self.case, "sh", "-c", "printf dmx-http >/usr/share/nginx/html/matrix.html")
            out = self.ready("wget", "-qO-", "http://127.0.0.1/matrix.html")
            assert out == "dmx-http", out
            self.cli("restart", self.case)
            assert self.ready("wget", "-qO-", "http://127.0.0.1/matrix.html") == out
            return "HTTP body survives restart (container loopback, no host port)"
        if name == "redis":
            self.run(image, platform, "redis-server", "--appendonly", "yes", "--appendfsync", "always", detach=True)
            assert self.ready("redis-cli", "PING") == "PONG"
            assert self.cli("exec", self.case, "redis-cli", "SET", "matrix", "42") == "OK"
            out = self.cli("exec", self.case, "redis-cli", "BGSAVE")
            assert "Background saving started" in out, out
            self.ready("sh", "-c", "redis-cli INFO persistence | grep -q '^rdb_bgsave_in_progress:0' && "
                       "redis-cli INFO persistence | grep -q '^rdb_last_bgsave_status:ok'")
            self.cli("restart", self.case)
            assert self.ready("redis-cli", "GET", "matrix") == "42"
            return "SET/GET, BGSAVE and AOF persistence across restart"
        if name == "postgres":
            # Pass init configuration before the image, unlike the shared run() helper.
            self.cli("run", "-d", "--pull", "never", "--platform", platform, "--name", self.case,
                     "--network", "none", "--memory", "1g", "--cpus", "2", "--pids-limit", "256",
                     "--ulimit", "core=0:0", "-e", "POSTGRES_PASSWORD=matrix-test", image)
            self.ready("pg_isready", "-U", "postgres")
            sql = "begin; create table if not exists matrix(n int); truncate matrix; insert into matrix select generate_series(1,10000); commit; checkpoint; select sum(n) from matrix;"
            out = self.ready("psql", "-U", "postgres", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql)
            assert out.splitlines()[-1] == "50005000", out
            self.cli("restart", self.case)
            out = self.ready("psql", "-U", "postgres", "-At", "-v", "ON_ERROR_STOP=1", "-c", "select sum(n) from matrix")
            assert out == "50005000", out
            return "initdb, 10000-row SQL transaction, checkpoint and restart persistence"
        raise ValueError(name)

    def test(self, name, entry, platform):
        self.case = "matrix-" + name + "-" + platform.split("/")[-1]
        self.platform = platform
        digest = entry["platforms"][platform]
        if not DIGEST.fullmatch(digest): raise ValueError("unpinned image")
        image = entry["repository"] + "@" + digest
        result = {"name": name, "platform": platform, "image": image, "tag": entry["tag"], "ok": False}
        started = time.monotonic()
        progress(f"{name} {platform}: pulling {digest}")
        try:
            self.cli("pull", "--platform", platform, image, timeout=600)
            info = json.loads(self.cli("image", "inspect", image))[0]
            assert info["Architecture"] == platform.split("/")[-1], info["Architecture"]
            result["image_id"] = info["Id"]
            self.cli("rm", "-fv", self.case) if self._exists() else None
            progress(f"{name} {platform}: running workload")
            workload_at = time.monotonic()
            result["detail"] = self.workload(name, image, platform)
            result["workload_s"] = round(time.monotonic() - workload_at, 2)
            result["ok"] = True
        except (RuntimeError, AssertionError, subprocess.TimeoutExpired) as e:
            result["error"] = str(e)
        finally:
            if self._exists():
                result["state"] = json.loads(self.cli("inspect", self.case))[0]["State"]
                result["logs"] = self.cli("logs", "--tail", "30", self.case, combined=True)[-4000:]
                self.cli("rm", "-fv", self.case)
            result["elapsed_s"] = round(time.monotonic() - started, 2)
            progress(f"{name} {platform}: {'PASS' if result['ok'] else 'FAIL'} ({result['elapsed_s']} s)")
        return result

    def _exists(self):
        r = subprocess.run([self.docker, "inspect", self.case], capture_output=True, timeout=30, env=self.env)
        return r.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmx", nargs="?", default=".build/release/dmx")
    parser.add_argument("--pin", action="store_true", help="resolve metadata and update pins; runs no images")
    parser.add_argument("--image", choices=IMAGES, action="append")
    parser.add_argument("--platform", choices=PLATFORMS, action="append")
    parser.add_argument("--qemu-guest-base", help="set QEMU_GUEST_BASE in amd64 run/exec for diagnosis (0 restores upstream "
                        "QEMU's layout); never used in a default run")
    parser.add_argument("--x86-emulator", choices=["fex", "qemu"], default="fex",
                        help="what runs the amd64 images (the x86_emulator setting); default fex, as dmx's own default")
    parser.add_argument("--state-dir", type=Path, help="keep isolated state/layers for reruns; use a short path under /tmp")
    args = parser.parse_args()
    if args.pin:
        pin_images()
        return 0
    pins = json.loads(PINS.read_text())
    assert pins["schema"] == 1
    state = args.state_dir.resolve() if args.state_dir else Path(tempfile.mkdtemp(prefix="dmx-im-", dir="/tmp"))
    state.mkdir(exist_ok=True)
    marker = state / ".image-matrix"
    if any(state.iterdir()) and not marker.exists():
        raise ValueError("state directory belongs to something else")
    marker.touch()
    guest = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
    if not (state / "guest").exists(): (state / "guest").symlink_to(guest)
    (state / "config.json").write_text(json.dumps({"cpus": 2, "memory": "4G", "shares": [], "idle_timeout": 600, "disk_size": "16G",
                                                   "x86_emulator": args.x86_emulator}))
    matrix = Matrix(Path(args.dmx).resolve(), state)
    matrix.qemu_guest_base = args.qemu_guest_base
    report = {"ok": False, "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "pins_at": pins["pinned_at"], "cpus": 2, "ceiling_mb": 4096, "host_load": os.getloadavg(),
              "x86_emulator": args.x86_emulator, "qemu_guest_base": args.qemu_guest_base, "results": []}
    try:
        report["docker_versions"] = matrix.start()
        report["guest"] = matrix.dmx("exec", "--", "sh", "-c", "uname -r; awk '/^KernelPageSize/{print $2;exit}' /proc/self/smaps")
        for platform in args.platform or PLATFORMS:
            for name in args.image or IMAGES:
                report["results"].append(matrix.test(name, pins["images"][name], platform))
        report["ok"] = all(r["ok"] for r in report["results"])
        report["status"] = json.loads(matrix.dmx("status", "--json"))
        log = matrix.dmx("exec", "--", "dmesg")
        report["kernel_problems"] = [line for line in log.splitlines()
                                     if any(t in line for t in ("module verification failed", "BUG:", "soft lockup"))]
        report["ok"] = report["ok"] and not report["kernel_problems"]
    except Exception as e:
        report["fatal_error"] = str(e)
    finally:
        try:
            matrix.stop()
            if not args.state_dir: shutil.rmtree(state)
        finally:
            print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
