BIN := .build/release/dmx

.PHONY: build install kernel guest selftest daemontest mcptest x86test test clean

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

# Builds the 16K page guest kernel inside a dmx VM (several minutes). `make guest` needs it.
kernel: build
	python3 -I scripts/build-kernel.py

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

# x86_64 programs through binfmt_misc and qemu: static, dynamic, python3, node, speed against
# native (pinned Alpine x86_64 packages, ~40 MB the first time; about 2 min).
x86test: build
	python3 -I scripts/test-x86.py $(BIN)

# Unit tests that need no VM (the virtio-fs server's path containment).
test:
	swift test

clean:
	rm -rf .build
