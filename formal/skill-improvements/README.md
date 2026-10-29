# Formal skill improvements from a reproduced verification miss

The maintainer requested installed skill improvements as part of the v0.3.12 repair.
`improvements.patch` is a portable reviewable delta for `formal-verify` and `tlaplus-model`.
`updated/` holds the final installed files; `files.json` records before/after hashes.
The installed skill directory is not Git-managed, so this repository preserves the delta.
The patch paths are relative to a skills root. Existing unrelated instructions are preserved.

The new focused reference covers semantic observations independent of fix selectors,
independent guard/binding/lifetime/error mutants, new fallible work after side effects,
progress assertions before teardown, and child isolation for destructive FD reuse.
The two entrypoints route fix validation to that reference. Descriptions were shortened to
fit skill-creator's schema; final frontmatter validation passes for both skills.

An independent Opus 5.5 evaluation received the improved instruction bodies and only raw
v0.3.11 source/tests/model/logs, with no prior findings or expected answer. It identified
the observation-oracle dependency, all-off mutation weakness, teardown wakeup, shared-FD
test race, potential post-send acquisition failure, and an extra binding-test blind spot.
The parent's concrete checks confirmed the runtime/model/test failures; in particular,
the original eight tests pass `body(fd)` while the gated child rejects mixed-socket framing.
The final ordinary suite adds a safe alternate-binding assertion and now rejects it too.
The evaluation is read-only reasoning, not an execution proof or broad skill benchmark.
Its reports about absent fixture evidence refer only to the deliberately small fixture.
See `forward-evaluation.md` and `evaluation-metadata.json` for raw verdict and boundaries.
The final YAML description quoting correction followed this behavioral evaluation;
instruction bodies were unchanged. Both final installed versions pass quick_validate.py
using a throwaway virtualenv with PyYAML 6.0.2; no system Python packages were changed.

Behavioral regression evidence is under `formal/evidence/v0.3.12`: the same frozen FD
properties now reject independent guard, binding and early-release mutants; the RPC
model rejects old reply misalignment, ID removal and retirement removal. Source mutants
remove only shutdown or replace `body(copy)` with `body(fd)`; distinct real assertions fail.
See [the causal analysis](../../docs/formal-verification-miss-2026-10-29.md).
