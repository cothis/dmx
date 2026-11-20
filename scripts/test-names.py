#!/usr/bin/env python3
"""Local names check: `<container>.dmx.local` and `<service>.<project>.dmx.local` on the real VM.

In a throwaway DMX_HOME, `dmx names setup --no-system` with test ports (macOS is left alone:
no trust change, no resolver file), then containers: nginx, a Compose-labelled service, one
with the dmx.http-port label, one sharing another's network namespace. Checks the DNS answers,
HTTP and HTTPS routing by Host and server name (curl --resolve and --cacert with the CA file),
the 404 for unknown names, that connections to the Mac's LAN address are refused, 200 parallel
HTTPS requests, a 100 MB download, a container publishing the HTTP port taking it over and names
taking it back, `dmx stop` emptying the table, and `dmx names remove`. Prints one JSON object;
exits non-zero if a check failed. About a minute after the first pulls.

Uses dmx's docker CLI (`dmx tools install`). Ports 18080, 18443 and 15353/udp are used.

    python3 -I scripts/test-names.py [path/to/dmx]
"""

import concurrent.futures
import hashlib
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
USER_DMX = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx")
DOCKER = str(USER_DMX / "bin" / "docker")
HTTP, HTTPS, DNS = 18080, 18443, 15353
NGINX = "nginx:alpine"
PYTHON = "python:3-alpine"

HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="dmx-names-", dir="/tmp")))
(HOME / "guest").symlink_to(USER_DMX / "guest")
(HOME / "bin").symlink_to(USER_DMX / "bin")
BASE = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "BUILDX_", "COMPOSE_"))}
ENV = {**BASE, "DMX_HOME": str(HOME), "DOCKER_HOST": f"unix://{HOME}/docker.sock", "DOCKER_CONFIG": str(HOME / "docker-config")}
CA = HOME / "names" / "ca.pem"

checks = []
results = {}
T0 = time.monotonic()


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)[:400]})
    return ok


def progress(message):
    print(f"names: {message}", file=sys.stderr, flush=True)


def run(*a, timeout=300):
    return subprocess.run(list(a), capture_output=True, text=True, timeout=timeout, env=ENV)


def dmx(*a, timeout=300):
    return run(str(DMX), *a, timeout=timeout)


def docker(*a, timeout=300):
    return run(DOCKER, *a, timeout=timeout)


def names_json():
    r = dmx("names", "ls", "--json")
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"stdout": r.stdout[-300:], "stderr": r.stderr[-300:]}


def curl(url, *extra, timeout=20):
    """Status, body. Names resolve to 127.0.0.1 through --resolve, as the resolver file would."""
    host = url.split("/")[2]
    name, port = host.rsplit(":", 1)
    r = subprocess.run(["curl", "-s", "-m", str(timeout), "--cacert", str(CA), "--resolve", f"{name}:{port}:127.0.0.1",
                        "-w", "\n%{http_code} %{http_version}", *extra, url], capture_output=True, timeout=timeout + 5)
    body, _, tail = r.stdout.rpartition(b"\n")
    return tail.decode(errors="replace"), body


def dns(name, qtype=1):
    q = struct.pack(">HHHHHH", 0x4242, 0x0100, 1, 0, 0, 0)
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode()
    q += b"\0" + struct.pack(">HH", qtype, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    try:
        s.sendto(q, ("127.0.0.1", DNS))
        reply = s.recv(512)
    except OSError as e:
        return {"error": str(e)}
    finally:
        s.close()
    rcode, answers = reply[3] & 0x0F, struct.unpack(">H", reply[6:8])[0]
    return {"rcode": rcode, "answers": answers, "address": socket.inet_ntoa(reply[-4:]) if answers else None}


def daemon_pids():
    out = subprocess.run(["pgrep", "-f", f"{DMX} daemon"], capture_output=True, text=True).stdout
    pids = []
    for pid in out.split():
        env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if f"DMX_HOME={HOME}" in env:
            pids.append(int(pid))
    return pids


def wait_for(predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    return predicate()


def daemon_fds():
    pids = daemon_pids()
    if not pids:
        return None
    out = subprocess.run(["lsof", "-n", "-P", "-p", str(pids[0]), "-F", "f"], capture_output=True, text=True).stdout
    return sum(1 for line in out.splitlines() if line[1:].isdigit())


def tls_hello(name):
    """A TLS handshake with server name `name`, verification off; True if it completed."""
    import ssl
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection(("127.0.0.1", HTTPS), timeout=5) as raw:
            with context.wrap_socket(raw, server_hostname=name):
                return True
    except (OSError, ssl.SSLError):
        return False


def lan_address():
    for interface in ["en0", "en1"]:
        r = subprocess.run(["ipconfig", "getifaddr", interface], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    return None


try:
    (HOME / "docker-config").mkdir()
    if not check("docker_tools", os.access(DOCKER, os.X_OK), f"{DOCKER}; run `dmx tools install`"):
        raise SystemExit
    for port in [HTTP, HTTPS]:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                check("ports_free", False, f"something listens on {port}")
                raise SystemExit

    progress("dmx names setup --no-system")
    r = dmx("names", "setup", "--no-system", "--dns-port", str(DNS), "--http-port", str(HTTP), "--https-port", str(HTTPS), "--json")
    setup = json.loads(r.stdout or "{}")
    check("setup", r.returncode == 0 and setup.get("enabled") and setup.get("authority") and CA.exists(), r.stdout[-300:] + r.stderr[-200:])
    check("setup_leaves_macos_alone", not setup.get("trusted") and not any("trusted" in c or "resolver" in c for c in setup.get("changes", [])),
          setup.get("changes"))
    mode = oct((HOME / "names" / "ca.key").stat().st_mode & 0o777)
    check("ca_key_private", mode == "0o600", mode)

    progress("containers")
    r = dmx("start", "--json")
    check("dmx_start", r.returncode == 0, r.stderr[-300:])
    for image in [NGINX, PYTHON]:
        docker("pull", image, timeout=600)
    compose = ["--label", "com.docker.compose.project=shop", "--label", "com.docker.compose.service=front",
               "--label", "com.docker.compose.container-number=1"]
    started = [
        docker("run", "-d", "--name", "web", NGINX),
        docker("run", "-d", "--name", "shop-front-1", *compose, PYTHON, "python", "-m", "http.server", "3000"),
        docker("run", "-d", "--name", "api", "--label", "dmx.http-port=8000", PYTHON, "python", "-m", "http.server", "8000"),
        docker("run", "-d", "--name", "Side_Car", "--network", "container:web", "--label", "dmx.http-port=80", PYTHON, "sleep", "600"),
    ]
    check("containers_run", all(c.returncode == 0 for c in started), [c.stderr[-200:] for c in started if c.returncode])
    docker("exec", "web", "sh", "-c", "head -c 100000000 /dev/urandom > /usr/share/nginx/html/big.bin")
    expected = {"web.dmx.local", "front.shop.dmx.local", "shop-front-1.dmx.local", "api.dmx.local", "side-car.dmx.local"}
    listed = wait_for(lambda: (lambda n: n if expected <= {e["name"] for e in n.get("daemon", {}).get("names", [])} else None)(names_json()), 10)
    names = {e["name"]: e for e in (listed or names_json()).get("daemon", {}).get("names", [])}
    results["names"] = sorted(names)
    check("names_listed", expected <= set(names), sorted(names))
    check("service_port_guessed", names.get("front.shop.dmx.local", {}).get("port") == 80, names.get("front.shop.dmx.local"))
    check("label_port", names.get("api.dmx.local", {}).get("port") == 8000, names.get("api.dmx.local"))
    check("shared_namespace_address", names.get("side-car.dmx.local", {}).get("address") == names.get("web.dmx.local", {}).get("address"),
          (names.get("side-car.dmx.local"), names.get("web.dmx.local")))

    progress("dns")
    a = dns("Web.dmx.local")
    check("dns_a", a.get("rcode") == 0 and a.get("address") == "127.0.0.1", a)
    check("dns_any_name", dns("not-running.dmx.local").get("address") == "127.0.0.1")
    aaaa = dns("web.dmx.local", 28)
    check("dns_aaaa_empty", aaaa.get("rcode") == 0 and aaaa.get("answers") == 0, aaaa)
    other = dns("example.com")
    check("dns_refuses_others", other.get("rcode") == 5, other)

    progress("http and https")
    status, body = curl(f"http://web.dmx.local:{HTTP}/")
    check("http_container", status == "200 1.1" and b"Welcome to nginx" in body, status)
    status, body = curl(f"https://web.dmx.local:{HTTPS}/")
    check("https_container", status == "200 1.1" and b"Welcome to nginx" in body, status)
    status, body = curl(f"https://side-car.dmx.local:{HTTPS}/")
    check("https_shared_namespace", status == "200 1.1" and b"Welcome to nginx" in body, status)
    status, body = curl(f"https://api.dmx.local:{HTTPS}/")
    check("https_label_port", status.startswith("200 ") and b"Directory listing" in body, status)
    # The python service listens on 3000 and exposes nothing: port 80 refuses, and the 502 says why.
    status, body = curl(f"http://front.shop.dmx.local:{HTTP}/")
    check("bad_gateway_explains", status.startswith("502") and b"dmx.http-port" in body, (status, body[:200]))
    status, body = curl(f"http://nope.dmx.local:{HTTP}/")
    check("unknown_name_404", status.startswith("404") and b"web.dmx.local" in body, (status, body[:200]))
    r = subprocess.run(["curl", "-sv", "-m", "10", "--cacert", str(CA), "--resolve", f"front.shop.dmx.local:{HTTPS}:127.0.0.1",
                        f"https://front.shop.dmx.local:{HTTPS}/", "-o", "/dev/null"], capture_output=True, text=True)
    check("leaf_for_the_name", "CN=front.shop.dmx.local" in r.stderr and "CN=dmx local names CA" in r.stderr
          and "ALPN: server accepted http/1.1" in r.stderr, r.stderr[-400:])
    status, _ = curl(f"https://web.dmx.local:{HTTPS}/", "--cacert", "/etc/ssl/cert.pem")
    check("untrusted_without_ca", status.startswith("000"), status)

    # Names and handshakes that go nowhere cost the daemon nothing that stays: no listener for a
    # name no container has, and failed handshakes close their sockets.
    time.sleep(2)
    fds_before = daemon_fds()
    unknown = [tls_hello(f"nobody-{i}.dmx.local") for i in range(200)]
    check("tls_unknown_names_refused", not any(unknown), f"{sum(unknown)} of 200 completed")
    for _ in range(50):
        curl(f"https://web.dmx.local:{HTTPS}/", "--cacert", "/etc/ssl/cert.pem")
    time.sleep(3)
    fds_after = daemon_fds()
    check("tls_failures_leave_no_fds", fds_before is not None and fds_after is not None and fds_after <= fds_before + 4,
          f"{fds_before} -> {fds_after}")
    # A container reaching the Mac: names would hand it any container's web port, so the web
    # ports and the per-name TLS listeners on 127.0.0.1 refuse it. A plain Mac port answers (the
    # control: a refusal must be the guard, not a container that cannot connect at all).
    control = socket.socket()
    control.bind(("127.0.0.1", 0))
    control.listen(8)
    control_port = control.getsockname()[1]
    tls_ports = []
    pid = (daemon_pids() or [None])[0]
    if pid:
        out = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP@127.0.0.1", "-sTCP:LISTEN", "-F", "n"],
                             capture_output=True, text=True).stdout
        tls_ports = sorted({int(l.rsplit(":", 1)[1]) for l in out.splitlines() if l.startswith("n127.0.0.1:")} - {HTTP, HTTPS})
    probe = " ; ".join(f"nc -z -w 3 host.docker.internal {p} && echo {p}:open || echo {p}:closed"
                       for p in [control_port, HTTP, HTTPS] + tls_ports)
    r = docker("run", "--rm", "--network", "bridge", "alpine", "sh", "-c", probe, timeout=120)
    control.close()
    seen = dict(line.split(":") for line in r.stdout.split() if ":" in line)
    check("container_reaches_mac_port", seen.get(str(control_port)) == "open", seen)
    check("container_cannot_reach_names", seen.get(str(HTTP)) == "closed" and seen.get(str(HTTPS)) == "closed", seen)
    check("container_cannot_reach_tls_listeners", tls_ports and all(seen.get(str(p)) == "closed" for p in tls_ports),
          f"tls listener ports {tls_ports}: {seen}")

    lan = lan_address()
    if lan:
        r = subprocess.run(["curl", "-s", "-m", "5", "-H", "Host: web.dmx.local", "-w", "%{http_code}", f"http://{lan}:{HTTP}/"],
                           capture_output=True, text=True)
        check("lan_refused", r.stdout.strip() == "000", f"{lan}: {r.stdout}")
    results["lan_address_checked"] = bool(lan)

    progress("200 parallel https requests, a 100 MB download")
    with concurrent.futures.ThreadPoolExecutor(50) as pool:
        codes = list(pool.map(lambda _: curl(f"https://web.dmx.local:{HTTPS}/")[0], range(200)))
    results["parallel"] = {c: codes.count(c) for c in set(codes)}
    check("parallel_https", codes.count("200 1.1") == 200, results["parallel"])
    want = docker("exec", "web", "sha256sum", "/usr/share/nginx/html/big.bin").stdout.split()[:1]
    for scheme, port in [("http", HTTP), ("https", HTTPS)]:
        t = time.monotonic()
        status, body = curl(f"{scheme}://web.dmx.local:{port}/big.bin", timeout=120)
        results[f"{scheme}_100mb_s"] = round(time.monotonic() - t, 2)
        check(f"{scheme}_download", status == "200 1.1" and [hashlib.sha256(body).hexdigest()] == want, (status, len(body)))

    progress("a container publishing the HTTP port takes it")
    r = docker("run", "-d", "--name", "pub", "-p", f"{HTTP}:80", NGINX)
    check("publish_http_port", r.returncode == 0, r.stderr[-300:])
    state = wait_for(lambda: (lambda s: s if s.startswith("yielded") else None)(names_json().get("daemon", {}).get("listeners", {}).get("http", "")), 10)
    check("names_yield", state, state)
    docker("rm", "-f", "pub")
    state = wait_for(lambda: names_json().get("daemon", {}).get("listeners", {}).get("http") == "listening", 15)
    status, _ = curl(f"http://web.dmx.local:{HTTP}/")
    check("names_take_it_back", state and status == "200 1.1", (state, status))

    progress("dmx stop, then remove")
    dmx("stop", "--json", timeout=60)
    status, body = curl(f"http://web.dmx.local:{HTTP}/")
    check("stopped_vm_404", status.startswith("404") and b"no container is running" in body, (status, body[:200]))
    r = dmx("names", "remove", "--json")
    removed = json.loads(r.stdout or "{}")
    check("remove", r.returncode == 0 and not removed.get("enabled") and not (HOME / "names").exists(), r.stdout[-300:])
    with socket.socket() as s:
        closed = s.connect_ex(("127.0.0.1", HTTP)) != 0
    check("remove_stops_listening", closed and "error" in dns("web.dmx.local"), closed)
except subprocess.TimeoutExpired as e:
    check("no_timeout", False, f"{e.cmd} timed out after {e.timeout} s")
except SystemExit:
    pass
finally:
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
        logs = Path(tempfile.gettempdir()) / f"dmx-names-logs-{os.getpid()}"
        shutil.copytree(HOME / "logs", logs, dirs_exist_ok=True)
        results["logs"] = str(logs)
    shutil.rmtree(HOME, ignore_errors=True)

results["total_s"] = round(time.monotonic() - T0)
ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
