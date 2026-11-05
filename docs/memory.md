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

- 2026-11-05: Authorized publishing v0.4.5 ("릴리즈 배포해"). As before, this does not include community announcements.

- 2026-10-30: Authorized deleting regenerable development/release artifacts, hardening log
  growth, actual Opus 5.5 review and release after resolving defects. Preserve user VM data
  and pinned build inputs. Paused during preflight, then explicitly resumed. This authorization
  does not include community announcements or a new GitHub Actions exception.

- 2026-10-29: Allowed one manually dispatched GitHub Actions job to reconstruct the byte-identical,
  pinned GPL source archive from the previous public release and upload it to the existing draft.
  App builds and tests stay local; remove the active workflow after upload. This is a one-time
  distribution exception, not adoption of GitHub CI.

- 2026-10-29: Requested actual Opus 5.5 review and authorized release conditional on resolving
  review defects. The public app installation should include its CLI in one installation, with
  whole-app updates preserving the signed bundle; old CLI-only updaters require the new
  installer once to add the app. Community announcements are not part of release authorization.

- 2026-10-29: Approved a manually launched native dmx.app (app launcher/Applications) with a
  menu bar status item, memory and container start/stop controls, errors and engine shutdown.
  The menu app must exit with normal/idle engine shutdown instead of remaining resident;
  CLI use stays independent. Avoid background status polling and a menu login item. The
  earlier 10–30 MB estimate is not a benchmark: measure the actual app before claiming its cost.
- Chat with the maintainer in Korean, every message (status updates and plans too, not only the final report).
  Code, commits and docs stay English as the repo does (HANDOFF is Korean). The maintainer had to say "한글로 말해라"
  twice on 2026-10-24, and again on 2026-10-27 after a status message written in English mid-release.
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
  Removing the apps is not enough (2026-10-27: they had been left behind): also undo what they write
  outside their own folders. Docker Desktop: PATH blocks in `~/.zprofile` and `~/.profile`, a
  completion block with `compinit` in `~/.zshrc`, `credsStore` in `~/.docker/config.json` (the
  helper goes with the app, which breaks later pulls), a `com.docker.helper` launchd job. OrbStack:
  `~/.zprofile` and `~/.ssh/config` includes, `~/OrbStack`, its group container. Colima: an
  `~/.ssh/config` include, `~/Library/Caches/colima` (317 MB).
- Delegate simple checks (summaries, disassembly, reviews) to Sonnet subagents while doing the hard reasoning
  yourself (2026-10-27: "단순작업은 sonnet으로 확인하면서"). Verify what they report before relying on it.
- "남은 작업 진행하자. 문서도 현행화해": start at PLAN.md and HANDOFF.md, do one coherent next item, update
  plan/progress/measurements in the same work, verify on a real VM, commit, push.

## Lessons

- 2026-11-05: Keep the script that verifies a release in the repository. v0.4.4's 32-check proof lived in a temporary
  folder and only its logs survived, so v0.4.5 had to rewrite it. A check you run for every release is code.
- 2026-11-05: A fix on one path says nothing about the retry path beside it. The AAAA rule covered UDP; a reply
  over 512 bytes sent glibc to TCP, which went elsewhere, and only names with long answers hit it, so PyPI passed and
  S3 failed. When a client has a fallback, test the fallback too, with a name large enough to take it.
- 2026-11-05: A footprint difference between suites run on different builds and guests is not a measurement.
  dockertest read 415 vs 281 MB; the same guest and alternating rounds gave 295.25 vs 295.75. Isolate before concluding either way.

- 2026-11-05: Before fixing a permission, check the test can see it. A release check ran from a new temporary
  path each time, so `allowed -> blocked` was certain whatever updates did; I then proposed a launchd key on a
  log-based theory, and probes under identifiers macOS had never seen refuted both. Isolate from the state
  this Mac has piled up, and let the measurement drop the fix.

- 2026-11-05: A local release mirror is the daemon's environment too. A signed-update rehearsal
  passed DMX_RELEASE_URL only to the CLI; launchd tried the unpublished public guest URL, got 404,
  and correctly booted the previous guest. Forward the mirror into the job and verify both the
  receipt and live emulator hash before calling a run evidence for the new release.

- 2026-11-05: Keep a shell parent when testing `timeout` in a container: `sh -c 'timeout 1 sleep 5'`
  can exec sleep as PID 1, which does not take the default SIGTERM termination. It returned 0 after
  five seconds on both native arm64 and FEX; adding a command after timeout made both return 143
  after one second. That earlier "timeout failed" record was a harness mistake, not FEX evidence.
- 2026-11-05: A review's low-severity note can still be a real fault loop. Opus's inherited
  ignored-signal note reproduced, including a plain SIGSEGV; fix and regression-test the actual
  sequence. Rerun managed exceptions and measurements on the emulator built after that last fix,
  rather than carrying forward an earlier successful result.

- 2026-11-04: A crash that matches a reviewer's finding is not that finding. I called a code-write crash "confirmed" before reading its core, which showed
  a different bug; a build without the reviewed fix then passed, so the fixture was not testing it. Read the crash record, then test the fix by removing it.
- 2026-11-04: A wider use of an existing mechanism inherits limits it never needed. FEX's deferred frames were safe around short C++ sections and wrong
  around guest code: two rounds of green fixtures did not show that, a review did. Use the kernel's own queue where it can do the job.
- 2026-11-04: Comparing two builds, alternate them in short blocks and swap which goes first. A loop
  that always ran the candidate first made it look twice as crash-prone (25/75 vs 12/75) while other
  work's load fell; swapped, at a steady load, the same builds gave 0/60 and 5/60.
- 2026-11-04: "It works here" says little when the failure depends on the network. A diagnostic the
  affected Mac could run settled what no test here could, and a real client on the failing path matters:
  `pip` and `getaddrinfo` on glibc hid a failure that musl turns fatal. Compare clients on that path.
- 2026-11-04: Look before `rm -rf .build`: PLAN and HANDOFF can name preserved references inside it. In
  zsh an unmatched glob aborts the whole command, so a failed `ls` proves nothing. Run test-daemon.py
  from a path with no symlink (`/tmp` resolves to `/private/tmp` and its daemon lookup finds nothing),
  and stop a crashed run's daemon: it keeps the suite's ports and breaks the next run.

- 2026-10-29: Frozen formal properties can still be made tautological by ghost updates tied
  to a fix selector. Observe actual bindings/events and mutate guards, ownership, atomicity,
  error paths and replay independently. A progress test must assert before teardown supplies
  its wakeup; destructive FD reuse needs a child, not only suite serialization. Check newly
  added fallible work both before and after a transaction's first side effect.

- 2026-10-27: Confirm a cause with a diagnostic before writing its fix. For the guest network stall I first wrote
  a change that moved mDNSResponder calls off the network queue, on a guess; a diagnostic build then logged the
  real cause (a receive-buffer deadlock), and the guess was reverted unshipped. Log the suspected state at the
  moment of failure, reproduce it, then fix.
- 2026-10-27: Run every command you put in a document. README's signature check first used `codesign -dv`,
  which does not print the Authority chain it was meant to show; only running it caught that.
- 2026-10-27: A pipeline's exit status is its last command's. `cmd | tail && next` runs `next` after `cmd`
  failed (the v0.3.9 release commit lost its guest pin that way), and a reader at the end of a pipe can run
  before the writer finished (a rehearsal check read its result file too early). Capture exit codes, and read
  result files after the command returns.
- 2026-10-27: A suite failure is not "the environment" until something shows it. daemontest lost 6 network
  checks during v0.3.8's qualification; I blamed a DNS switch, a rerun passed, and I shipped. The same stall
  then hit a user's Mac: a 1-in-100 receive deadlock at boot (64 KB frames vs. the 32 x 1536 bytes of
  buffers Linux always keeps posted). Loop the failing step in isolation (here 300 fresh boots) before
  calling a failure environmental, and keep the first failure in the record either way.
- 2026-10-27: Diagnose an emulator crash from what the crash report recorded, not from repeat counts. Asking which
  byte mix of the old and new code produces exactly the recorded fault address and registers pinned the FEX Java
  crash in one pass, after 330 Java runs had stayed statistically inconclusive. A race probe must hit one site
  continuously and hold each state long enough; it is a regression test only once old and new emulators differ on it.
- 2026-10-27: Candidate emulator tests count only after the file packed into docker.img and the
  live `/var/lib/dmx/x86/FEX` match the candidate's sha256. `build-guest.py`'s `X86_EMULATORS`
  captures `DMX_FEX` at import time; changing only the latter on an imported module still packages
  the old emulator. Prefer the normal build recipe; use `test-images.py --expect-emulator-sha256`
  for candidate runs. A run with the wrong artifact is baseline evidence, not candidate evidence.

- When stuck on a hard debugging problem, ask Codex for a second opinion (2026-10-26):
  `perl -e 'alarm 900; exec @ARGV' codex exec -m gpt-6-astra -s read-only - < prompt.txt`. Its sandbox cannot read
  files outside the repo, so put the symptom, what is ruled out, build specifics and code excerpts in the prompt, ask
  for ranked hypotheses plus the cheapest diagnostic, and verify the answer yourself. It found the FEX 32-bit cause
  (fallback vsyscall page mapped read-only) after a wrong lead of mine.
- Two models reviewing the same diff is worth the tokens (2026-10-26, the maintainer asked for
  "sonnet 5.5 및 gpt sol6.1로 검수"): Claude Sonnet 5.5 through the Agent tool and
  `codex exec -m gpt-6.1-sol -s read-only` (if it answers "Selected model is at capacity", fall back to
  `gpt-6-astra`). Both found the same two worst defects in code that had already shipped, and between them nine more.
  Give them the diff range, the project rules and the riskiest areas, ask for file:line plus the sequence that breaks
  it, and verify every claim against the code before fixing: a few were already handled or needed narrowing.
- Review a self-updater as hostile input end to end: check the signature before running the downloaded binary, treat
  only an explicit `stopped` as idle before touching a VM, reject an archive member that is not a plain file, validate
  anything that reaches a URL or a path, and write receipts atomically.
- `guest_used_mb` from `MemAvailable` overstates use; use `total - free - buffers - cached + shmem`. Intermediate
  balloon growth is not successful reclaim: wait for balloon state and footprint recovery. Unplug virtio-mem surplus
  before ballooning.
- A pushed main and a green test matrix are not a public release; release and notarization are maintainer decisions.
- Guest agent: control and exec must use separate vsock connections, or you get `Broken pipe`.
