BIN := .build/release/dmx

.PHONY: build guest selftest clean

# Virtualization.framework refuses to run without this entitlement; ad-hoc signing is enough locally.
build:
	swift build -c release
	codesign --force --sign - --entitlements dmx.entitlements $(BIN)

guest:
	python3 -I scripts/build-guest.py

selftest: build
	$(BIN) boot --selftest --json

clean:
	rm -rf .build
