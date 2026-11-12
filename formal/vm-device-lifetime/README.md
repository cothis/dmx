# VM lifetime checks

- `make lifecycletest`: bounded model, entitled Machine tests, and four real 2 GiB release/stop/start cycles.
- `python3 formal/vm-device-lifetime/repro/check-code.py --mutations`: independently remove the
  alive guard, failed-init cleanup, failed-start cleanup, and tick epoch guard, require failures,
  restore the source, and rerun all four Machine tests. Run only on a clean, exclusively owned
  checkout: this command temporarily edits the named implementation files, restoring in finally.
- `swift test --filter DeviceStopTests`: deterministic net queue stop barrier (fails on a0a7922).

The entitled test runner is built locally against Xcode's Testing framework. It loads the SwiftPM
bundle and owns the Hypervisor entitlement; signing the bundle alone does not grant its loader
Hypervisor access. The tests share the pinned guest read-only and never open a user data disk.
See SCOPE.md, CORRESPONDENCE.md and evidence/ for bounds, traces and logs.
