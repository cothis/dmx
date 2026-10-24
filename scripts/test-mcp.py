#!/usr/bin/env python3
"""Drive `dmx mcp` over pipes as an MCP client would, on the real VM, in a throwaway DMX_HOME.

The guest files come from $DMX_HOME/guest (default ~/.dmx/guest, symlinked). Covers the legacy
handshake (initialize) and the stateless 2026-07-28 revision (server/discover, _meta), every
tool, output limits, timeouts, cancellation and errors. Prints one JSON object and exits
non-zero if any check failed.

    python3 -I scripts/test-mcp.py [path/to/dmx]
"""

import json
import os
import queue
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
GUEST = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
MODERN = "2026-07-28"

checks = []
results = {}


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail if isinstance(detail, str) else repr(detail)[:300]})


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


class Client:
    """A minimal MCP client: one JSON-RPC message per line on the server's stdin and stdout."""

    def __init__(self):
        self.proc = subprocess.Popen([str(DMX), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(HOME / "mcp-stderr.log", "wb"), env=ENV)
        self.replies = {}
        self.cond = threading.Condition()
        self.bad_lines = []
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                msg = json.loads(line)
                assert msg.get("jsonrpc") == "2.0"
            except Exception:
                self.bad_lines.append(line[:200])
                continue
            with self.cond:
                self.replies[json.dumps(msg.get("id"))] = msg
                self.cond.notify_all()

    def send(self, msg):
        self.proc.stdin.write(json.dumps(msg).encode() + b"\n")
        self.proc.stdin.flush()

    def wait(self, id, timeout=60):
        key = json.dumps(id)
        with self.cond:
            self.cond.wait_for(lambda: key in self.replies, timeout)
            return self.replies.pop(key, None)

    def request(self, method, params=None, modern=False, timeout=60):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if modern:
            params = dict(params or {})
            params["_meta"] = {f"io.modelcontextprotocol/protocolVersion": MODERN,
                               "io.modelcontextprotocol/clientCapabilities": {},
                               "io.modelcontextprotocol/clientInfo": {"name": "test-mcp", "version": "1"}}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        return self.wait(self.next_id, timeout)

    def call(self, name, arguments=None, timeout=60, **kw):
        reply = self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout, **kw)
        return reply.get("result") if reply else None


def guest_has(pattern):
    r = c.call("dmx_exec", {"argv": ["ps", "-o", "args"]})
    return pattern in r["structuredContent"]["stdout"]


HOME = Path(tempfile.mkdtemp(prefix="dmx-mcp-", dir="/tmp"))
ENV = {**os.environ, "DMX_HOME": str(HOME)}
(HOME / "guest").symlink_to(GUEST)
try:
    c = Client()

    # Legacy handshake.
    r = c.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                 "clientInfo": {"name": "test-mcp", "version": "1"}})
    res = (r or {}).get("result", {})
    check("initialize", res.get("protocolVersion") == "2025-11-25" and res.get("serverInfo", {}).get("name") == "dmx"
          and "tools" in res.get("capabilities", {}), r)
    r = c.request("initialize", {"protocolVersion": "2099-01-01", "capabilities": {}, "clientInfo": {"name": "x", "version": "1"}})
    check("initialize_unknown_version", r["result"]["protocolVersion"] == "2025-11-25", r)
    c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    r = c.request("ping")
    check("ping", r.get("result", {}).get("resultType") == "complete", r)

    r = c.request("tools/list")
    tools = {t["name"]: t for t in r["result"]["tools"]}
    results["tools"] = sorted(tools)
    check("tools_list", {"dmx_exec", "dmx_status", "dmx_start", "dmx_stop", "dmx_config_get", "dmx_config_set"} <= set(tools)
          and all(t["inputSchema"]["type"] == "object" for t in tools.values()), sorted(tools))

    # Stateless revision: per-request _meta, server/discover, unsupported versions.
    r = c.request("server/discover", {}, modern=True)
    res = r.get("result", {})
    check("discover", MODERN in res.get("supportedVersions", []) and "tools" in res.get("capabilities", {})
          and res.get("_meta", {}).get("io.modelcontextprotocol/serverInfo", {}).get("name") == "dmx"
          and res.get("resultType") == "complete" and isinstance(res.get("ttlMs"), int), r)
    c.next_id += 1
    c.send({"jsonrpc": "2.0", "id": c.next_id, "method": "tools/list", "params": {"_meta": {
        "io.modelcontextprotocol/protocolVersion": "1900-01-01", "io.modelcontextprotocol/clientCapabilities": {}}}})
    r = c.wait(c.next_id)
    check("unsupported_version", r.get("error", {}).get("code") == -32022 and MODERN in r["error"]["data"]["supported"]
          and r["error"]["data"]["requested"] == "1900-01-01", r)
    c.next_id += 1
    c.send({"jsonrpc": "2.0", "id": c.next_id, "method": "tools/list",
            "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": MODERN}}})
    r = c.wait(c.next_id)
    check("missing_capabilities", r.get("error", {}).get("code") == -32602, r)

    # Cold exec: starts the daemon and boots the VM.
    started = time.time()
    r = c.call("dmx_exec", {"argv": ["uname", "-a"]}, modern=True)
    results["cold_exec_ms"] = int((time.time() - started) * 1000)
    if "structuredContent" not in (r or {}):
        raise SystemExit(f"cold exec failed: {r}")
    s = r["structuredContent"]
    check("exec_uname", s["exit_code"] == 0 and s["stdout"].startswith("Linux") and r["isError"] is False
          and json.loads(r["content"][0]["text"]) == s, s)
    started = time.time()
    c.call("dmx_exec", {"argv": ["true"]})
    results["warm_exec_ms"] = int((time.time() - started) * 1000)

    r = c.call("dmx_exec", {"argv": ["sh", "-c", 'cat; echo "$A $(pwd)"; echo err >&2; exit 3'],
                            "stdin": "in\n", "env": {"A": "b"}, "cwd": "/tmp"})
    s = r["structuredContent"]
    check("exec_stdin_env_cwd", s["exit_code"] == 3 and s["stdout"] == "in\nb /tmp\n" and s["stderr"] == "err\n"
          and r["isError"] is False, s)

    # Large output: 200 MB of stdout, capped to the default 8 KiB, with bounded memory.
    peak_rss = [0]
    sampling = [True]

    def sample():
        while sampling[0]:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(c.proc.pid)], capture_output=True, text=True).stdout
            if out.strip():
                peak_rss[0] = max(peak_rss[0], int(out))
            time.sleep(0.05)

    rss_before = int(subprocess.run(["ps", "-o", "rss=", "-p", str(c.proc.pid)], capture_output=True, text=True).stdout)
    sampler = threading.Thread(target=sample)
    sampler.start()
    started = time.time()
    r = c.call("dmx_exec", {"argv": ["sh", "-c", "head -c 200000000 /dev/zero | tr '\\0' a; echo; echo the-end"]}, timeout=120)
    seconds = time.time() - started
    sampling[0] = False
    sampler.join()
    s = r["structuredContent"]
    total = 200000000 + 1 + 8
    results["large_output_200mb_s"] = round(seconds, 2)
    results["mcp_rss_before_mb"] = rss_before // 1024
    results["mcp_rss_peak_during_200mb_mb"] = peak_rss[0] // 1024
    check("large_output_capped", s["stdout_bytes"] == total and s["stdout_omitted_bytes"] == total - 8192
          and s["stdout"].startswith("a" * 4096) and s["stdout"].endswith("a\nthe-end\n")
          and "bytes omitted" in s["stdout"] and len(r["content"][0]["text"]) < 20000,
          {k: v for k, v in s.items() if k not in ("stdout", "stderr")})
    check("large_output_bounded_memory", peak_rss[0] - rss_before < 32 * 1024, f"rss {rss_before} -> peak {peak_rss[0]} KB")

    # Cuts fall on UTF-8 character boundaries.
    r = c.call("dmx_exec", {"argv": ["sh", "-c", "printf x; i=0; while [ $i -lt 100 ]; do printf '\\303\\251'; i=$((i+1)); done"],
                            "max_output_bytes": 101})
    s = r["structuredContent"]
    check("utf8_boundaries", "�" not in s["stdout"] and s["stdout"].startswith("xé") and s["stdout"].endswith("é")
          and s["stdout_bytes"] == 201, s)
    r = c.call("dmx_exec", {"argv": ["echo", "hello"], "max_output_bytes": 0})
    s = r["structuredContent"]
    check("max_output_zero", s["stdout_bytes"] == 6 and s["stdout_omitted_bytes"] == 6, s)

    # Timeout kills the process and its children.
    started = time.time()
    r = c.call("dmx_exec", {"argv": ["sh", "-c", "echo before; sleep 1234 & sleep 1235"], "timeout": 2})
    seconds = time.time() - started
    s = r["structuredContent"]
    results["timeout_2s_returned_s"] = round(seconds, 2)
    check("timeout", s["timed_out"] is True and r["isError"] is True and s["exit_code"] is None
          and s["stdout"] == "before\n" and 1.9 < seconds < 6, (round(seconds, 2), s))
    gone = wait_for(lambda: not guest_has("sleep 123"), 5)
    check("timeout_killed_guest_processes", gone, "gone" if gone else "sleep 1234/1235 still running")

    # notifications/cancelled stops a running call: no reply, guest process killed.
    c.next_id += 1
    cancel_id = c.next_id
    c.send({"jsonrpc": "2.0", "id": cancel_id, "method": "tools/call",
            "params": {"name": "dmx_exec", "arguments": {"argv": ["sleep", "2345"]}}})
    time.sleep(1)
    c.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": cancel_id, "reason": "test"}})
    gone = wait_for(lambda: not guest_has("sleep 2345"), 5)
    no_reply = c.wait(cancel_id, timeout=1) is None
    check("cancel", gone and no_reply, f"process gone {gone}, no reply {no_reply}")

    # Errors: tool errors carry the DMXError code and hint; protocol errors are JSON-RPC errors.
    r = c.call("dmx_exec", {"argv": ["true"], "timeout_s": 3})
    check("bad_argument", r["isError"] is True and "bad_argument" in r["content"][0]["text"] and "hint:" in r["content"][0]["text"], r)
    r = c.call("dmx_exec", {"argv": ["nosuch-binary"]})
    check("missing_binary", r["isError"] is True and "nosuch-binary" in r["content"][0]["text"], r)
    r = c.request("tools/call", {"name": "nosuch", "arguments": {}})
    check("unknown_tool", r.get("error", {}).get("code") == -32602, r)
    r = c.request("nosuch/method")
    check("unknown_method", r.get("error", {}).get("code") == -32601, r)
    c.proc.stdin.write(b"{not json\n")
    c.proc.stdin.flush()
    r = c.wait(None, timeout=5)
    check("parse_error", r and r.get("error", {}).get("code") == -32700, r)

    # Config.
    r = c.call("dmx_config_set", {"key": "idle_timeout", "value": "7m"})
    s = r["structuredContent"]
    check("config_set", s["settings"] == {"idle_timeout": "7m"} and s["configured"] == ["idle_timeout"], r)
    r = c.call("dmx_config_get", {})
    check("config_get", r["structuredContent"]["settings"].get("idle_timeout") == "7m"
          and {"cpus", "memory", "idle_timeout"} <= set(r["structuredContent"]["settings"]), r)
    r = c.call("dmx_config_set", {"key": "idle_timeout", "value": None})
    check("config_unset", r["structuredContent"]["settings"] == {"idle_timeout": "5m"} and r["structuredContent"]["configured"] == [], r)
    r = c.call("dmx_config_set", {"key": "memory", "value": "1M"})
    check("config_bad_value", r["isError"] is True and "bad_config_value" in r["content"][0]["text"], r)

    # Status, stop, start.
    r = c.call("dmx_status", modern=True)
    s = r["structuredContent"]
    results["footprint_running_mb"] = s.get("host_footprint_mb")
    check("status_running", s["state"] == "running" and r["isError"] is False, s)
    r = c.call("dmx_stop")
    check("stop", r["structuredContent"]["state"] == "stopped", r["structuredContent"])
    r = c.call("dmx_start")
    check("start", r["structuredContent"]["state"] == "running", r["structuredContent"])

    check("stdout_only_protocol", not c.bad_lines, c.bad_lines)

    # Closing stdin ends the server.
    c.proc.stdin.close()
    try:
        c.proc.wait(timeout=5)
        exited = True
    except subprocess.TimeoutExpired:
        c.proc.kill()
        exited = False
    check("exit_on_eof", exited and c.proc.returncode == 0, f"returncode {c.proc.returncode}")
    results["mcp_max_rss_mb"] = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // (1 << 20)
finally:
    try:
        c.proc.kill()
    except Exception:
        pass
    for pid in daemon_pids():
        os.kill(pid, signal.SIGTERM)
    wait_for(lambda: not daemon_pids(), 15)
    if sys.exc_info()[0] or not all(x["ok"] for x in checks):
        sys.stderr.write((HOME / "mcp-stderr.log").read_text(errors="replace")[-3000:])
    shutil.rmtree(HOME, ignore_errors=True)

ok = all(x["ok"] for x in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
