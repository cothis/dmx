# dmx mcp

`dmx mcp` is an [MCP](https://modelcontextprotocol.io) server on stdin and stdout. An AI client
starts it as a subprocess; it lets the agent run commands in dmx's Linux VM, manage the VM, and use sandboxes.
Code lives in `Sources/DMXCore/MCP`.

It is not the daemon. Each tool call connects to the daemon's control socket
([daemon-protocol.md](daemon-protocol.md)), starting the daemon if nothing answers, and
disconnects when done. Between calls it holds nothing open, so an idle VM still stops after
`idle_timeout` and the daemon still exits, even while the client keeps `dmx mcp` running.

## Registering it

Claude Code:

```sh
claude mcp add dmx -- dmx mcp
# or for every project:
claude mcp add --scope user dmx -- dmx mcp
```

Other clients take a command and arguments in their MCP configuration, usually:

```json
{"mcpServers": {"dmx": {"command": "dmx", "args": ["mcp"]}}}
```

Use the absolute path (`~/.local/bin/dmx` after `make install`) if the client does not search
`PATH`. To use another state directory, set `DMX_HOME` in the server's environment
(`claude mcp add --env DMX_HOME=/path dmx -- dmx mcp`).

## Protocol

Newline-delimited JSON-RPC 2.0. stdout carries only protocol messages; logs go to stderr, one
line per tool call. Supported revisions:

- **2026-07-28** (current, stateless): each request names its version and client capabilities in
  `_meta` (`io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientCapabilities`);
  `server/discover` returns the supported versions. An unknown version gets error -32022 with
  `data.supported`; a request without `clientCapabilities` gets -32602.
- **2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05** (handshake): `initialize`, answered with the
  client's version if listed, else 2025-11-25; then `notifications/initialized`.

Both kinds can be mixed in one process. Methods: `server/discover`, `initialize`, `ping`,
`tools/list`, `tools/call`; the notification `notifications/cancelled` stops a running call
(an exec's process is killed and the call gets no reply). Requests are served concurrently,
so a long `dmx_exec` does not hold up others. Batches are not supported (they were removed in
2025-06-18). Results carry `resultType: "complete"` and `_meta` with
`io.modelcontextprotocol/serverInfo`; `tools/list` and `server/discover` carry `ttlMs` (5 min)
and `cacheScope: "public"`. The server exits when stdin closes.

## Tools

Every tool result has the JSON in `structuredContent` and the same JSON as text in `content`.
Failures are results with `isError: true` and the text
`error (<code>): <message>` plus `hint: <next step>`, with the codes of the CLI's `--json`
errors (for example `daemon_unreachable`, `guest_missing`, `agent_exec_failed`,
`bad_config_value`, and `bad_argument` for arguments that do not match the input schema).
An unknown tool name is a JSON-RPC error (-32602).

| Tool | Arguments | Result |
|---|---|---|
| `dmx_exec` | `argv` (required), `stdin`, `env` (object), `cwd`, `timeout` (s, default 120, max 3600), `max_output_bytes` (per stream, default 8192, max 1 MiB) | `exit_code`, `signal`, `timed_out`, `duration_ms`, `stdout`, `stderr`, `stdout_bytes`, `stderr_bytes`, `stdout_omitted_bytes`, `stderr_omitted_bytes` |
| `dmx_status` | none | `dmx status --json`; never boots the VM |
| `dmx_start` | none | status, once the guest agent answers |
| `dmx_stop` | none | status, once the VM is off |
| `dmx_config_get` | `key` | `settings` (values in effect), `configured` (keys set in the file), `file` |
| `dmx_config_set` | `key`, `value` (null resets it) | the same, for that key; applies at the next boot |
| `dmx_sandbox_create` | `name`, `image`, `network` (`"none"`, `"all"` or an array of hosts and CIDRs), `mounts` (`[{host, path, writable}]`), `cpus`, `memory`, `pids`, `ttl` (seconds or `"30m"`), `env`, `workdir`, `command` | the sandbox: `name`, `state`, `policy`, `allowed`, `expires_at`, `expires_in_s`, `checkpoints`, ... |
| `dmx_sandbox_exec` | `name`, `argv` (required), `stdin`, `env`, `cwd`, `timeout`, `max_output_bytes` | as `dmx_exec` (`signal` is always null) |
| `dmx_sandbox_list` | none | `sandboxes`; those past their TTL are removed first |
| `dmx_sandbox_rm` | `name` | `name`, `container`, `checkpoints` removed |
| `dmx_sandbox_checkpoint` | `name`, `checkpoint` (default `c<N>`) | `name`, `image`, `created_at`, `size_mb`, `added_mb`, `ms` |
| `dmx_sandbox_rollback` | `name`, `checkpoint` (default the latest) | the sandbox |
| `dmx_sandbox_fork` | `name`, `new_name`, `checkpoint` (default: the current state), `ttl` | the new sandbox |
| `dmx_logs` | `target` (sandbox, or container name or id), `since`, `tail`, `timestamps`, `max_output_bytes` | `stdout`, `stderr` capped as for exec, their totals and omitted bytes, `summary` (`stdout_lines`, `stderr_lines`, `error_lines`, `errors`) |

### dmx_exec

`argv` runs directly, without a shell; use `["sh", "-c", "..."]` for pipes. The VM boots on the
first call. A non-zero exit is a normal result (`isError: false`); the agent reads `exit_code`.

**Output limits.** Each stream keeps its first `max_output_bytes / 2` and last
`max_output_bytes / 2` bytes, cut on UTF-8 character boundaries, with a marker line between
them: `[... dmx: 199991817 bytes omitted ...]`. `*_bytes` is what the command wrote in total
and `*_omitted_bytes` what is not in the text. Memory stays bounded while collecting: the
server keeps the head, a tail window of at most twice its half, and a count, and reads the
rest of the stream only to discard it (200 MB of output: `dmx mcp` stays at 9 to 10 MB RSS).
The defaults keep both streams together at about 16 KiB, a few thousand tokens. For more,
raise `max_output_bytes`, or write the output to a file in the VM and read parts of it.

**Timeouts and cancellation.** When `timeout` runs out, `dmx mcp` shuts its connection down;
the daemon closes the agent's connection and the agent kills the command's process group with
SIGKILL, so children it started die too. The result has `timed_out: true`, `exit_code: null`,
the output so far, and `isError: true`. `notifications/cancelled` does the same without a
reply.

### Sandboxes and logs

`dmx_sandbox_*` give an agent disposable environments with a policy: by default no network, no
host files, 2 CPUs, 1G and a 30 minute TTL, after which the daemon removes them even if the
client is gone. Grant only what the task needs. Checkpoints save the filesystem (not processes),
rollback restores one, fork starts a copy to try a second approach. `dmx_logs` reads a sandbox's
or any container's logs with the exec caps, plus a summary of the whole log (line counts and the
first and last lines that look like errors; a pattern match, no model). The policy model, what
the isolation does and does not guarantee, and measurements are in [sandbox.md](sandbox.md).

## Testing

`make mcptest` (`scripts/test-mcp.py`) starts `dmx mcp` in a throwaway `DMX_HOME`, drives it over
pipes with both protocol eras, and checks every tool, the output cap and its memory, UTF-8
cuts, timeout and cancellation (the guest processes are gone afterwards), errors, and exit on
EOF. `make sandboxtest` (`scripts/test-sandbox.py`) does the same for the sandbox and logs tools.
