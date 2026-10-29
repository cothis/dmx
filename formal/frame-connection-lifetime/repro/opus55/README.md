# Opus review reproductions

These are code-level review probes for `4aeb48f` / released `13c1257`, not new production
tests or CI. They deliberately fail property assertions on the reviewed implementation.
All destructive FD operations and syscall fault injection run in a separate process.
No VM, signing credential, network download or system-wide installation is needed.

The recorded environment uses Xcode's Swift build layout. `make test` produces the debug
DMXCore object/module below; it is not the signed published executable. After a product
fix these historical probes may stop failing. See the validated review for interpretation.

The commands below are historical and require an exported snapshot of the reviewed
`7b094ab` source (for example, `git archive` to a temporary directory), then a build there.
The current model intentionally has different selectors and the repaired Core has different
failure placement. Use `make formaltest` in the current checkout for present guards.

From the reviewed snapshot root:

```sh
make test
mkdir -p .build/opus55-review
swiftc -parse-as-library -target arm64-apple-macos15.0 \
  -I .build/out/Products/Debug \
  formal/frame-connection-lifetime/repro/opus55/ReviewReproduction.swift \
  .build/out/Products/Debug/DMXCore.o -framework Hypervisor -framework Security \
  -o .build/opus55-review/reproduce
clang -dynamiclib formal/frame-connection-lifetime/repro/opus55/emfile-inject.c \
  -o .build/opus55-review/emfile-inject.dylib

# Control: owner=second, exit 0.
.build/opus55-review/reproduce emfile
# Inject EMFILE only into the second client frame lease: owner=first, exit 1.
DYLD_INSERT_LIBRARIES="$PWD/.build/opus55-review/emfile-inject.dylib" \
  .build/opus55-review/reproduce emfile
# Test-helper interleaving: unrelated file is replaced with a socket, exit 1.
.build/opus55-review/reproduce test-fd-reuse
# Same-archive/different-tag observation: fixture remains at v1, exit 1.
.build/opus55-review/reproduce equal-archive

# Prepare scratch copies, remove the close guard in the model and shutdown in Core,
# then run the unchanged properties and three original tests. Both unexpectedly pass.
python3 formal/frame-connection-lifetime/repro/opus55/check-mutations.py
```

The interposer uses Darwin's `__interpose` mechanism. Calls from its own image bind to
the original `fcntl`; all non-injected calls are forwarded. No real host FD table is
exhausted. The synthetic peer answers actual `AgentClient.call` requests in ID order.
The direct FD-reuse probe reproduces the original test helper's syscall order; it does
not claim a whole Swift Testing process was observed corrupting another test.

Mutation checks need Java plus `TLA2TOOLS` (or `~/.cache/proof-skills/tla2tools.jar`), as
in `formal/README.md`. They only write below `.build/opus55-review-mutations/` and never
modify the real Core, tests or frozen Properties.tla. Existing output is preserved; use
`--out .build/opus55-review-mutations-2` for another run.
