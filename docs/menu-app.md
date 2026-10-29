# Native menu app

`dmx.app` is a manually launched AppKit menu utility for macOS 15+ on Apple Silicon. It shares
the existing DMXCore engine and state directory; it does not embed another VM or runtime.

## Build and launch

From the source checkout with Swift/Xcode command-line tools available:

```sh
make guest
make install-app
```

This installs the CLI into `~/.local/bin` and the app into `~/Applications/dmx.app`, and refreshes
an existing launchd engine installation as `make install` does. It does not install a menu app
login item. Launch dmx from the app launcher, Applications or Spotlight. `make app` only packages
`.build/dmx.app` and does not install it. The app carries its CLI helper and an ad-hoc signature;
public app distribution and notarization are separate release work, not part of v0.3.12.

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
usual 10-second daemon linger; saved port forwards keep their listener as before. On idle stop,
`menu_release` lets a standalone Docker socket stop keeping the daemon resident, but refuses
if another client has already restarted/claimed the VM. A failed boot, guest failure or abrupt
daemon exit stays visible with recovery rather than disappearing as if it were a normal quit.
CLI/Docker use does not require the app and does not automatically launch its UI.

## Passive observation

The daemon atomically replaces `$DMX_HOME/run/engine.json` at lifecycle/container-count changes.
The receipt has pid/version/state/container count and an optional reason or structured failure.
The app watches the dedicated directory and the daemon's process exit. Observation opens no
control socket, holds no start lease, uses no polling timer and does not sample guest memory.
Menu opening/Refresh queries details; each control/API connection is closed after its operation.
An app startup temporarily keeps its start lease until first-time tools setup completes.
Only explicit Start may spawn the app's CLI helper; a missing standalone Docker socket during
a menu read/action fails instead of running the UI executable as a daemon. Quit drains existing
menu operations before its final stop, so a late container action cannot undo shutdown. Menu
HTTP streams have a 30-second one-shot deadline: it shuts the owned stream down to wake both
the blocking read's `poll` and writes, then reports `docker_timeout`. It never closes a descriptor
from the deadline callback. There is no repeating status timer.

The capability is additive to protocol 1 (`hello.activity_notifications`); older CLI clients
ignore it. New menu apps report an incompatible older daemon instead of silently losing idle
shutdown notifications. The bundled CLI refuses `dmx update` replacement of only itself,
including `--force`, because that would break the app's sealed signature. Rebuild/replace the
whole app, or update the separately installed CLI.

## Verification

```sh
make build && make guest && make selftest
make test && make daemontest && make mcptest && make menutest
make app
```

`menutest` uses a temporary state directory and real VM: lifecycle capability/receipts,
active-VM release refusal, a real Docker listing, idle stop, release/daemon exit, passive reads,
independent CLI restart and an unexpected guest poweroff. It does not substitute for visually
checking the actual menu, container actions, explicit Quit, app relaunch and idle UI exit.

`make menutest` also runs an opt-in Swift integration suite against a separate real VM,
using MenuEngine itself: start, typed container listing, container start/stop and engine quit.
It uses a disposable BusyBox workload image and the pinned guest/tools already installed on
the host. Normal `make test` skips that VM suite.

To reproduce the UI overhead measurement, find the PID with `pgrep -x dmx-menu`, close the
menu, then run `python3 -I scripts/measure-menu.py PID --seconds 45`. It reuses the engine
benchmark's `ri_phys_footprint`/Mach CPU reader and checks its conversion against getrusage.
This measures the menu process, not the daemon/guest. A single interval is a sample, not a
cross-machine guarantee or a comparison with another container engine.

For local UI diagnostics only, `DMX_MENU_TRACE=1` records native menu-open/close and error-button
callbacks in `$DMX_HOME/run/menu-ui.json`. It does not drive UI or run a timer, and is off by
default. A callback receipt is behavioral evidence, not a substitute for a menu screenshot.

## Local measurements (2026-10-29)

After opening the menu with no containers, the UI process measured **14.92 MiB** and
**0.002103% of one CPU core over 45 seconds**. This is an additional process cost, excluding
the engine/guest. It is a single sample with host pressure recorded, not a universal budget.
External engine stop removed the actual menu process and the daemon exited after its linger.
The error dialog/OK callback and synthetic existing-error refresh were checked; full
menu/submenu screenshots and direct GUI container/Quit clicks remain unverified. See
[measurements, checks and proof limits](measurements/2026-10-29-menu-app.json).
