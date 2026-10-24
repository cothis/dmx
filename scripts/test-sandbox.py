#!/usr/bin/env python3
"""Drive dmx's sandboxes through `dmx mcp` as an AI client would, on the real VM, in a throwaway
DMX_HOME: policies (no network, all, an allowlist; a read-only host path), exec with caps and
timeouts, checkpoint, rollback, fork, logs with summaries, the TTL enforced by the daemon after
the client went away, errors, and guest memory per sandbox. Needs the internet (Docker Hub, and
example.com for the egress checks). Prints one JSON object and exits non-zero if a check failed.

    python3 -I scripts/test-sandbox.py [path/to/dmx]
"""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"

checks = []
results = {}


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail if isinstance(detail, str) else repr(detail)[:400]})


def daemon_pids():
    out = subprocess.run(["pgrep", "-f", f"{DMX} daemon"], capture_output=True, text=True).stdout
    pids = []
    for pid in out.split():
        env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if f"DMX_HOME={HOME}" in env:
            pids.append(int(pid))
    return pids


def wait_for(predicate, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(step)
    return False


class Client:
    """A minimal MCP client over the server's stdin and stdout (legacy handshake)."""

    def __init__(self, log):
        self.proc = subprocess.Popen([str(DMX), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(HOME / log, "wb"), env=ENV)
        self.replies = {}
        self.cond = threading.Condition()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()
        r = self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                        "clientInfo": {"name": "test-sandbox", "version": "1"}})
        assert r and "result" in r, r
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _read(self):
        for line in self.proc.stdout:
            msg = json.loads(line)
            with self.cond:
                self.replies[json.dumps(msg.get("id"))] = msg
                self.cond.notify_all()

    def send(self, msg):
        self.proc.stdin.write(json.dumps(msg).encode() + b"\n")
        self.proc.stdin.flush()

    def request(self, method, params=None, timeout=180):
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}})
        key = json.dumps(self.next_id)
        with self.cond:
            self.cond.wait_for(lambda: key in self.replies, timeout)
            return self.replies.pop(key, None)

    def call(self, name, arguments=None, timeout=180):
        reply = self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout)
        return reply.get("result") if reply else {"isError": True, "content": [{"text": "no reply"}], "structuredContent": {}}

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def ok(r):
    return r and not r.get("isError") and r.get("structuredContent") is not None


def text(r):
    return (r or {}).get("content", [{}])[0].get("text", "")


def sx(name, argv, **kw):
    """dmx_sandbox_exec, returning (exit_code, stdout, stderr, structured)."""
    r = c.call("dmx_sandbox_exec", {"name": name, "argv": argv, **kw})
    s = r.get("structuredContent") or {}
    return s.get("exit_code"), s.get("stdout", ""), s.get("stderr", ""), r


def timed(fn, *a, **kw):
    t = time.time()
    r = fn(*a, **kw)
    return r, int((time.time() - t) * 1000)


def docker_get(path):
    """GET on the Docker API through $DMX_HOME/docker.sock (HTTP/1.0: the body ends at close)."""
    s = socket.socket(socket.AF_UNIX)
    s.connect(str(HOME / "docker.sock"))
    s.sendall(f"GET {path} HTTP/1.0\r\nHost: d\r\n\r\n".encode())
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    s.close()
    return json.loads(data.split(b"\r\n\r\n", 1)[1])


def sandbox_containers():
    return [n[1:] for c in docker_get("/containers/json?all=1") for n in c["Names"] if n.startswith("/dmx-sandbox-")]


HOME = Path(tempfile.mkdtemp(prefix="dmx-sb-", dir="/tmp"))
ENV = {k: v for k, v in os.environ.items() if not k.startswith("DOCKER_")}
ENV["DMX_HOME"] = str(HOME)
(HOME / "guest").symlink_to(GUEST)
ro = HOME / "ro"
ro.mkdir()
(ro / "hello").write_text("from the mac\n")
c = None
try:
    c = Client("mcp-stderr.log")
    tools = [t["name"] for t in c.request("tools/list")["result"]["tools"]]
    want = {"dmx_sandbox_create", "dmx_sandbox_exec", "dmx_sandbox_list", "dmx_sandbox_rm", "dmx_sandbox_checkpoint",
            "dmx_sandbox_rollback", "dmx_sandbox_fork", "dmx_logs"}
    check("tools_list", want <= set(tools), tools)

    # The first sandbox boots the VM, starts dockerd (unpacking it onto a new data disk) and pulls alpine.
    r, ms = timed(c.call, "dmx_sandbox_create", {"name": "none", "mounts": [{"host": str(ro), "path": "/ro"}]}, timeout=300)
    results["first_create_ms"] = ms
    s = r.get("structuredContent") or {}
    check("create_none", ok(r) and s["state"] == "running" and s["policy"]["network"] == "none"
          and s["policy"]["mounts"][0]["writable"] is False and s["expires_in_s"] > 1700, r)
    status = c.call("dmx_status")["structuredContent"]
    check("sandbox_holds_off_idle_stop", status["containers"] >= 1 and status.get("idle_stop_in_s") is None, status)

    code, out, err, r = sx("none", ["cat", "/ro/hello"])
    check("mount_readable", code == 0 and out == "from the mac\n", r)
    code, out, err, r = sx("none", ["sh", "-c", "echo x > /ro/new"])
    check("mount_read_only", code != 0 and "Read-only" in err and not (ro / "new").exists(), r)
    code, out, err, r = sx("none", ["wget", "-T", "5", "-q", "-O", "/dev/null", "http://example.com"])
    check("egress_none_blocked", code != 0, r)
    code, out, err, r = sx("none", ["ip", "link", "set", "lo", "down"])
    check("no_net_admin", code != 0, r)

    (_, ms) = timed(sx, "none", ["true"])
    results["exec_ms"] = ms
    code, out, err, r = sx("none", ["sh", "-c", "echo in=$(cat) $FOO $PWD; echo err >&2; exit 3"],
                           stdin="hi", env={"FOO": "bar"}, cwd="/tmp")
    check("exec_stdin_env_cwd", code == 3 and out == "in=hi bar /tmp\n" and err == "err\n", r)
    code, out, err, r = sx("none", ["seq", "1", "100000"], max_output_bytes=1000)
    s = r["structuredContent"]
    check("exec_output_capped", s["stdout_bytes"] == 588895 and s["stdout_omitted_bytes"] == 588895 - 1000
          and "bytes omitted" in out and out.startswith("1\n2\n") and out.endswith("100000\n"), s.get("stdout_omitted_bytes"))
    code, out, err, r = sx("none", ["sh", "-c", "sleep 1234 & sleep 1235; echo never"], timeout=2)
    s = r["structuredContent"]
    gone = wait_for(lambda: "sleep 123" not in c.call("dmx_exec", {"argv": ["ps", "-o", "args"]})["structuredContent"]["stdout"], 10)
    check("exec_timeout_kills", s.get("timed_out") is True and r["isError"] is True and s["exit_code"] is None and gone,
          f"timed_out {s.get('timed_out')}, processes gone {gone}")

    # Egress: everything, and an allowlist of one host.
    r, ms = timed(c.call, "dmx_sandbox_create", {"name": "all", "network": "all", "ttl": "10m"})
    results["create_ms"] = ms
    code, out, err, r2 = sx("all", ["wget", "-T", "10", "-q", "-O", "/dev/null", "http://example.com"])
    check("egress_all", ok(r) and code == 0, (r2, text(r)))
    r = c.call("dmx_sandbox_create", {"name": "allow", "network": ["example.com"], "ttl": 600})
    s = r.get("structuredContent") or {}
    check("create_allowlist", ok(r) and s["policy"]["network"] == "allowlist" and s["allowed"], r)
    code, out, err, r = sx("allow", ["wget", "-T", "10", "-q", "-O", "/dev/null", "http://example.com"])
    check("allowlist_allows", code == 0, r)
    code, out, err, r = sx("allow", ["wget", "-T", "10", "-q", "-O", "/dev/null", "http://1.1.1.1"])
    check("allowlist_blocks_other", code != 0 and "refused" in err, r)
    code, out, err, r = sx("allow", ["wget", "-T", "10", "-q", "-O", "/dev/null", "http://host.docker.internal:22999"])
    check("allowlist_blocks_mac", code != 0 and "refused" in err, r)
    code, out, err, r = sx("allow", ["nslookup", "example.org"])
    check("allowlist_dns", code == 0 and "Address" in out, r)
    # A main process of the caller's starts only once the rules are in place.
    r = c.call("dmx_sandbox_create", {"name": "allow-cmd", "network": ["example.com"], "ttl": "5m", "command": [
        "sh", "-c", "wget -T 5 -q -O /dev/null http://1.1.1.1 && echo leaked || echo blocked; sleep 600"]})
    got = wait_for(lambda: c.call("dmx_logs", {"target": "allow-cmd"})["structuredContent"]["stdout"] != "", 15, 0.5)
    out = c.call("dmx_logs", {"target": "allow-cmd"})["structuredContent"]["stdout"]
    check("allowlist_command_starts_fenced", ok(r) and got and out == "blocked\n", (out, text(r)))
    c.call("dmx_sandbox_rm", {"name": "allow-cmd"})

    # Checkpoint, rollback, fork.
    sx("none", ["sh", "-c", "echo v1 > /root/state"])
    r, ms = timed(c.call, "dmx_sandbox_checkpoint", {"name": "none"})
    results["checkpoint_ms"] = ms
    check("checkpoint", ok(r) and r["structuredContent"]["name"] == "c1", r)
    sx("none", ["sh", "-c", "echo v2 > /root/state; head -c 4000000 /dev/urandom > /root/blob"])
    r = c.call("dmx_sandbox_checkpoint", {"name": "none", "checkpoint": "big"})
    results["checkpoint_4mb_added_mb"] = (r.get("structuredContent") or {}).get("added_mb")
    check("checkpoint_named", ok(r) and 3.5 < r["structuredContent"]["added_mb"] < 5, r)
    r = c.call("dmx_sandbox_checkpoint", {"name": "none", "checkpoint": "big"})
    check("checkpoint_exists", r["isError"] and "checkpoint_exists" in text(r), r)
    r, ms = timed(c.call, "dmx_sandbox_rollback", {"name": "none", "checkpoint": "c1"})
    results["rollback_ms"] = ms
    code, out, err, _ = sx("none", ["sh", "-c", "cat /root/state; ls /root"])
    check("rollback", ok(r) and out == "v1\nstate\n" and [x["name"] for x in r["structuredContent"]["checkpoints"]] == ["c1", "big"], (out, r))
    code, out, err, _ = sx("none", ["cat", "/ro/hello"])
    check("rollback_keeps_policy", code == 0 and r["structuredContent"]["policy"]["mounts"][0]["path"] == "/ro", out)
    r, ms = timed(c.call, "dmx_sandbox_fork", {"name": "none", "new_name": "fork-big", "checkpoint": "big"})
    results["fork_checkpoint_ms"] = ms
    code, out, err, _ = sx("fork-big", ["cat", "/root/state"])
    check("fork_from_checkpoint", ok(r) and out == "v2\n", (out, r))
    sx("none", ["sh", "-c", "echo v3 > /root/state"])
    r, ms = timed(c.call, "dmx_sandbox_fork", {"name": "none", "new_name": "fork-now", "ttl": "5m"})
    results["fork_now_ms"] = ms
    sx("fork-now", ["sh", "-c", "echo changed-in-fork > /root/state"])
    _, a, _, _ = sx("none", ["cat", "/root/state"])
    _, b, _, _ = sx("fork-now", ["cat", "/root/state"])
    check("fork_independent", ok(r) and a == "v3\n" and b == "changed-in-fork\n" and r["structuredContent"]["expires_in_s"] <= 300, (a, b))

    # Logs of a sandbox's main process, capped, with a summary.
    script = 'for i in $(seq 1 5000); do echo "line $i"; done; echo "ERROR: disk on fire" >&2; sleep 3600'
    r = c.call("dmx_sandbox_create", {"name": "logs", "command": ["sh", "-c", script], "ttl": "5m"})
    wait_for(lambda: c.call("dmx_logs", {"target": "logs"})["structuredContent"]["summary"]["stderr_lines"] == 1, 15, 0.5)
    r = c.call("dmx_logs", {"target": "logs", "max_output_bytes": 200})
    s = r.get("structuredContent") or {}
    check("logs_capped", ok(r) and s["stdout_bytes"] == 48893 and s["stdout_omitted_bytes"] > 48000
          and "bytes omitted" in s["stdout"] and s["stderr"] == "ERROR: disk on fire\n", s)
    sm = s.get("summary", {})
    check("logs_summary", sm.get("stdout_lines") == 5000 and sm.get("error_lines") == 1
          and sm["errors"][0]["text"] == "ERROR: disk on fire" and sm["errors"][0]["stream"] == "stderr", sm)
    r = c.call("dmx_logs", {"target": "logs", "tail": 2})
    s = r.get("structuredContent") or {}
    check("logs_tail", ok(r) and s["summary"]["stdout_lines"] + s["summary"]["stderr_lines"] == 2, s)
    r = c.call("dmx_logs", {"target": "logs", "since": str(int(time.time()) + 3600)})
    check("logs_since", ok(r) and r["structuredContent"]["stdout_bytes"] == 0, r)
    r = c.call("dmx_logs", {"target": "no-such-thing"})
    check("logs_not_found", r["isError"] and "container_not_found" in text(r), r)

    # Errors carry a code and a hint.
    r = c.call("dmx_sandbox_exec", {"name": "nope", "argv": ["true"]})
    check("not_found", r["isError"] and "sandbox_not_found" in text(r) and "hint:" in text(r), r)
    r = c.call("dmx_sandbox_create", {"network": "all", "cpus": 0.5, "memory": "lots"})
    check("bad_policy", r["isError"] and "bad_sandbox_policy" in text(r), r)
    r = c.call("dmx_sandbox_create", {"mounts": [{"host": "/System/Library"}]})
    check("mount_not_shared", r["isError"] and "mount_not_shared" in text(r), r)
    r = c.call("dmx_sandbox_create", {"name": "none"})
    check("exists", r["isError"] and "sandbox_exists" in text(r), r)
    r = c.call("dmx_sandbox_create", {"name": "Bad Name"})
    check("bad_name", r["isError"] and "bad_name" in text(r), r)

    # Memory: guest memory per idle sandbox (tini + sleep + its shim), measured over 5 more.
    def guest_used():
        return c.call("dmx_status")["structuredContent"]["guest_used_mb"]
    before = guest_used()
    for i in range(5):
        c.call("dmx_sandbox_create", {"name": f"mem{i}", "ttl": "5m"})
    time.sleep(3)
    after = guest_used()
    results["guest_mb_per_sandbox"] = round((after - before) / 5, 1)
    results["host_footprint_mb_with_sandboxes"] = c.call("dmx_status")["structuredContent"]["host_footprint_mb"]
    for i in range(5):
        c.call("dmx_sandbox_rm", {"name": f"mem{i}"})

    # Remove, with checkpoints; the fork that runs from one of them keeps it.
    r, ms = timed(c.call, "dmx_sandbox_rm", {"name": "none"})
    results["rm_ms"] = ms
    s = r.get("structuredContent") or {}
    names = sandbox_containers()
    images = [t for i in docker_get("/images/json") for t in (i.get("RepoTags") or [])]
    check("rm", ok(r) and s["container"] and "dmx-sandbox-none" not in names and not any(t.startswith("dmx-sandbox/none:") for t in images)
          and "dmx-sandbox/fork-big:forked" in images, (s, images))
    code, out, err, _ = sx("fork-big", ["cat", "/root/state"])
    check("fork_survives_rm", code == 0 and out == "v2\n", out)
    r = c.call("dmx_sandbox_rm", {"name": "none"})
    check("rm_again", r["isError"] and "sandbox_not_found" in text(r), r)
    listed = [x["name"] for x in c.call("dmx_sandbox_list")["structuredContent"]["sandboxes"]]
    check("list", set(listed) == {"all", "allow", "fork-big", "fork-now", "logs"}, listed)

    # The TTL: a second client creates a sandbox and goes away; the daemon removes it on time.
    c2 = Client("mcp2-stderr.log")
    r = c2.call("dmx_sandbox_create", {"name": "ttl", "ttl": 10})
    created = time.time()
    c2.close()
    removed = wait_for(lambda: "dmx-sandbox-ttl" not in sandbox_containers(), 40, 1)
    results["ttl_removed_after_s"] = round(time.time() - created, 1)
    log = (HOME / "logs" / "daemon.log").read_text(errors="replace")
    check("ttl_expiry_without_client", ok(r) and removed and "sandbox: removed ttl" in log and results["ttl_removed_after_s"] < 25,
          results["ttl_removed_after_s"])

    for name in ["all", "allow", "fork-big", "fork-now", "logs"]:
        c.call("dmx_sandbox_rm", {"name": name})
    status = c.call("dmx_status")["structuredContent"]
    check("idle_stop_after_rm", wait_for(lambda: c.call("dmx_status")["structuredContent"].get("idle_stop_in_s") is not None, 10), status)
    c.close()
finally:
    try:
        c and c.proc.kill()
    except Exception:
        pass
    for pid in daemon_pids():
        os.kill(pid, signal.SIGTERM)
    wait_for(lambda: not daemon_pids(), 15)
    if sys.exc_info()[0] or not all(x["ok"] for x in checks):
        for name in ["mcp-stderr.log", "logs/daemon.log"]:
            if (HOME / name).exists():
                sys.stderr.write(f"--- {name}\n" + (HOME / name).read_text(errors="replace")[-3000:])
    shutil.rmtree(HOME, ignore_errors=True)

ok_all = all(x["ok"] for x in checks)
print(json.dumps({"ok": ok_all, **results, "checks": checks}, indent=2))
sys.exit(0 if ok_all else 1)
