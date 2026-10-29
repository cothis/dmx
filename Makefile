BIN := .build/release/dmx

.PHONY: build app install-app apptest menutest install kernel qemu fex guest selftest daemontest mcptest sandboxtest x86test dockertest imagetest javatest storagetest pressuretest benchmark test formaltest release clean

PREFIX ?= $(HOME)/.local

# Hypervisor.framework refuses to run without this entitlement; ad-hoc signing is enough locally.
build:
	swift build -c release
	codesign --force --sign - --entitlements dmx.entitlements $(BIN)

# A local ad-hoc-signed app; public Developer ID signing/notarization is a release step.
app: build
	python3 -I scripts/build-app.py

# One verified app owns the CLI too; replacement preserves existing running VM processes.
install-app: build
	python3 -I scripts/build-app.py --install --bin-dir "$(PREFIX)/bin"

apptest: app
	DMX_APP_TEST_BUNDLE="$(abspath .build/dmx.app)" swift test --filter AppInstallationTests
	python3 -I scripts/test-app-install.py $(BIN) .build/dmx.app

# Copies dmx to $(PREFIX)/bin (default ~/.local/bin, no sudo). If the launchd agent is installed,
# points it at the new copy. The guest stays in ~/.dmx/guest (`make guest`).
install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/.dmx.new
	mv -f $(PREFIX)/bin/.dmx.new $(PREFIX)/bin/dmx
	@if [ -f $(HOME)/Library/LaunchAgents/io.github.cothis.dmx.plist ]; then $(PREFIX)/bin/dmx install; fi

# Builds the trimmed 4K page guest kernel inside a dmx VM (several minutes). `make guest` needs it.
kernel: build
	python3 -I scripts/build-kernel.py

# Builds qemu-x86_64 (pinned QEMU source, Alpine's patches, a guest-base fix) inside a dmx VM.
# `make guest` needs it.
qemu: build
	python3 -I scripts/build-qemu.py

# Builds FEX-Emu, the default x86_64 emulator (pinned source, a dmx patch, static musl), inside a
# dmx VM. `make guest` needs it.
fex: build
	python3 -I scripts/build-fex.py

guest:
	python3 -I scripts/build-guest.py

selftest: build
	$(BIN) boot --selftest --json

# The daemon, its socket and exec paths, idle stop, in a throwaway DMX_HOME (about 45 s).
daemontest: build
	python3 -I scripts/test-daemon.py $(BIN)

# Passive receipts, unexpected shutdown and idle release after a real Docker listing.
menutest: build
	python3 -I scripts/test-menu.py $(BIN)
	DMX_MENU_VM=1 DMX_MENU_EXECUTABLE="$(abspath $(BIN))" swift test --filter MenuEngineVMTests

# `dmx mcp` driven over pipes like an MCP client: tools, output limits, timeouts (about 6 s).
mcptest: build
	python3 -I scripts/test-mcp.py $(BIN)

# Sandboxes through `dmx mcp`: policies, egress, checkpoints, forks, logs, TTL (needs the
# internet; about 2 min on a new data disk).
sandboxtest: build
	python3 -I scripts/test-sandbox.py $(BIN)

# x86 programs through binfmt_misc and FEX/QEMU: static, dynamic, python3, node, speed against
# native (pinned Alpine x86_64 packages, ~40 MB the first time; about 2 min).
x86test: build
	python3 -I scripts/test-x86.py $(BIN)

# The stock docker CLI, Compose and Buildx (dmx's own copies, `dmx tools install`) against dmx,
# in a throwaway DMX_HOME (needs the internet; a few minutes).
dockertest: build
	python3 -I scripts/test-docker.py $(BIN)

# Workloads in nine digest-pinned images, arm64/amd64 and six available 386 images; no skipped failures.
imagetest: build
	python3 -I scripts/test-images.py $(BIN)

# HotSpot repeatedly compiles and patches x86 code; one image run misses intermittent failures.
javatest: build
	python3 -I scripts/test-images.py $(BIN) --image java --platform linux/amd64 --repeat 100

# Diagnostic overflow/migration, Docker log defaults, failed-start retry, guest Rust unit tests.
storagetest: build
	python3 -I scripts/test-storage.py $(BIN)

# Guest memory and disk integrity while the Mac swaps (an incompressible hog of 3/4 of RAM,
# boots that run e2fsck -fy). Not a release check: the Mac slows down for a few minutes.
pressuretest: build
	python3 -I scripts/test-pressure.py $(BIN)

# Local dmx baseline. Cross-engine comparison needs matched settings and a quiet host;
# scripts/benchmark.py can also drive an existing engine (docs/benchmark.md).
benchmark: build
	python3 -I scripts/benchmark.py $(BIN)

# Unit tests that need no VM (the virtio-fs server's path containment).
test:
	swift test

# Bounded safety models plus real Core FD/EMFILE probes (Java + cached TLA+ jar required).
# Child-only forced FD reuse never shares the unit runner's descriptor namespace.
formaltest: test
	python3 formal/check.py
	python3 formal/frame-connection-lifetime/repro/check-code.py

# Assembles a GitHub Release in .build/dist/v$(VERSION) from the guest `make guest` built, and
# pins that guest in Sources/DMXCore/GuestPin.swift. Uploads nothing (docs/release.md).
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.1.0"; exit 1; }
	python3 -I scripts/release.py --version $(VERSION)

clean:
	rm -rf .build
