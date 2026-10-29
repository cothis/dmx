#!/usr/bin/env python3
"""Prove an installed Developer ID rejects foreign helper code before executing it."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CLI = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
SIGNED = Path(sys.argv[2] if len(sys.argv) > 2 else ".build/signed/dmx.app").resolve()
version = subprocess.check_output([CLI, "--version"], text=True).strip()
details = subprocess.run(["codesign", "-dvv", SIGNED], capture_output=True, text=True).stderr
assert "Authority=Developer ID Application" in details
# The invoking CLI intentionally has no publisher identity, exercising the destination anchor.
assert "TeamIdentifier=not set" in subprocess.run(["codesign", "-dvv", CLI], capture_output=True, text=True).stderr
with tempfile.TemporaryDirectory(prefix="dmx-identity-", dir="/tmp") as scratch:
    root = Path(scratch); installed = root / "installed.app"; incoming = root / "incoming.app"
    shutil.copytree(SIGNED, installed); shutil.copytree(SIGNED, incoming)
    marker = root / "helper-was-executed"
    source = root / "probe.c"
    source.write_text('#include <stdio.h>\nint main(void) { FILE *f=fopen(' + json.dumps(str(marker)) + ',"w"); if(f){fputs("executed",f);fclose(f);} puts(' + json.dumps(version) + '); return 0; }\n')
    helper = incoming / "Contents/MacOS/dmx"
    subprocess.run(["clang", source, "-o", helper], check=True, capture_output=True)
    for target in [helper, incoming]:
        subprocess.run(["codesign", "--force", "--sign", "-", target], check=True, capture_output=True)
    args = [CLI, "app", "install", "--bundle", incoming, "--directory", installed, "--json"]
    denied = subprocess.run(args, capture_output=True, text=True, timeout=30)
    failure = json.loads(denied.stdout)
    assert denied.returncode != 0 and failure["error"]["code"] == "update_unsigned", failure
    assert not marker.exists(), "the rejected helper executed before the identity check"
    assert "Authority=Developer ID Application" in subprocess.run(["codesign", "-dvv", installed], capture_output=True, text=True).stderr
    # Positive control: this is runnable, correctly sealed input, not a fixture rejected for
    # an unrelated reason. Only the explicit source-signing exception permits it to execute.
    allowed = subprocess.run([*args, "--allow-signing-change"], capture_output=True, text=True, timeout=30)
    assert allowed.returncode == 0 and marker.read_text() == "executed", (allowed.stdout, allowed.stderr)
print(json.dumps({"ok": True, "installed_identity_checked_before_execution": True,
                  "signed_install_preserved_on_refusal": True, "explicit_exception_positive_control": True}, indent=2))
