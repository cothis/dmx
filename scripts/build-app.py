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
    parser.add_argument("--helper", type=Path, default=ROOT / ".build/release/dmx", help="pre-signed CLI helper")
    parser.add_argument("--no-sign", action="store_true", help="leave Developer ID signing to release.py")
    parser.add_argument("--bin-dir", type=Path, default=Path.home() / ".local/bin")
    args = parser.parse_args()
    output = args.output.resolve()
    version = subprocess.check_output([args.helper, "--version"], text=True).strip()
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
            shutil.copy2(args.helper if name == "dmx" else ROOT / ".build/release" / name, macos / name)
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
        if not args.no_sign:
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
        run(args.helper, "app", "install", "--bundle", output, "--bin-dir", args.bin_dir, "--allow-signing-change")
    else:
        print(output)


if __name__ == "__main__":
    main()
