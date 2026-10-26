#!/usr/bin/env python3
"""Exercise the dmx daemon end to end on the real VM, in a throwaway DMX_HOME.

The guest files come from $DMX_HOME/guest (default ~/.dmx/guest, symlinked), so run
`make guest` first. Starts no
launchd job; `dmx install` is tested by hand (it writes ~/Library/LaunchAgents). Prints one
JSON object and exits non-zero if any check failed.

    python3 -I scripts/test-daemon.py [path/to/dmx]
"""

import hashlib
import http.server
import json
import os
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
# The guest of the DMX_HOME this script was started with (default ~/.dmx).
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"

checks = []


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})


def dmx(*args, stdin=None, timeout=300):
    """Runs dmx; a timeout comes back as returncode -1 so the check fails instead of the script.
    Generous because a loaded host (other VMs) can slow a 500 MB stream past a minute."""
    try:
        return subprocess.run([str(DMX), *args], input=stdin, capture_output=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired as e:
        return subprocess.CompletedProcess(e.cmd, -1, e.stdout or b"", (e.stderr or b"") + b"timed out")


def status():
    return json.loads(dmx("status", "--json").stdout)


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
        if predicate():
            return True
        time.sleep(0.1)
    return False


def through_pty(argv, script):
    """Runs argv on a pty, sending each (delay, bytes) of script; returns output and exit code."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(argv[0], argv, ENV)
    out = b""

    def drain(seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    return

    for delay, data in script:
        drain(delay)
        try:
            os.write(fd, data)
        except OSError:
            break
    drain(2)
    _, code = os.waitpid(pid, 0)
    os.close(fd)
    return out.decode(errors="replace"), os.waitstatus_to_exitcode(code)


def daemon_call(method, params):
    """One request on the control socket, without the CLI (for methods it has no command for)."""
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(str(HOME / "dmx.sock"))
        body = json.dumps({"id": 1, "method": method, "params": params}).encode()
        s.sendall(struct.pack(">I", len(body) + 1) + b"\0" + body)
        data = b""
        while len(data) < 4 or len(data) < 4 + struct.unpack(">I", data[:4])[0]:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        return json.loads(data[5:])


def memory_checks(results):
    """Idle trim, hotplug and balloon under simulated pressure, and capacity returning on demand."""
    def memory():
        s = status()
        return s.get("host_footprint_mb") or 0, s.get("memory") or {}

    # 512 MB of clean page cache: an empty zram block device read through, held open so the
    # kernel keeps its cache after dd exits. Reading zeros from zram costs zram nothing.
    fill = ("n=$(cat /sys/class/zram-control/hot_add); echo 1G >/sys/block/zram$n/disksize; "
            "setsid sleep 1000 </dev/zram$n >/dev/null 2>&1 & dd if=/dev/zram$n of=/dev/null bs=1M count=512 2>/dev/null")
    daemon_call("simulate_pressure", {"level": "normal"})
    time.sleep(3)
    idle, _ = memory()
    dmx("exec", "--", "sh", "-c", fill)
    full, m = memory()
    check("memory_cache_filled", m.get("guest_cache_mb", 0) >= 500 and full >= idle + 400, f"footprint {idle} -> {full} MB, {m}")

    # Warning: the guest trims at once.
    daemon_call("simulate_pressure", {"level": "warning"})
    started = time.time()
    back = wait_for(lambda: memory()[0] < idle + 64, 15)
    results["memory_warning_trim_s"] = round(time.time() - started, 1)
    fp, m = memory()
    check("memory_trim_on_warning", back and (m.get("last_trim") or {}).get("reason") == "host pressure warning",
          f"footprint {fp} MB, {m}")

    # Idle: under pressure the guest trims after 5 s without an exec (30 s without pressure).
    dmx("exec", "--", "sh", "-c", fill)
    started = time.time()
    back = wait_for(lambda: memory()[0] < idle + 64, 20)
    results["memory_idle_trim_s"] = round(time.time() - started, 1)
    fp, m = memory()
    check("memory_idle_trim", back and (m.get("last_trim") or {}).get("reason") == "idle", f"footprint {fp} MB, {m}")
    # The idle sweep (reporting from 16 KB blocks, empty slabs freed) comes with the idle trim.
    swept = wait_for(lambda: (memory()[1].get("sweeps") or 0) >= 1, 10)
    check("memory_idle_sweep", swept, str(memory()[1]))

    # Grow well beyond boot RAM, then free it. Critical pressure must unplug immediately,
    # rather than wait for normal hysteresis or pin it in the balloon.
    r = dmx("exec", "--", "sh", "-c", "mkdir -p /mnt/pressure; mount -t tmpfs -o size=3G tmpfs /mnt/pressure; "
            "dd if=/dev/zero of=/mnt/pressure/data bs=1M count=2048 2>/dev/null")
    fp, m = memory()
    grown = m.get("plug") or {}
    check("memory_hotplug_growth", r.returncode == 0 and grown.get("plugged_mb", 0) >= 2048,
          f"footprint {fp} MB, {grown}, {r.stderr!r}")
    daemon_call("simulate_pressure", {"level": "normal"})
    dmx("exec", "--", "rm", "/mnt/pressure/data")
    started = time.time()
    normal_back = wait_for(lambda: (memory()[1].get("plug") or {}).get("plugged_mb", 1 << 20) <= 512
                           and memory()[0] < idle + 64, 10)
    fp, m = memory()
    results["memory_normal_unplug_s"] = round(time.time() - started, 1)
    results["memory_normal_footprint_mb"] = fp
    check("memory_normal_unplug", normal_back, f"footprint {idle} -> {fp} MB, {m}")

    # Grow again so the immediate pressure path is checked independently of normal unplug.
    r = dmx("exec", "--", "sh", "-c", "dd if=/dev/zero of=/mnt/pressure/data bs=1M count=2048 2>/dev/null")
    if r.returncode != 0:
        check("memory_pressure_fixture", False, repr(r.stderr))
    _, m = memory()
    grown = m.get("plug") or {}
    results["memory_grown_plug"] = grown
    dmx("exec", "--", "rm", "/mnt/pressure/data")
    daemon_call("simulate_pressure", {"level": "critical"})
    started = time.time()
    unplugged = wait_for(lambda: (memory()[1].get("plug") or {}).get("plugged_mb", 1 << 20) <= 256, 15)
    results["memory_critical_unplug_s"] = round(time.time() - started, 1)
    fp, m = memory()
    plug = m.get("plug") or {}
    check("memory_unplug_on_critical", unplugged and plug.get("unplugs", 0) > grown.get("unplugs", 0), str(m))
    # The balloon still squeezes the boot RAM that virtio-mem cannot remove.
    def squeezed():
        fp, m = memory()
        return (m.get("balloon_mb") or 0) >= 256 and fp < idle + 64

    # Reaching 256 MB is only partial balloon progress; free-page reporting may still be
    # finishing. Wait for both requirements within the same deadline, not an intermediate frame.
    inflated = wait_for(squeezed, 15)
    fp, m = memory()
    results["memory_critical_footprint_mb"] = fp
    check("memory_balloon_on_critical", inflated and fp < idle + 64, f"footprint {fp} MB, {m}")

    # The reduced headroom is not a hard memory cap: active allocations still plug more RAM.
    # Random bytes stop zram compression from hiding the need for more physical memory.
    r = dmx("exec", "--", "sh", "-c", "dd if=/dev/urandom of=/mnt/pressure/data bs=1M count=1536 2>/dev/null && wc -c </mnt/pressure/data")
    fp, m = memory()
    check("memory_growth_under_critical", r.returncode == 0 and r.stdout.strip() == b"1610612736"
          and (m.get("plug") or {}).get("plugged_mb", 0) > plug.get("plugged_mb", 0), f"{r.stdout!r} {r.stderr!r} {m}")
    dmx("exec", "--", "rm", "/mnt/pressure/data")
    daemon_call("simulate_pressure", {"level": "warning"})
    loosened = wait_for(lambda: memory()[1].get("balloon_mb") == 0
                        and (memory()[1].get("plug") or {}).get("requested_mb", 0) >= 128, 15)
    check("memory_warning_headroom_restored", loosened, str(memory()[1]))
    daemon_call("simulate_pressure", {"level": "normal"})
    deflated = wait_for(lambda: memory()[1].get("balloon_mb") == 0, 15)
    check("memory_balloon_deflated", deflated, str(memory()[1]))
    dmx("exec", "--", "umount", "/mnt/pressure")
    daemon_call("simulate_pressure", {"level": None})


def fixed_memory_checks():
    """A ceiling equal to boot RAM has no hotplug device: pressure must still use the balloon."""
    dmx("config", "set", "memory", "1G")
    dmx("stop")
    dmx("start")
    daemon_call("simulate_pressure", {"level": "normal"})
    check("memory_without_hotplug", (status().get("memory") or {}).get("plug") is None, str(status()))
    daemon_call("simulate_pressure", {"level": "critical"})
    inflated = wait_for(lambda: (status().get("memory") or {}).get("balloon_mb", 0) >= 256, 15)
    r = dmx("exec", "--", "echo", "alive")
    check("memory_balloon_without_hotplug", inflated and r.stdout == b"alive\n", str(status()))
    daemon_call("simulate_pressure", {"level": "normal"})
    deflated = wait_for(lambda: (status().get("memory") or {}).get("balloon_mb") == 0, 15)
    check("memory_normal_without_hotplug", deflated, str(status()))
    daemon_call("simulate_pressure", {"level": None})


# Guest servers for the port forward check. The guest's busybox has no httpd; `nc -lk -e` serves
# one connection per child, but with a listen backlog of 1, so connect one client at a time.
GUEST_SERVERS = b"""
mkdir -p /www
cat > /www/http <<'EOF'
#!/bin/sh
read -r req
while read -r line; do [ "${line%$(printf '\\r')}" = "" ] && break; done
path=${req#GET }; path=${path%% *}
case "$path" in
/zero/*) printf 'HTTP/1.0 200 OK\\r\\n\\r\\n'; head -c "${path#/zero/}" /dev/zero ;;
*) printf 'HTTP/1.0 200 OK\\r\\n\\r\\nhello from the guest\\n' ;;
esac
EOF
chmod +x /www/http
setsid nc -lk -p 80 -e /www/http </dev/null >/dev/null 2>&1 &
setsid nc -lk -p 81 -e cat </dev/null >/dev/null 2>&1 &
setsid nc -lk -p 82 -e wc -c </dev/null >/dev/null 2>&1 &
sleep 0.3
"""


def http_get(port, path, timeout=60, host="127.0.0.1"):
    with socket.create_connection((host, port), timeout=timeout) as c:
        c.sendall(f"GET {path} HTTP/1.0\r\n\r\n".encode())
        data = bytearray()
        while chunk := c.recv(1 << 20):
            data += chunk
    return bytes(data.split(b"\r\n\r\n", 1)[-1])


def reads_eof(c):
    try:
        return c.recv(100) == b""
    except OSError:
        return False


def portfwd(results):
    """`dmx port`: a forward to guest servers, many connections at once, closes both ways,
    half close, errors, and a forward that boots the stopped VM and survives a daemon restart."""
    def add(spec):
        return json.loads(dmx("port", "add", spec, "--json").stdout)

    added = [add(f"1878{p}:8{p}") for p in range(3)]
    dmx("exec", "--", "sh", stdin=GUEST_SERVERS)
    body = http_get(18780, "/")
    check("portfwd_http", all(a.get("listening") for a in added) and body == b"hello from the guest\n", f"{body!r} {added[0]}")
    # A forward on 127.0.0.1 listens on ::1 too: `localhost` on the Mac tries ::1 first.
    body = http_get(18780, "/", host="::1")
    check("portfwd_ipv6_loopback", body == b"hello from the guest\n", repr(body))

    # The memory checks just before free gigabytes that take a few seconds to come back; without
    # this wait the footprint after the streams measures them, not the forward.
    wait_for(lambda: status().get("host_footprint_mb", 1 << 20) < results.get("idle_footprint_mb", 0) + 64, 15)
    results["portfwd_footprint_before_streams_mb"] = status().get("host_footprint_mb")
    started = time.time()
    n = len(http_get(18780, "/zero/200000000"))
    results["portfwd_guest_to_host_mb_per_s"] = int(200 / (time.time() - started))
    started = time.time()
    with socket.create_connection(("127.0.0.1", 18782)) as c:
        for _ in range(200):
            c.sendall(b"x" * (1 << 20))
        c.shutdown(socket.SHUT_WR)  # half close: the guest still answers
        reply = c.recv(100)
    results["portfwd_host_to_guest_mb_per_s"] = int(200 / (time.time() - started))
    results["portfwd_footprint_after_streams_mb"] = status().get("host_footprint_mb")
    check("portfwd_streams", n == 200000000 and reply.strip() == str(200 << 20).encode(), f"{n} {reply!r}")

    # 30 connections open at once, each echoed by its own `cat` in the guest.
    conns = []
    for i in range(30):
        c = socket.create_connection(("127.0.0.1", 18781), timeout=10)
        c.sendall(b"hi %d\n" % i)
        conns.append((c, c.recv(100)))
    echoed = all(r == b"hi %d\n" % i for i, (_, r) in enumerate(conns))
    cats = dmx("exec", "--", "pgrep", "-x", "cat").stdout.split()
    # The guest side closes: every client reads end of stream.
    dmx("exec", "--", "pkill", "-x", "cat")
    eof = all(reads_eof(c) for c, _ in conns)
    for c, _ in conns:
        c.close()
    check("portfwd_concurrent_guest_close", echoed and len(cats) == 30 and eof, f"echoed {echoed}, {len(cats)} cats, eof {eof}")

    # The host side closes: the guest's `cat` reads end of stream and exits.
    c = socket.create_connection(("127.0.0.1", 18781), timeout=10)
    c.sendall(b"x\n")
    c.recv(10)
    c.close()
    gone = wait_for(lambda: not dmx("exec", "--", "pgrep", "-x", "cat").stdout, 5)
    idle = wait_for(lambda: all(f["connections"] == 0 for f in json.loads(dmx("port", "ls", "--json").stdout)["forwards"]), 5)
    check("portfwd_host_close", gone and idle, f"guest cat gone {gone}, no open connections {idle}")

    taken = socket.socket()
    taken.bind(("127.0.0.1", 18789))
    taken.listen()
    codes = [json.loads(dmx("port", *args, "--json").stdout).get("error", {}).get("code")
             for args in (("add", "18780:80"), ("add", "18789:80"), ("rm", "18788"), ("add", "1:2:3:4"))]
    taken.close()
    check("portfwd_errors", codes == ["port_forwarded", "port_in_use", "port_not_forwarded", "bad_port_spec"], str(codes))

    # Forwards keep the daemon (not the VM) up; a connection boots the VM. A new daemon listens again.
    pid = daemon_pids()
    dmx("stop")
    time.sleep(1)
    stopped = status()["state"]
    with socket.create_connection(("127.0.0.1", 18780), timeout=30) as c:
        c.sendall(b"GET / HTTP/1.0\r\n\r\n")
        try:
            c.recv(100)  # nothing listens in the new VM yet, so it closes
        except OSError:
            pass
    booted = status()["state"]
    os.kill(pid[0], signal.SIGTERM)
    wait_for(lambda: not daemon_pids(), 15)
    listening = [f["listening"] for f in json.loads(dmx("port", "ls", "--json").stdout)["forwards"]]
    check("portfwd_boot_and_restart", stopped == "stopped" and daemon_pids() and booted == "running" and listening == [True] * 3,
          f"after stop {stopped}, after connect {booted}, after restart {listening}")
    for p in range(3):
        dmx("port", "rm", f"1878{p}")


# A short path: Unix socket paths are limited to 104 bytes.
HOME = Path(tempfile.mkdtemp(prefix="dmx-test-", dir="/tmp"))
ENV = {**os.environ, "DMX_HOME": str(HOME)}
(HOME / "guest").symlink_to(GUEST)
results = {}
try:
    s = status()
    check("not_running", s["state"] == "not_running" and not daemon_pids(), s["state"])

    # Share a throwaway directory instead of the default (the home directory).
    SHARE = HOME / "share"
    SHARE.mkdir()
    (SHARE / "from-host").write_text("host\n")
    (SHARE / "esc").symlink_to(HOME / "config.json")
    r = dmx("config", "set", "shares", str(SHARE))
    check("config_shares", r.returncode == 0, repr(r.stderr))

    started = time.time()
    r = dmx("exec", "--", "uname", "-r")
    results["cold_exec_ms"] = int((time.time() - started) * 1000)
    check("cold_exec", r.returncode == 0 and r.stdout.strip(), f"{r.stdout!r} rc {r.returncode}")

    s = status()
    results["idle_footprint_mb"] = s.get("host_footprint_mb")
    results["guest_used_mb"] = s.get("guest_used_mb")
    check("running", s["state"] == "running" and s["launchd"] is False, s["state"])

    started = time.time()
    r = dmx("exec", "--", "true")
    results["warm_exec_ms"] = int((time.time() - started) * 1000)

    r = dmx("exec", "--", "sh", "-c", "echo out; echo err >&2; exit 7")
    check("exit_and_streams", r.returncode == 7 and r.stdout == b"out\n" and r.stderr == b"err\n", repr(r))

    r = dmx("exec", "-e", "A=b", "-w", "/tmp", "--", "sh", "-c", 'echo "$A $(pwd)"')
    check("env_and_cwd", r.stdout == b"b /tmp\n", repr(r.stdout))

    data = os.urandom(64 << 20)
    r = dmx("exec", "--", "md5sum", stdin=data)
    check("stdin_64mb", r.stdout.split()[:1] == [hashlib.md5(data).hexdigest().encode()], repr(r.stdout[:40]))

    started = time.time()
    r = dmx("exec", "--", "head", "-c", "500000000", "/dev/zero")
    seconds = time.time() - started
    results["stdout_500mb_mb_per_s"] = int(500 / seconds)
    check("stdout_500mb", len(r.stdout) == 500000000, str(len(r.stdout)))
    results["footprint_after_streams_mb"] = status().get("host_footprint_mb")

    # Network: 64 MB over HTTP from a server on the host's loopback (192.168.127.254 in the guest).
    body = os.urandom(64 << 20)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    started = time.time()
    r = dmx("exec", "--", "sh", "-c", f"wget -q -O - http://192.168.127.254:{server.server_address[1]}/ | md5sum")
    results["net_64mb_mb_per_s"] = int(64 / (time.time() - started))
    server.shutdown()
    check("net_http_64mb", r.stdout.split()[:1] == [hashlib.md5(body).hexdigest().encode()], repr(r.stdout[:40] + r.stderr[:80]))
    results["footprint_after_net_mb"] = status().get("host_footprint_mb")

    # DNS goes through macOS's resolver: the Mac's own .local name is known only to multicast DNS
    # (no unicast server has it). The guest gets the Mac's own IPv4 answer, a loopback answer as
    # the gateway's host address. Which macOS gives depends on the Mac's network (loopback with no
    # LAN, the LAN address on one).
    local = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True, text=True).stdout.strip()
    answer = subprocess.run(["dscacheutil", "-q", "host", "-a", "name", f"{local}.local"], capture_output=True, text=True).stdout
    mac = {line.split()[1] for line in answer.splitlines() if line.startswith("ip_address:")}
    mac6 = {line.split()[1] for line in answer.splitlines() if line.startswith("ipv6_address:")}
    want = {"192.168.127.254" if a.startswith("127.") else a for a in mac}
    # The Mac's loopback is the gateway's host address in both families. Link-local answers and
    # AAAA the Mac has no route for are left out of the guest's answer (HostDNS.routable), so ::1
    # is the only IPv6 address expected back.
    if "::1" in mac6:
        want.add("fd64:646d:7800::254")
    r = dmx("exec", "--", "nslookup", f"{local}.local", "192.168.127.1")
    # Addresses after the first "answer:" (the lines before it name the server).
    got = {line.split()[1].decode() for line in r.stdout.partition(b"answer:")[2].splitlines() if line.startswith(b"Address:")}
    check("dns_host_resolver", r.returncode == 0 and bool(want) and got == want, f"mac {sorted(mac)}, guest {sorted(got)}")
    # IPv6: DNS from the gateway's IPv6 address, the Mac's names as its IPv6 address, and UDP to
    # the Mac's ::1 (UDP over IPv6 must carry a checksum).
    r = dmx("exec", "--", "nslookup", "-type=AAAA", "host.docker.internal", "fd64:646d:7800::1")
    check("dns_ipv6", b"Address: fd64:646d:7800::254" in r.stdout, repr(r.stdout[-200:] + r.stderr[-200:]))
    echo = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    echo.bind(("::1", 0))

    def reverse():
        data, peer = echo.recvfrom(65536)
        echo.sendto(data[::-1], peer)

    threading.Thread(target=reverse, daemon=True).start()
    r = dmx("exec", "--", "sh", "-c", f"printf hello | nc -u -w2 fd64:646d:7800::254 {echo.getsockname()[1]}")
    echo.close()
    check("udp_ipv6", r.stdout == b"olleh", repr(r.stdout + r.stderr))
    # ICMP errors: a closed UDP port on the Mac comes back as port unreachable (counted by the
    # guest's ICMP and ICMPv6 stacks; busybox nc does not report it), and a TCP connect to an
    # address that leads nowhere fails with "host unreachable" rather than "connection refused".
    r = dmx("exec", "--", "sh", "-c",
            "u() { grep -A1 '^Icmp: ' /proc/net/snmp | awk 'NR==2{print $5}'; awk '/Icmp6InDestUnreachs/{print $2}' /proc/net/snmp6; }; "
            "a=$(u); echo x | nc -u -w1 192.168.127.254 9; echo x | nc -u -w1 fd64:646d:7800::254 9; sleep 0.5; echo $a $(u); "
            "wget -T 5 -q -O /dev/null http://240.0.0.1/")
    counts = [int(x) for x in r.stdout.split()] if len(r.stdout.split()) == 4 else []
    check("icmp_errors", bool(counts) and counts[2:] == [counts[0] + 1, counts[1] + 1], repr(r.stdout + r.stderr))
    check("tcp_unreachable", b"Host is unreachable" in r.stderr, repr(r.stderr))
    r = dmx("exec", "--", "nslookup", "www.github.com", "192.168.127.1")
    check("dns_cname_chain", b"canonical name = github.com" in r.stdout and b"Name:\tgithub.com\nAddress: " in r.stdout, repr(r.stdout[-300:]))

    r = dmx("exec", "--", "nosuch")
    check("missing_binary", r.returncode == 1 and b"nosuch" in r.stderr, repr(r.stderr))

    # The share is at the same path in the guest, read-write, owned by root there; host changes
    # show on the next open; nothing outside it is reachable.
    G = json.loads(dmx("config", "get", "shares", "--json").stdout)["settings"]["shares"]
    r = dmx("exec", "--", "sh", "-c", f"cat {G}/from-host && echo guest > {G}/from-guest && stat -c %u {G}/from-host")
    check("share_read_write", r.stdout == b"host\n0\n" and (SHARE / "from-guest").read_text() == "guest\n", repr(r))
    (SHARE / "from-host").write_text("changed on the host\n")
    r = dmx("exec", "--", "cat", f"{G}/from-host")
    check("share_host_change", r.stdout == b"changed on the host\n", repr(r.stdout))
    r = dmx("exec", "--", "sh", "-c", f"ls -a {G}/..; cat {G}/esc {G}/../config.json 2>&1")
    check("share_contained", b"shares" not in r.stdout and b"config.json\n" not in r.stdout, repr(r.stdout))

    # SIGTERM to dmx is passed to the guest process, which decides how to exit.
    p = subprocess.Popen([str(DMX), "exec", "--", "sh", "-c", 'trap "echo term; exit 5" TERM; while :; do sleep 0.1; done'],
                         stdout=subprocess.PIPE, env=ENV)
    time.sleep(1)
    p.send_signal(signal.SIGTERM)
    out, _ = p.communicate(timeout=10)
    check("signal_forwarded", p.returncode == 5 and out == b"term\n", f"rc {p.returncode} {out!r}")

    # A client that dies takes its guest process with it.
    p = subprocess.Popen([str(DMX), "exec", "--", "sleep", "1234"], env=ENV)
    time.sleep(1)
    p.kill()
    p.wait()
    gone = wait_for(lambda: b"sleep 1234" not in dmx("exec", "--", "ps", "-o", "args").stdout, 5)
    check("client_killed", gone, "guest process ended" if gone else "guest process still running")

    out, code = through_pty([str(DMX), "shell"], [
        (1.0, b"echo $((6*7))\n"),
        (0.3, b"sleep 100\n"),
        (0.5, b"\x03"),
        (0.5, b"echo after-$((1+1))\n"),
        (0.3, b"exit 3\n"),
    ])
    check("shell_tty", code == 3 and "42" in out and "^C" in out and "after-2" in out, f"rc {code} {out[-200:]!r}")

    # A stuck agent (paused with SIGSTOP from inside the guest, as a kernel oops once left it):
    # status still answers, the control connection is replaced after a minute, and once the agent
    # runs again everything works.
    dmx("exec", "--", "sh", "-c", "pid=$(pidof dmx-agent); setsid sh -c \"sleep 1; kill -STOP $pid; sleep 75; kill -CONT $pid\" "
        "</dev/null >/dev/null 2>&1 &")
    time.sleep(3)
    slowest = 0
    for _ in range(4):
        started = time.monotonic()
        stuck = status()
        slowest = max(slowest, time.monotonic() - started)
        time.sleep(15)
    def runs():
        try:
            return dmx("exec", "--", "true", timeout=30).returncode == 0
        except subprocess.TimeoutExpired:
            return False
    resumed = wait_for(runs, 90)
    log = (HOME / "logs" / "daemon.log").read_text()
    results["stuck_agent_status_max_s"] = round(slowest, 2)
    check("stuck_agent", slowest < 5 and stuck.get("state") == "running" and "opening another" in log and resumed
          and status().get("guest_used_mb"), f"status {slowest:.1f} s, reconnect logged {'opening another' in log}, resumed {resumed}")

    # Memory controller (MemoryController.swift), with the host's pressure level simulated.
    memory_checks(results)
    portfwd(results)

    # Concurrent cold starts end with one daemon.
    dmx("stop")
    pid = daemon_pids()
    wait_for(lambda: not daemon_pids(), 15)
    procs = [subprocess.Popen([str(DMX), "exec", "--", "echo", str(i)], stdout=subprocess.PIPE, env=ENV) for i in range(8)]
    outs = [p.communicate(timeout=60)[0] for p in procs]
    check("concurrent_cold_start", all(o == f"{i}\n".encode() for i, o in enumerate(outs)) and len(daemon_pids()) == 1,
          f"{len(daemon_pids())} daemons")

    # Stop then start again in the same daemon process. The data disk keeps what was written.
    r = dmx("exec", "--", "sh", "-c", "grep ' /var/lib ' /proc/mounts; echo kept > /var/lib/marker")
    check("disk_mounted", r.stdout.startswith(b"/dev/vda /var/lib ext4 "), repr(r.stdout))
    pid = daemon_pids()
    s = json.loads(dmx("stop", "--json").stdout)
    results["footprint_stopped_mb"] = s.get("host_footprint_mb")
    results["disk"] = s.get("disk")
    r = dmx("exec", "--", "cat", "/var/lib/marker")
    check("restart_in_process", r.returncode == 0 and daemon_pids() == pid and s["state"] == "stopped", f"{s['state']} {pid}")
    check("disk_persists", r.stdout == b"kept\n" and (s.get("disk") or {}).get("size_mb") == 65536, f"{r.stdout!r} {s.get('disk')}")

    # Boot-time e2fsck: an error ext4 recorded forces a check; a superblock e2fsck -p will not
    # touch (a bad checksum) is repaired by e2fsck -fy from a backup; files survive both.
    dmx("exec", "--", "sh", "-c", "echo 1 > /sys/fs/ext4/vda/trigger_fs_error")
    dmx("stop")
    r = dmx("exec", "--", "sh", "-c", "cat /var/lib/dmx/log/fsck.log; cat /sys/fs/ext4/vda/errors_count")
    check("fsck_forced", b"check forced" in r.stdout and r.stdout.endswith(b"\n0\n"), repr(r.stdout[-300:]))
    dmx("stop")
    with open(HOME / "data.img", "r+b") as image:
        image.seek(1024 + 12)  # s_free_blocks_count_lo; the superblock checksum no longer matches
        image.write((12345).to_bytes(4, "little"))
    started = time.monotonic()
    r = dmx("exec", "--", "sh", "-c", "cat /var/lib/marker; tail -3 /var/lib/dmx/log/fsck.log")
    results["fsck_repair_boot_s"] = round(time.monotonic() - started, 2)
    console = (HOME / "logs" / "console.log").read_text(errors="replace")
    check("fsck_repaired", r.stdout.startswith(b"kept\n") and b"FILE SYSTEM WAS MODIFIED" in r.stdout and "running e2fsck -fy" in console,
          f"{r.stdout[-300:]!r}")

    # A raised disk_size grows the disk (host file, then ext4 online) at the next boot; a smaller
    # one leaves it alone.
    dmx("stop")
    dmx("config", "set", "disk_size", "80G")
    r = dmx("exec", "--", "sh", "-c", "cat /var/lib/marker; df -k /var/lib | tail -1")
    grown = (status().get("disk") or {}).get("size_mb")
    fields = r.stdout.split()
    check("disk_grows", r.stdout.startswith(b"kept\n") and grown == 81920 and len(fields) > 2 and int(fields[2]) > 75 << 20,
          f"{r.stdout!r} {grown}")
    dmx("stop")
    dmx("config", "set", "disk_size", "16G")
    dmx("exec", "--", "true")
    check("disk_never_shrinks", (status().get("disk") or {}).get("size_mb") == 81920, str(status().get("disk")))
    dmx("config", "unset", "disk_size")

    fixed_memory_checks()

    # `dmx update` against the real release page: what it would install, the guard that keeps it
    # from overwriting a build from source, and a copy of this binary actually updated to the
    # published release (0.2.2 here, so the swap is visible in --version). The notice a command
    # prints when the daemon answering is another version is checked with the running daemon.
    r = dmx("update", "--check", "--json")
    plan = json.loads(r.stdout) if r.returncode == 0 else {}
    results["update_check"] = plan
    check("update_check", r.returncode == 0 and plan.get("target", "").count(".") == 2 and
          plan.get("url", "").endswith(f"dmx-{plan.get('target')}-darwin-arm64.tar.gz"), repr(r.stdout[:200]))
    r = dmx("update", "--version", "0.2.2", "--json")
    refused = json.loads(r.stdout) if r.stdout.startswith(b"{") else {}
    check("update_refuses_source_build", r.returncode != 0 and
          (refused.get("error") or {}).get("code") == "update_source_build", repr(r.stdout[:200]))

    copied = HOME / "bin"
    copied.mkdir(parents=True, exist_ok=True)
    shutil.copy2(DMX, copied / "dmx")
    r = subprocess.run([str(copied / "dmx"), "update", "--version", "0.2.2", "--json"],
                       capture_output=True, timeout=600, env=ENV)
    done = json.loads(r.stdout) if r.stdout.startswith(b"{") else {}
    installed = subprocess.run([str(copied / "dmx"), "--version"], capture_output=True, timeout=60, env=ENV).stdout.strip()
    # The signature check compares the download's Developer ID team with this binary's. A build
    # from source is ad-hoc signed, so here it reports that it skipped rather than claiming a match.
    check("update_installs", r.returncode == 0 and done.get("updated") is True and installed == b"0.2.2" and
          (done.get("daemon") or {}).get("handover") == "stop_to_switch" and
          str(done.get("signature", "")).startswith("skipped"), f"{r.stdout[:200]!r} now {installed!r}")
    # The notice needs a daemon of another version, so the 0.2.2 copy serves one in its own home.
    other = Path(tempfile.mkdtemp(prefix="dmx-test-old-", dir="/tmp"))
    other_env = {**os.environ, "DMX_HOME": str(other)}
    (other / "guest").symlink_to(GUEST)
    dmx("stop")
    subprocess.run([str(copied / "dmx"), "start", "--json"], capture_output=True, timeout=300, env=other_env)
    r = subprocess.run([str(DMX), "status"], capture_output=True, timeout=120, env=other_env)
    check("update_notices_old_daemon", b"the daemon answering is 0.2.2" in r.stderr and b"dmx stop" in r.stderr,
          repr(r.stderr[:200]))
    subprocess.run([str(copied / "dmx"), "stop"], capture_output=True, timeout=120, env=other_env)
    wait_for(lambda: not subprocess.run(["pgrep", "-f", f"{copied / 'dmx'} daemon"], capture_output=True).stdout, 30)
    shutil.rmtree(other, ignore_errors=True)
    shutil.rmtree(copied, ignore_errors=True)
    dmx("exec", "--", "true")

    # Idle: the VM stops after idle_timeout, then the daemon exits after 10 s.
    dmx("config", "set", "idle_timeout", "2s")
    dmx("stop")
    dmx("start")
    stopped = wait_for(lambda: status()["state"] == "stopped", 10)
    exited = wait_for(lambda: not daemon_pids(), 15)
    check("idle_stop", stopped and exited and not (HOME / "dmx.sock").exists(), f"vm stopped {stopped}, daemon exited {exited}")
finally:
    for pid in daemon_pids():
        os.kill(pid, signal.SIGTERM)
    wait_for(lambda: not daemon_pids(), 15)
    shutil.rmtree(HOME, ignore_errors=True)

ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
