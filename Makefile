BIN := .build/release/dmx

.PHONY: build kernel guest selftest clean

# Hypervisor.framework refuses to run without this entitlement; ad-hoc signing is enough locally.
build:
	swift build -c release
	codesign --force --sign - --entitlements dmx.entitlements $(BIN)

# Builds the 16K page guest kernel inside a dmx VM (several minutes). `make guest` needs it.
kernel: build
	python3 -I scripts/build-kernel.py

guest:
	python3 -I scripts/build-guest.py

selftest: build
	$(BIN) boot --selftest --json

clean:
	rm -rf .build
