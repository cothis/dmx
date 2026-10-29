# Preserve the first daemon-suite failure

The first post-review daemon run passed 57/58, failing only the critical balloon footprint
check. Its final resample was 157 MiB with idle 93 MiB (exclusive limit 157). The old test
first waited for a joint balloon/footprint predicate, then discarded that sample and gated
again on a new `status` response. It did not retain the earlier sample or `inflated` boolean.

The actual memory-check path, with measurement-only instrumentation, was isolated and
repeated five times: all memory assertions passed, with qualifying/final footprints
132, 134, 138, 136, 139 MiB and balloons about 682–683 MiB. Logs and the exact diagnostic
script are retained. These runs do not recreate the complete preceding daemon-suite history.

A deterministic replay extracts the actual original assertion block and a same-sample
variant before extra result diagnostics were added. It supplies legal synthetic
consecutive footprints 156/157 MiB (combined with the observed last balloon 483 MiB and
idle 93). This is a synthetic schedule, not a captured pair. The original test falsely
rejects a deadline already satisfied; retaining the qualifying snapshot passes without
changing the footprint/balloon limits or 15 s deadline. Those replay values are not claimed
to be the two measured values of the first failed run. Its missing accepted sample prevents
proving that this exact race caused that run. The last trim age of about one second
supports an early successful wait followed by a failing resample, but this is an inference. No host-environment explanation is asserted.

The fix keeps the final checked tuple via `nonlocal`, reports the wait result/limit, and
uses that tuple for the assertion. Corrected full-suite results and the scoped independent
Opus review accompany the final release record. A green rerun alone was not the diagnosis;
the replay demonstrates a concrete harness defect and five real isolated runs establish
that the actual memory path meets the original joint requirement in those experiments.
