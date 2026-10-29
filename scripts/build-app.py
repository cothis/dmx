#!/usr/bin/env python3
"""Package the native, manually launched menu app. No login item is installed."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    subprocess.run(list(map(str, args)), check=True, cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/dmx.app")
    parser.add_argument("--install", action="store_true", help="copy to ~/Applications/dmx.app")
    args = parser.parse_args()
    output = args.output.resolve()
    version = subprocess.check_output([ROOT / ".build/release/dmx", "--version"], text=True).strip()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dmx-app-", dir=output.parent) as scratch:
        scratch = Path(scratch)
        app = scratch / "dmx.app"
        contents = app / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        for name in ("dmx", "dmx-menu"):
            shutil.copy2(ROOT / ".build/release" / name, macos / name)
        shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
        shutil.copy2(ROOT / ".build/checkouts/swift-argument-parser/LICENSE.txt", resources / "ArgumentParser-LICENSE.txt")
        info = {
            "CFBundleIdentifier": "io.github.cothis.dmx.menu",
            "CFBundleName": "dmx",
            "CFBundleDisplayName": "dmx",
            "CFBundleExecutable": "dmx-menu",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundleIconFile": "AppIcon",
            "LSMinimumSystemVersion": "15.0",
            "LSUIElement": True,
            "LSApplicationCategoryType": "public.app-category.developer-tools",
            "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        iconset = scratch / "AppIcon.iconset"
        run("swift", ROOT / "scripts/draw-app-icon.swift", iconset)
        run("iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns")
        run("codesign", "--force", "--sign", "-", "--entitlements", ROOT / "dmx.entitlements", macos / "dmx")
        run("codesign", "--force", "--sign", "-", macos / "dmx-menu")
        run("codesign", "--force", "--sign", "-", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        # Never write through a running executable's pages. The old bundle remains usable
        # until the new one has been completely built and verified.
        previous = output.with_name(output.name + ".previous")
        if previous.exists():
            raise RuntimeError(f"preserving existing {previous}; move it before replacing this app")
        if output.exists():
            output.rename(previous)
        try:
            app.rename(output)
        except BaseException:
            if previous.exists():
                previous.rename(output)
            raise
        if previous.exists():
            shutil.rmtree(previous)
    if args.install:
        destination = Path.home() / "Applications/dmx.app"
        destination.parent.mkdir(exist_ok=True)
        if output == destination:
            raise RuntimeError("build output must differ from the installed app")
        staging = destination.with_name(".dmx.app.new")
        if staging.exists():
            raise RuntimeError(f"preserving existing {staging}; move it before installing")
        shutil.copytree(output, staging)
        old = destination.with_name(".dmx.app.previous")
        if old.exists():
            raise RuntimeError(f"preserving existing {old}; move it before installing")
        if destination.exists():
            destination.rename(old)
        try:
            staging.rename(destination)
        except BaseException:
            if old.exists():
                old.rename(destination)
            raise
        if old.exists():
            shutil.rmtree(old)
        print(destination)
    else:
        print(output)


if __name__ == "__main__":
    main()
