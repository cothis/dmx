# Remaining lifecycle regression checks

Build and run in a throwaway `DMX_HOME`, following the isolation instructions in
[docs/release.md](../../docs/release.md#guardrails-from-mistakes-in-034039). `make guest` writes
the guest under the selected home; do not point release checks at `~/.dmx`.

- `make test`: Swift tests including independent shutdown, listing retry, EMFILE backoff,
  half-close expiry, UDP backpressure/close and sliced stdin framing.
- `make remaininglifecycletest`: byte-credit model; separately entitled VM suites; a child that
  must exit 70 on a blocked host share; real stalled stdin, spawn lock race, first-boot SIGTERM,
  256 MiB APFS ENOSPC/recovery and three Docker unpack crashes. The script detaches its volume.
- `make selftest && make daemontest && make mcptest && make storagetest && make clocktest`:
  normal real VM, Docker/forward/memory integration, MCP stdin cancellation/lossless 1 MiB,
  storage and seven cross-compiled Rust tests, and independent clock synchronization.
- `python3 formal/lifecycle-remaining/check-mutations.py`: temporarily remove five independent
  repairs, require assertions to fail, restore each source in finally, then require all unit
  tests to pass. Use an exclusively owned checkout. This command never mutates release binaries.

The original binary at 0ca4214 fails the stalled-child cleanup, one-second spawn-lock hold and
full-host-disk probes. Baseline artifacts are local build products; logs are kept in evidence/.
The model covers credit/queue safety only. The original natural unpack corruption and a real
unresponsive network mount are not claimed as reproduced: the former is covered by durable
ordering and crash recovery; the latter by a real VM with a deliberately blocked share callback.

When host I/O cannot return, normal cancellation cannot safely free RAM. The default 20 s
teardown watchdog exits the process instead. During startup, the stop grace is 30 s; launchd's
75 s ExitTimeOut covers boot grace, up to 13 s shutdown and 20 s device teardown with margin.
ENOSPC writes wait and retry once per second; status publishes disk_error.code = disk_full.

The v0.4.8 follow-up adds fragmented/unanswered UDP replies, EOF/early-exit input cleanup,
clock setup/deadline and dockerd-generation regressions in `ReleaseReviewTests`/UDP tests.
`make formaltest` also runs isolated Docker HTTP and MCP cancellation FD-reuse probes;
closing an owning connection must never let old raw-fd work touch its successor.
`python3 -I scripts/test-legacy-exec.py <new-dmx> <previous-guest> --require-fallback` tests
failed-download fallback, small input, bounded upgrade failure and SIGINT cleanup. The signed
local/public release suite includes these checks and large lossless input on the newly fetched guest.
