#!/usr/bin/env python3
"""Verifies a dmx release as a user gets it: a fresh install, an update from the previous release with
a running VM, container and volume, and the release's own fix. Isolated from ~/.dmx and the installed app.
    test-release.py local <dist-root>   a local mirror of the release directory (DMX_RELEASE_URL)
    test-release.py public            the public GitHub URLs
"""
import ctypes, http.server, json, os, plistlib, shutil, socketserver, subprocess, sys, tempfile, threading, time
from pathlib import Path

VERSION, PREVIOUS = "0.4.6", "0.4.5"
mode = sys.argv[1]
PUBLIC = "https://github.com/cothis/dmx/releases/download"
checks = []
def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})
    print(name, bool(ok), str(detail)[:200], flush=True)

ROOT = Path(tempfile.mkdtemp(prefix="dmx045-", dir="/private/tmp"))
base = PUBLIC
server = None
if mode == "local":
    dist = Path(sys.argv[2]).resolve()
    class H(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k): super().__init__(*a, directory=str(dist), **k)
        def log_message(self, *a): pass
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"

def run(cmd, env, timeout=400, stdin=None):
    return subprocess.run(cmd, env=env, capture_output=True, timeout=timeout, input=stdin)

def install(area, version, script_base):
    area.mkdir(parents=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "DMX_"))}
    env.update(DMX_HOME=str(area / "home"), PREFIX=str(area / "prefix"), DMX_APP_DIR=str(area / "Applications/dmx.app"),
               DOCKER_CONFIG=str(area / "docker-config"), DOCKER_HOST=f"unix://{area}/home/docker.sock",
               PATH=f"{area}/prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    if mode == "local" and script_base != PUBLIC:
        env["DMX_RELEASE_URL"] = script_base
    (area / "docker-config").mkdir()
    (area / "docker-config/config.json").write_text("{}")
    (area / "home").mkdir()
    script = area / "install.sh"
    subprocess.run(["curl", "-fsSL", "-o", script, f"{script_base}/v{version}/install.sh"], check=True)
    r = run(["sh", str(script)], env, timeout=600)
    return env, r

def dmx(area, env, *args, timeout=400):
    return run([str(area / "prefix/bin/dmx"), *args], env, timeout=timeout)
def docker(env, area, *args, timeout=400, stdin=None):
    return run([str(area / "home/bin/docker"), *args], env, timeout=timeout, stdin=stdin)
def status(area, env):
    return json.loads(dmx(area, env, "status", "--json").stdout)
def signed(area):
    app = area / "Applications/dmx.app"
    a = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True).returncode == 0
    b = subprocess.run(["xcrun", "stapler", "validate", str(app)], capture_output=True).returncode == 0
    c = subprocess.run(["spctl", "-a", "-t", "exec", str(app)], capture_output=True).returncode == 0
    d = b"V4YA23448U" in subprocess.run(["codesign", "-dv", str(app)], capture_output=True).stderr
    return a and b and c and d, {"codesign": a, "stapled": b, "gatekeeper": c, "team": d}

BOTO = r"""
import boto3
from botocore import UNSIGNED
from botocore.config import Config
for region in ('us-east-1', 'ap-northeast-2'):
    c = boto3.client('s3', region_name=region, config=Config(signature_version=UNSIGNED, retries={'max_attempts': 1}, connect_timeout=8, read_timeout=8))
    try:
        c.head_bucket(Bucket='dmx-dns-test-nonexistent-1'); print(region, 'ok')
    except c.exceptions.ClientError as e:
        print(region, e.response['Error']['Code'])
"""
GAI = r"""
import socket, struct, sys
ns = [l.split()[1] for l in open('/etc/resolv.conf') if l.startswith('nameserver')][0]
name = 'dmx-dns-test.s3.ap-northeast-2.amazonaws.com'
q = struct.pack('>HHHHHH', 1, 0x100, 1, 0, 0, 0) + b''.join(bytes([len(p)]) + p.encode() for p in name.split('.')) + b'\0' + struct.pack('>HH', 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(8); s.sendto(q, (ns, 53)); r = s.recv(4096)
flags = struct.unpack('>H', r[2:4])[0]
print('tc', flags >> 9 & 1, 'bytes', len(r), 'inet', len(socket.getaddrinfo(name, 443, socket.AF_INET, socket.SOCK_STREAM)), 'unspec', len(socket.getaddrinfo(name, 443, type=socket.SOCK_STREAM)))
"""

AF_INET6_ALONE = r"""
import socket, sys, time
started = time.time()
try:
    socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET6, socket.SOCK_STREAM)
    outcome = "addresses"
except socket.gaierror as error:
    outcome = "no_address" if error.errno == socket.EAI_NODATA else f"error_{error.errno}"
print(outcome, round(time.time() - started, 2))
"""
# A record registered as shared answers A and leaves AAAA silent, with no network setting changed.
dnssd = ctypes.CDLL("/usr/lib/libSystem.dylib")
dnssd_ref, record = ctypes.c_void_p(), ctypes.c_void_p()
registered = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int32, ctypes.c_void_p)(lambda *_: None)
SILENT = f"dmx-release-aaaa-{os.getpid()}.local"
assert dnssd.DNSServiceCreateConnection(ctypes.byref(dnssd_ref)) == 0
assert dnssd.DNSServiceRegisterRecord(dnssd_ref, ctypes.byref(record), ctypes.c_uint32(0x10), ctypes.c_uint32(0), f"{SILENT}.".encode(),
                                      ctypes.c_uint16(1), ctypes.c_uint16(1), ctypes.c_uint16(4), bytes([192, 0, 2, 1]), ctypes.c_uint32(60), registered, None) == 0
time.sleep(2)

try:
    # A fresh install.
    area = ROOT / "fresh"
    env, r = install(area, VERSION, base)
    check("fresh_install", r.returncode == 0, r.stderr[-300:] or r.stdout[-200:])
    v = dmx(area, env, "--version").stdout.decode().strip()
    check("fresh_version", v == VERSION, v)
    ok, detail = signed(area)
    check("fresh_signed_notarized_stapled", ok, detail)
    check("fresh_guest_starts_missing", not (area / "home/guest").exists())
    r = dmx(area, env, "boot", "--selftest", "--json", timeout=500)
    d = json.loads(r.stdout or b"{}")
    check("fresh_selftest", r.returncode == 0 and d.get("ok") is True, {"checks": len(d.get("checks", [])), "footprint_mb": d.get("host", {}).get("footprint_mb")})
    receipt = json.loads((area / "home/guest/release.json").read_text())
    check("fresh_guest_from_release", receipt.get("tag") == f"v{VERSION}", receipt.get("tag"))
    dmx(area, env, "start", "--json")
    for platform, want in (("linux/arm64", "aarch64"), ("linux/amd64", "x86_64"), ("linux/386", "x86_64")):
        r = docker(env, area, "run", "--rm", "--platform", platform, "alpine", "uname", "-m")
        check(f"fresh_container_{platform.replace('/', '_')}", r.stdout.decode().strip() == want, r.stdout + r.stderr[-200:])
    # The release's own fix, with the published binary.
    for image in ("python:3-slim", "python:3-alpine"):
        tag = image.split("-")[1]
        r = docker(env, area, "run", "--rm", "-i", image, "python", "-u", "-c", GAI, timeout=200)
        out = r.stdout.decode().split()
        check(f"fix_s3_name_{tag}", r.returncode == 0 and out[:2] == ["tc", "0"] and int(out[3]) < 512 and int(out[5]) > 0 and int(out[7]) > 0, r.stdout + r.stderr[-200:])
        for platform in (["--platform", "linux/amd64"] if tag == "slim" else []), []:
            r = docker(env, area, "run", "--rm", "-i", *platform, image, "sh", "-c",
                       "pip install -q --root-user-action=ignore --disable-pip-version-check boto3 >/dev/null 2>&1; python -u -", stdin=BOTO.encode(), timeout=300)
            text = r.stdout.decode()
            check(f"fix_boto3_{tag}{'_amd64' if platform else ''}", r.returncode == 0 and text.count("404") == 2, text + r.stderr.decode()[-200:])
    r = docker(env, area, "run", "--rm", "python:3-slim", "python", "-u", "-c", AF_INET6_ALONE, SILENT, timeout=100)
    out = r.stdout.decode().split()
    check("fix_af_inet6_alone", len(out) >= 2 and out[0] == "no_address" and 0.8 < float(out[1]) < 4.5, r.stdout[:40] + r.stderr[-200:])
    dmx(area, env, "stop", "--json")
    time.sleep(12)

    # An update from the previous public release with a running VM, container and volume.
    area = ROOT / "upgrade"
    env, r = install(area, PREVIOUS, PUBLIC)
    check("previous_install", r.returncode == 0, r.stderr[-300:])
    check("previous_version", dmx(area, env, "--version").stdout.decode().strip() == PREVIOUS)
    if "DMX_RELEASE_URL" in env: del env["DMX_RELEASE_URL"]
    dmx(area, env, "start", "--json")
    r = docker(env, area, "run", "-d", "--name", "kept", "-v", "dmxproof:/data", "busybox", "sh", "-c", "echo kept > /data/f && exec sleep 3600")
    check("previous_container", r.returncode == 0, r.stderr[-200:])
    cid = r.stdout.decode().strip()
    time.sleep(1)
    before = status(area, env)
    update_env = dict(env)
    if mode == "local":
        update_env["DMX_RELEASE_URL"] = base
    args = ["update", "--json"] + (["--version", VERSION] if mode == "local" else [])
    r = dmx(area, update_env, *args, timeout=500)
    report = json.loads(r.stdout or b"{}")
    check("update_ok", r.returncode == 0, {k: report.get(k) for k in ("version", "handover", "installed")} if report else r.stderr[-300:])
    check("update_to_version", dmx(area, env, "--version").stdout.decode().strip() == VERSION)
    ok, detail = signed(area)
    check("update_signed_notarized_stapled", ok, detail)
    after = status(area, env)
    check("update_keeps_vm", after.get("pid") == before.get("pid") and after.get("state") == "running", {"before": before.get("pid"), "after": after.get("pid"), "version": after.get("version")})
    r = docker(env, area, "exec", "kept", "cat", "/data/f")
    check("update_keeps_container", r.stdout == b"kept\n", r.stdout + r.stderr[-200:])
    docker(env, area, "stop", "-t", "1", "kept")
    dmx(area, env, "stop", "--json")
    time.sleep(13)
    start_env = dict(env)
    if mode == "local":
        start_env["DMX_RELEASE_URL"] = base
    r = dmx(area, start_env, "start", "--json", timeout=300)
    now = status(area, env)
    check("restart_serves_new_version", r.returncode == 0 and now.get("version") == VERSION and now.get("state") == "running", {k: now.get(k) for k in ("version", "state")})
    r = docker(env, area, "start", "kept")
    r = docker(env, area, "inspect", "-f", "{{.Id}}", "kept")
    check("restart_keeps_container", r.stdout.decode().strip() == cid, r.stdout[:80])
    r = docker(env, area, "run", "--rm", "-v", "dmxproof:/data", "busybox", "cat", "/data/f")
    check("restart_keeps_volume", r.stdout == b"kept\n", r.stdout + r.stderr[-200:])
    receipt = json.loads((area / "home/guest/release.json").read_text())
    check("update_guest_receipt", receipt.get("tag") == f"v{VERSION}", receipt.get("tag"))
    r = docker(env, area, "run", "--rm", "-i", "python:3-slim", "python", "-u", "-c", GAI, timeout=300)
    out = r.stdout.decode().split()
    check("update_fix_s3_name", r.returncode == 0 and out[:2] == ["tc", "0"] and int(out[7]) > 0, r.stdout + r.stderr[-200:])
    r = docker(env, area, "run", "--rm", "python:3-slim", "python", "-u", "-c", AF_INET6_ALONE, SILENT, timeout=100)
    out = r.stdout.decode().split()
    check("update_fix_af_inet6_alone", len(out) >= 2 and out[0] == "no_address" and 0.8 < float(out[1]) < 4.5, r.stdout[:40] + r.stderr[-200:])
    docker(env, area, "rm", "-f", "kept")
    dmx(area, env, "stop", "--json")
    time.sleep(12)
finally:
    if server: server.shutdown()
    dnssd.DNSServiceRefDeallocate(dnssd_ref)
    failed = [c["name"] for c in checks if not c["ok"]]
    print(json.dumps({"mode": mode, "version": VERSION, "previous": PREVIOUS, "ok": not failed and len(checks) > 0, "total": len(checks), "failed": failed, "root": str(ROOT), "checks": checks}, default=str))
