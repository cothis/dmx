#!/usr/bin/env python3
"""Whether macOS's local network permission survives an update at the same path, for an engine inside
an app and for a standalone CLI, each started by launchd. A small signed probe stands in for dmx so
that the Mach-O UUID is new on every run: updating the installed dmx to a release whose UUID a test
already got allowed proves nothing.

macOS keeps the answer by signing identifier and path, so the paths here never change. The first run
on a Mac raises two prompts for the owner to allow; later runs ask nothing, even after /private/tmp
was emptied. Keep a prompt for another copy from being open: it blocks every copy until answered.

    python3 -I scripts/test-local-network-update.py [codesigning identity]

Needs an Apple-issued identity (ad-hoc signing makes every build a new program to macOS).
"""

import ctypes
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path("/private/tmp/dmxlnp")
PROBE = Path(__file__).resolve().parent / "fixtures/local-network-probe.c"
DOMAIN = f"gui/{os.getuid()}"
SETTINGS = Path("/Library/Preferences/com.apple.networkextension.plist")
ANSWER_WAIT = 600
# The daemon checks again 3 s after a refusal; an update has to be through by then.
RECOVERY_LIMIT = 3
RENAME_SWAP = 2
checks = []


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})


def run(*args):
    subprocess.run([str(a) for a in args], check=True, capture_output=True)


def identity():
    if len(sys.argv) > 1:
        return sys.argv[1]
    listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    found = re.search(r"\b([0-9A-F]{40})\b", listing)
    if not found:
        sys.exit("no codesigning identity; pass one, or create an Apple Development certificate in Xcode")
    return found.group(1)


def gateway():
    routes = subprocess.run(["netstat", "-rn", "-f", "inet"], capture_output=True, text=True).stdout
    for line in routes.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[0] == "default" and re.match(r"en\d+$", fields[-1]) and re.match(r"[\d.]+$", fields[1]):
            return fields[1]
    sys.exit("no LAN default route: join a network and run this again")


def allowed_rules(signing_id):
    """The paths macOS has an answer for, under this identifier."""
    archive = plistlib.loads(SETTINGS.read_bytes())["$objects"]
    value = lambda ref: archive[ref.data] if isinstance(ref, plistlib.UID) else ref
    return sorted(value(o["Path"]) for o in archive
                  if isinstance(o, dict) and "DenyMulticast" in o and value(o.get("SigningIdentifier")) == signing_id)


class Layout:
    """The two ways an installed dmx is replaced: the whole app is exchanged, a CLI is renamed over."""

    def __init__(self, kind, sign_as):
        self.kind = kind
        self.signing_id = "dmxlnp-plain-engine" if kind == "app" else "dmxlnp-cli"
        self.sign_as = sign_as
        self.label = f"io.github.cothis.dmxlnp.check.{kind}"
        self.log = ROOT / "logs" / f"{kind}.log"
        self.target = ROOT / "plain/dmxlnp-plain.app" if kind == "app" else ROOT / "cli/dmxlnp-cli"
        self.engine = self.target / "Contents/MacOS/dmxlnp-plain-engine" if kind == "app" else self.target

    def compile(self, output, tag):
        run("clang", "-O1", f'-DTAG="{tag}"', PROBE, "-o", output)

    def sign(self, path, signing_id=None):
        identifier = ["--identifier", signing_id] if signing_id else []
        run("codesign", "--force", "--options", "runtime", "--timestamp=none", *identifier, "--sign", self.sign_as, path)

    def build(self, destination, tag):
        if self.kind == "cli":
            self.compile(destination, tag)
            self.sign(destination, self.signing_id)
            return
        macos = destination / "Contents/MacOS"
        macos.mkdir(parents=True)
        (destination / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "io.github.cothis.dmxlnp.plain", "CFBundleExecutable": "dmxlnp-plain",
            "CFBundleName": "dmxlnp-plain", "CFBundlePackageType": "APPL", "LSUIElement": True,
            "NSLocalNetworkUsageDescription": "dmx's local network permission check.",
        }))
        self.compile(macos / "dmxlnp-plain", tag + "-menu")
        self.compile(macos / "dmxlnp-plain-engine", tag)
        self.sign(macos / "dmxlnp-plain-engine", self.signing_id)
        self.sign(macos / "dmxlnp-plain")
        self.sign(destination)

    def install(self, tag, lan):
        self.target.parent.mkdir(parents=True, exist_ok=True)
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.build(self.target, tag)
        plist = ROOT / f"{self.label}.plist"
        plist.write_bytes(plistlib.dumps({
            "Label": self.label, "ProgramArguments": [str(self.engine), lan], "RunAtLoad": True, "ProcessType": "Interactive",
            "StandardOutPath": str(self.log), "StandardErrorPath": str(self.log),
        }))
        run("launchctl", "bootstrap", DOMAIN, plist)

    def update(self, tag):
        staged = self.target.with_name(".staged" + self.target.suffix)
        self.build(staged, tag)
        if self.kind == "cli":
            os.rename(staged, self.target)
        else:
            if ctypes.CDLL(None).renamex_np(str(staged).encode(), str(self.target).encode(), RENAME_SWAP) != 0:
                raise OSError("renamex_np failed")
            shutil.rmtree(staged)
        run("launchctl", "kickstart", "-k", f"{DOMAIN}/{self.label}")

    def states(self, tag):
        """(seconds since the epoch, allowed) for each probe of this build."""
        found = []
        for line in (self.log.read_text() if self.log.exists() else "").splitlines():
            fields = line.split(" ", 2)
            if len(fields) == 3 and fields[1] == tag:
                found.append((float(fields[0]), fields[2].startswith("multicast=ok")))
        return found

    def uuid(self):
        return subprocess.run(["dwarfdump", "--uuid", self.engine], capture_output=True, text=True).stdout.split()[1]

    def wait_allowed(self, tag, limit):
        end = time.time() + limit
        while time.time() < end:
            states = self.states(tag)
            if states and states[-1][1]:
                return states
            time.sleep(0.25)
        return self.states(tag)


def main():
    sign_as, lan = identity(), gateway()
    layouts = [Layout("app", sign_as), Layout("cli", sign_as)]
    shutil.rmtree(ROOT, ignore_errors=True)
    results = {}
    try:
        for layout in layouts:
            tag = f"{layout.kind}-{uuid.uuid4().hex}"
            layout.install(tag, lan)
            print(f"waiting for {layout.signing_id}: allow it if macOS asks", file=sys.stderr)
            states = layout.wait_allowed(tag, ANSWER_WAIT)
            check(f"{layout.kind}_allowed_before_update", states and states[-1][1], "no answer" if not states or not states[-1][1] else "")
            if not states or not states[-1][1]:
                continue
            answers = allowed_rules(layout.signing_id)
            seen = {layout.uuid()}
            runs = []
            for number in (1, 2):
                time.sleep(2)
                tag = f"{layout.kind}-{uuid.uuid4().hex}"
                layout.update(tag)
                new = layout.uuid()
                check(f"{layout.kind}_update_{number}_new_uuid", new not in seen, new)
                seen.add(new)
                states = layout.wait_allowed(tag, RECOVERY_LIMIT + 2)
                recovered = bool(states) and states[-1][1]
                # Second-resolution stamps: a refusal then a pass can read 1 s apart even when it took less.
                took = states[-1][0] - states[0][0] if recovered else None
                check(f"{layout.kind}_update_{number}_recovers", recovered and took <= RECOVERY_LIMIT, {"first_probe_allowed": bool(states) and states[0][1], "seconds": took})
                runs.append({"first_probe_allowed": bool(states) and states[0][1], "seconds_to_allowed": took})
            check(f"{layout.kind}_needed_no_new_answer", allowed_rules(layout.signing_id) == answers, answers)
            results[layout.kind] = runs
    finally:
        for layout in layouts:
            subprocess.run(["launchctl", "bootout", f"{DOMAIN}/{layout.label}"], capture_output=True)
        shutil.rmtree(ROOT, ignore_errors=True)
    ok = all(c["ok"] for c in checks)
    print(json.dumps({"ok": ok, "results": results, "checks": checks}, indent=2))
    sys.exit(0 if ok else 1)


main()
