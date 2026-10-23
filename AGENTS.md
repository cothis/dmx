# Working on dmx

Read [docs/PLAN.md](docs/PLAN.md) first. It holds the goal, the decisions and their reasons, every
phase with its tasks, the next task, and the measurements so far.

## When asked to continue ("이어서 진행해", "continue")

1. Read `docs/PLAN.md` and `git log --oneline -10`. Start at **Next up**.
2. Do that task, then the following unchecked tasks in the same phase while they stay on track.
   Stop and ask only for decisions that belong to the maintainer (scope, naming, licensing, anything public).
3. Verify on the real VM, not just by compiling: `make build && make guest && make selftest`,
   plus whatever the task's "Done when" says.
4. Update `docs/PLAN.md` in the same commit: tick tasks, rewrite **Next up**, add measurements
   to **Findings and measurements**, add a dated line to **Progress log**.
5. Commit with a message that says what changed and why, then `git push` without asking (the maintainer said so on 2026-10-23). Never force-push.
6. Report to the maintainer in Korean: what works now, what was measured, what is next.

## Rules

- Logic lives in `Sources/DMXCore`; `Sources/dmx` only parses arguments and prints.
- Every command supports `--json`. Failures are `DMXError(code, message, hint)` with a stable code
  and a hint that names the next command to run. No interactive prompts.
- Memory savings (balloon, idle stop, cache trimming) are defaults, never opt-in flags.
- Measure memory before and after any change that could affect it, and record the numbers.
- Guest inputs are pinned by sha256 in `scripts/build-guest.py`. Do not fetch unpinned artifacts.
- Never commit anything from `~/.dmx` (kernel, initramfs, caches).
- Commits use the repo-local identity (`cothis`, GitHub noreply email). Do not change it.

## Testing tips

- macOS has no `timeout`; use `perl -e 'alarm 20; exec @ARGV' <cmd>`.
- To test the interactive console, drive `dmx boot` through a pty from Python (`pty.openpty()`);
  macOS `script` with piped stdin does not forward input reliably.
- Host memory of the VM: selftest `host.footprint_mb`, which is `ri_phys_footprint` of the dmx process
  (guest RAM lives there). Do not use the `footprint` tool: it leaves out guest pages.
