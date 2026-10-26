# Agent memory: maintainer preferences and lessons

Long-term memory shared by Claude Code and Codex. Rules are in `AGENTS.md` (`CLAUDE.md` imports it), plans and
measurements in `docs/PLAN.md`, the next-session handoff in `docs/HANDOFF.md`. This file holds only what code and git
do not record. Add a dated line under the right heading when you learn something, and commit it with the work.
This repo is public: no private hostnames, IPs or personal details here.

## Project

- 2026-10-23: dmx is a Docker-compatible container engine for macOS, open source (Apache-2.0) from the start.
  Goals: a VM that does not hold memory (balloon, idle stop), docker CLI compatibility (Engine API socket),
  AI-native (`--json`, structured errors, `dmx mcp`). The maintainer accepts a VM but dislikes fixed memory allocation,
  so memory savings are the main differentiator.
- Memory savings are always-on defaults, never opt-in flags.
- Host memory of the VM is reported as `ri_phys_footprint` of the dmx process (not RSS, not the `footprint` tool).

## Maintainer preferences

- Chat with the maintainer in Korean, every message (status updates and plans too, not only the final report).
  Code, commits and docs stay English as the repo does (HANDOFF is Korean). The maintainer had to say "한글로 말해라"
  twice on 2026-10-24.
- Commit, then `git push` without asking (2026-10-23: "묻지말고푸시하고"). Never force-push. Work on `main` in the
  existing checkout, no branches or worktrees.
- Keep asking before: scope, naming, licensing, tags, GitHub releases, anything public.
- Open design and security choices: do what Docker Desktop and standard tools do; Docker must just work. Don't ask,
  record the choice in PLAN.md Decisions (2026-10-24: "도커가 정상적으로 동작하면 돼. 보안같은것도 표준 프로그램에 맞게").
  Examples: share `/Users` rw, `host.docker.internal` reaches the host, ports bind 127.0.0.1 by default.
- Keep hardening that costs only a few MB (2026-10-24: `rodata=noalias` saved 4 MB but was rejected, "4MB네
  보안강화면 좋은거같다"). If a memory saving weakens security, measure it, present the MB number and let the maintainer decide.
- Installing Docker Desktop, OrbStack or Colima briefly on this Mac for comparison benchmarks is OK
  (2026-10-25). Back up and restore what they change (`~/.docker`, contexts, PATH links), stop them while measuring
  others, uninstall afterwards. License and admin-password prompts stay the maintainer's.
- "남은 작업 진행하자. 문서도 현행화해": start at PLAN.md and HANDOFF.md, do one coherent next item, update
  plan/progress/measurements in the same work, verify on a real VM, commit, push.

## Lessons

- When stuck on a hard debugging problem, ask Codex for a second opinion (2026-10-26):
  `perl -e 'alarm 900; exec @ARGV' codex exec -m gpt-6-astra -s read-only - < prompt.txt`. Its sandbox cannot read
  files outside the repo, so put the symptom, what is ruled out, build specifics and code excerpts in the prompt, ask
  for ranked hypotheses plus the cheapest diagnostic, and verify the answer yourself. It found the FEX 32-bit cause
  (fallback vsyscall page mapped read-only) after a wrong lead of mine.
- `guest_used_mb` from `MemAvailable` overstates use; use `total - free - buffers - cached + shmem`. Intermediate
  balloon growth is not successful reclaim: wait for balloon state and footprint recovery. Unplug virtio-mem surplus
  before ballooning.
- A pushed main and a green test matrix are not a public release; release and notarization are maintainer decisions.
- Guest agent: control and exec must use separate vsock connections, or you get `Broken pipe`.
