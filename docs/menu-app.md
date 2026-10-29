# Native menu app

`dmx.app` is a manually launched AppKit menu utility for macOS 15+ on Apple Silicon. It shares
the existing DMXCore engine and state directory; it does not embed another VM or runtime.

## Build and launch

From the source checkout with Swift/Xcode command-line tools available:

```sh
make guest
make install-app
```

This installs one complete app into `~/Applications/dmx.app` and links its helper as
`~/.local/bin/dmx` (`PREFIX` selects another terminal prefix). It does not restart a running VM
or install a menu login item. Launch dmx from Applications, the app launcher or Spotlight.
`make app` only packages `.build/dmx.app`; source apps are ad-hoc signed for local use.
The v0.4.0 public installer includes the same app and CLI together, plus pinned Docker tools.
Public apps use Developer ID signing, hardened runtime, notarization and a stapled ticket.

Launching selects the dmx Docker context and ensures the pinned Docker CLI tools/plugins are
installed, using the same setup as the CLI. An already running compatible daemon/VM is reused.
An older daemon without lifecycle receipts is reported with a recovery hint; the app does not
silently stop its containers to upgrade it.

## Controls and lifetime

- Engine state and measured engine/menu physical footprint (MiB).
- Containers, with their image/status and Start/Stop actions. Names are bounded in the menu;
  tooltips preserve full names and images. Lists over 100 entries point to `docker ps -a`.
- Refresh, Open logs, persistent error details and Retry.
- Quit dmx: powers off the guest, exits the daemon and then closes the app. Containers and data
  are preserved with the same shutdown semantics as `dmx stop`; restart policies still apply.

Normal idle VM stop and external `dmx stop` close the menu process too. The engine retains its
usual 10-second daemon linger; saved port forwards keep their listener as before. Menu Docker
requests use a control-socket tunnel bound to the existing running guest. They cannot boot a
stopped/stopping VM and do not claim the independent Docker CLI socket's keepalive. Closing
the menu never clears another client's socket use. A failed boot, guest failure or abrupt
daemon exit stays visible with recovery. Ordinary refresh/container errors clear after success
or normal engine stop, and never make a stopped app remain resident.
CLI/Docker use does not require the app and does not automatically launch its UI.

## Passive observation

The daemon atomically replaces `$DMX_HOME/run/engine.json` at lifecycle/container-count changes.
The receipt has pid/version/state/container count, a monotonic sequence and an optional reason
or structured failure. Retry ignores duplicate/older receipts from the same daemon.
The app watches the dedicated directory and the daemon's process exit. Observation opens no
control socket, holds no start lease, uses no polling timer and does not sample guest memory.
Menu opening/Refresh queries details; each control/API connection is closed after its operation.
An app startup temporarily keeps its start lease until first-time tools setup completes.
Only explicit Start may spawn the app's CLI helper; a missing standalone Docker socket during
a menu read/action fails instead of running the UI executable as a daemon. Quit cancels first-run guest/tool downloads and drains existing
menu operations before its final stop, so a late container action cannot undo shutdown. Menu
HTTP streams have a 30-second one-shot deadline: it shuts the owned stream down to wake both
the blocking read's `poll` and writes, then reports `docker_timeout`. It never closes a descriptor
from the deadline callback. Control calls have one-shot deadlines too (30 seconds normally, 150 seconds for stop).
The first start waits for a slow guest download without a client deadline; Quit cancels its
owned connection and a download before VM creation.
Once a VM has begun formatting its first disk, shutdown lets the guest agent connect (up to
120 seconds) before graceful poweroff; cancelling a download does not begin a VM. There is no
repeating status timer.

The capabilities are additive to protocol 1 (`hello.activity_notifications` and `menu_control`);
older CLI clients ignore them. New menu apps report an incompatible older daemon with a hint
instead of stopping its containers. `dmx update` identifies the actual helper executable,
verifies the download's publisher/version, and replaces the complete signed app. The CLI link
continues to follow the app. Running VM/menu processes retain their mapped old executable until
they stop; reopen the app after updating. Legacy standalone updaters cannot add the app: run
v0.4.0's installer once to migrate.

App installation extracts only validated member names to stdout, writes its own regular files,
verifies bundle/helper signatures and version, stages and re-verifies beside the destination,
then exchanges whole app directories with `RENAME_SWAP` and atomically renames the CLI link.
The installed path never disappears. A failed CLI commit rolls back the app exchange. An
existing Developer ID app also pins the incoming identity; `make install-app` explicitly permits
source signing with `--allow-signing-change`. It refuses to replace a different app,
link a CLI inside a signed bundle, or install a damaged bundle. No archive-controlled symlink
is materialized. The CLI/helper's signing team anchors public installation and updates.

## Verification

```sh
make build && make guest && make selftest
make test && make daemontest && make mcptest && make menutest
make apptest
```

`menutest` uses a temporary state directory and real VM: lifecycle capability/receipts,
active-VM release refusal, a real Docker listing, idle stop, release/daemon exit, passive reads,
independent CLI socket retention/restart, cancellation of a held-open first guest download,
and an unexpected guest poweroff. It does not substitute for visually
checking the actual menu, container actions, explicit Quit, app relaunch and idle UI exit.

`make menutest` also runs an opt-in Swift integration suite against a separate real VM,
using MenuEngine itself: start, typed container listing, container start/stop (including 304),
host-port collision and engine quit. `apptest` exercises real signed-bundle install, refusal of
damaged/traversal/duplicate/link archives, rollback after a failed CLI commit, and whole-app
self-update with a live VM and guest data.
It uses a disposable BusyBox workload image and the pinned guest/tools already installed on
the host. Normal `make test` skips that VM suite.

To reproduce the UI overhead measurement, find the PID with `pgrep -x dmx-menu`, close the
menu, then run `python3 -I scripts/measure-menu.py PID --seconds 45`. It reuses the engine
benchmark's `ri_phys_footprint`/Mach CPU reader and checks its conversion against getrusage.
This measures the menu process, not the daemon/guest. A single interval is a sample, not a
cross-machine guarantee or a comparison with another container engine.

For local UI diagnostics only, `DMX_MENU_TRACE=1` records native menu-open/close and error-button
callbacks in `$DMX_HOME/logs/menu-ui.json` and `menu-events.jsonl`. The trace lives outside
the watched run directory so it cannot manufacture lifecycle notifications. It does not drive UI or run a timer, and is off by
default. A callback receipt is behavioral evidence, not a substitute for a menu screenshot.

## Local measurements (2026-10-29)

After opening the menu with no containers, the UI process measured **14.92 MiB** and
**0.002103% of one CPU core over 45 seconds**. This is an additional process cost, excluding
the engine/guest. It is a single sample with host pressure recorded, not a universal budget.
External engine stop removed the actual menu process and the daemon exited after its linger.
The error dialog/OK callback and synthetic existing-error refresh were checked; full
menu/submenu screenshots and direct GUI container/Quit clicks remain unverified. See
[measurements, checks and proof limits](measurements/2026-10-29-menu-app.json).

## Opus 5.5 release review (2026-10-29)

The requested independent review used the actual `claude-opus-5-5` model in read-only mode.
The first review required fixes for operation-error retention, Docker 304 handling, independent
CLI keepalive and first-run cancellation, plus lifecycle/deadline/reaping races. These changes
are covered by production state tests, actual socket waits and real-VM tests. A port-conflict
regression also exposed a synthetic HTTP refusal lacking EOF; the proxy now explicitly closes
that response. Review reports and qualification evidence are recorded with the release.

An actual Finder-launched/reopened app encountered a real malformed isolated Docker daemon
configuration, rendered `docker_failed`, then received normal idle stop, cleared its error and
exited. This was not a synthetic receipt. Full menu/submenu captures and direct GUI Start/Stop/
Quit clicks remain unverified by the available windowless-app automation. The initial old-app
UI attempt did not isolate P1, and is not claimed as a controlled old/new reproduction.

The final v0.4.0 source was also sampled after launch with pinned tools already present and
before opening its menu: **11.92 MiB**, **0.000434% of one core over45 seconds**, host pressure
normal. It exited after an external normal engine stop. This was an isolated ad-hoc QA bundle
with the final source, not an exported-performance guarantee for every Mac. It is a different
usage phase from the earlier14.92 MiB sample after menu use, so no reduction is inferred.
