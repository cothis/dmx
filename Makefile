BIN := .build/release/dmx

.PHONY: build install kernel qemu fex guest selftest daemontest mcptest sandboxtest x86test dockertest imagetest pressuretest benchmark test release clean

PREFIX ?= $(HOME)/.local

# Hypervisor.framework refuses to run without this entitlement; ad-hoc signing is enough locally.
build:
	swift build -c release
	codesign --force --sign - --entitlements dmx.entitlements $(BIN)

# Copies dmx to $(PREFIX)/bin (default ~/.local/bin, no sudo). If the launchd agent is installed,
# points it at the new copy. The guest stays in ~/.dmx/guest (`make guest`).
install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/dmx
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

# Assembles a GitHub Release in .build/dist/v$(VERSION) from the guest `make guest` built, and
# pins that guest in Sources/DMXCore/GuestPin.swift. Uploads nothing (docs/release.md).
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.1.0"; exit 1; }
	python3 -I scripts/release.py --version $(VERSION)

clean:
	rm -rf .build
