# Remaining lifecycle regression checks

Run `make build && make guest` first. The installed app and user data disk are never replaced.

- `make test`: Swift tests including independent shutdown, listing retry, EMFILE backoff,
  half-close expiry, UDP backpressure/close and sliced stdin framing.
- `make remaininglifecycletest`: byte-credit model; separately entitled VM suites; a child that
  must exit 70 on a blocked host share; real stalled stdin, spawn lock race, first-boot SIGTERM,
  256 MiB APFS ENOSPC/recovery and three Docker unpack crashes. The script detaches its volume.
- `make selftest && make daemontest && make mcptest && make storagetest && make clocktest`:
  normal real VM, Docker/forward/memory integration, MCP stdin cancellation/lossless 1 MiB,
  storage and six cross-compiled Rust tests, and independent clock synchronization.
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
