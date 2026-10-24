#!/usr/bin/env python3
"""Assemble a dmx release into a directory: the files to attach to a GitHub Release.

Inputs: the guest `make guest` wrote (default $DMX_HOME/guest), the pinned Alpine packages in
the cache it used, and this checkout. Steps:
  1. dmx-guest-<version>.tar.gz: Image, initramfs.gz, docker.img, manifest.json, plus
     THIRD_PARTY.md and LICENSES/ for what runs in the guest. Byte-identical for the same guest.
  2. Sources/DMXCore/GuestPin.swift: the archive's sha256 and the hash of each boot file, so the
     dmx binary verifies the guest it downloads against itself (GuestStore.swift).
  3. `make build`, then dmx-<version>-darwin-arm64.tar.gz (dmx, LICENSE, THIRD_PARTY.md).
  4. <asset>.sha256 next to each archive, SHA256SUMS, install.sh with the version and the
     binary's sha256 written in, the kernel config, and NOTES.md (release text and source offer).
Nothing is uploaded, tagged or pushed: docs/release.md says how the maintainer publishes it.

Only the Python standard library is used (plus cargo, for the agent's crate licenses).
"""

import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True  # importing build-guest.py must not leave __pycache__ in scripts/
_spec = importlib.util.spec_from_file_location("build_guest", ROOT / "scripts" / "build-guest.py")
guest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guest)
_spec = importlib.util.spec_from_file_location("build_kernel", ROOT / "scripts" / "build-kernel.py")
kernel_build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kernel_build)

REPO = "https://github.com/cothis/dmx"
PIN_FILE = ROOT / "Sources" / "DMXCore" / "GuestPin.swift"
# What the guest archive carries and dmx verifies one by one after unpacking it.
BOOT_FILES = ["Image", "initramfs.gz", "docker.img", "manifest.json"]
ALPINE_APORTS = "https://gitlab.alpinelinux.org/alpine/aports/-/tree"
ALPINE_DISTFILES = "https://distfiles.alpinelinux.org/distfiles/v3.24/"

# License texts from SPDX's license list at a fixed commit, pinned by sha256. Every license id
# in the inventory must be here: an unknown one stops the release so its text gets added.
SPDX = "https://raw.githubusercontent.com/spdx/license-list-data/31ba1a50e5397e00a304dbadc76531740e89ee48/text"
LICENSE_TEXTS = {
    "Apache-2.0": "074e6e32c86a4c0ef8b3ed25b721ca23aca83df277cd88106ef7177c354615ff",
    "BSD-2-Clause": "f32fb3b417a194167cfad068223fc975ba96c5960513a10f66a3c28720aec1df",
    "BSD-3-Clause": "5a93d5831e1297ab10fe643e1a631e83be392896da14ee2951285a79012df69d",
    "GPL-2.0-only": "aaf135472f81c5b4a0dca9367e5bb5e9750032b5bebe5442b36e4c0a47430df3",
    "GPL-2.0-or-later": "aaf135472f81c5b4a0dca9367e5bb5e9750032b5bebe5442b36e4c0a47430df3",
    "LGPL-2.0-or-later": "86dc99d7e5060915ab1dfc1378b7dd351c62088bfa74067e8aa1868c6fdba7d8",
    "LGPL-2.1-only": "5749785c8bdefafcb5d798270ed0a967036fe2ca63dcedade1627565dfef81d2",
    "LGPL-2.1-or-later": "5749785c8bdefafcb5d798270ed0a967036fe2ca63dcedade1627565dfef81d2",
    "Linux-syscall-note": "5bcef4fedbfc08776630e65d5d0d074dd31208037eddb167ca46a9ec4f737764",
    "MIT": "b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5",
    "MPL-2.0": "66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172",
    "Unlicense": "0bdebfeda07d45dada625ae1317c6f833186e798b171d0db640bcf32e92a8240",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def license_ids(expression: str) -> set:
    """SPDX ids in an expression like `GPL-2.0-or-later AND (MIT OR Apache-2.0)`."""
    return {t for t in re.split(r"[\s()]+", expression.replace("/", " OR ")) if t and t not in ("AND", "OR", "WITH")}


def apk_info(path: Path) -> dict:
    with tarfile.open(path, "r:gz", ignore_zeros=True) as tar:
        text = tar.extractfile(".PKGINFO").read().decode()
    info = {}
    for line in text.splitlines():
        key, sep, value = line.partition(" = ")
        if sep and key not in info:
            info[key] = value
    return info


def inventory(cache: Path, kernel_tar: Path) -> list:
    """Everything shipped in the guest with its license and where its source is."""
    items = []

    def alpine(name, version, license, origin, commit, url, repo):
        items.append({
            "name": name, "version": version, "license": license, "origin": origin, "upstream": url,
            "source": f"{ALPINE_APORTS}/{commit}/{repo}/{origin}",
            "distfiles": ALPINE_DISTFILES, "aports_commit": commit, "from": "Alpine Linux 3.24",
        })

    # The minirootfs, minus what build-guest.py drops (apk and its TLS stack).
    with tarfile.open(guest.fetch("minirootfs", cache), "r:gz") as tar:
        db = tar.extractfile("./lib/apk/db/installed").read().decode()
    for block in db.split("\n\n"):
        fields = {}
        for line in block.splitlines():
            key, _, value = line.partition(":")
            fields.setdefault(key, value)
        if "P" in fields and fields["P"] not in guest.DROP_PACKAGES:
            alpine(fields["P"], fields["V"], fields["L"], fields["o"], fields["c"], fields.get("U", ""), "main")
    # Packages build-guest.py takes files from (mke2fs, qemu-x86_64, Docker). The Alpine kernel
    # only boots the VM that builds the dmx kernel; it is not shipped.
    for name, src in guest.SOURCES.items():
        if name in ("minirootfs", "kernel"):
            continue
        info = apk_info(guest.fetch(name, cache))
        repo = src["url"].split("/v3.24/")[1].split("/")[0]
        alpine(info["pkgname"], info["pkgver"], info["license"], info["origin"], info["commit"], info.get("url", ""), repo)

    items.append({
        "name": "linux", "version": guest.DMX_KERNEL_RELEASE, "license": "GPL-2.0-only WITH Linux-syscall-note",
        "upstream": "https://kernel.org/", "source": kernel_build.SOURCE["url"], "source_sha256": kernel_build.SOURCE["sha256"],
        "notes": f"kernel.org source with the page_reporting free-list budget patch in scripts/build-kernel.py ({REPO}); the exact "
                 f"config is kernel-{guest.DMX_KERNEL_RELEASE}.config in this release",
        "from": "dmx",
    })
    items.append({"name": "dmx-agent, /init, dmx-docker", "version": "this release", "license": "Apache-2.0",
                  "upstream": REPO, "source": f"{REPO} (guest/)", "from": "dmx"})
    for crate in agent_crates():
        items.append({**crate, "from": "crates.io (in dmx-agent)"})
    return items


def agent_crates() -> list:
    """Crates linked into dmx-agent: its normal dependencies, without proc-macro crates and what
    only they use (those run at build time)."""
    out = subprocess.run(["cargo", "metadata", "--format-version", "1", "--locked", "--offline",
                          "--filter-platform", guest.AGENT_TARGET],
                         cwd=ROOT / "guest" / "agent", check=True, capture_output=True, text=True).stdout
    meta = json.loads(out)
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = meta["resolve"]["root"]
    seen, todo = set(), [root]
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes[pid]["deps"]:
            normal = any(k["kind"] is None for k in dep["dep_kinds"])
            macro = any("proc-macro" in t["kind"] for t in packages[dep["pkg"]]["targets"])
            if normal and not macro:
                todo.append(dep["pkg"])
    seen.discard(root)
    return sorted(({"name": packages[p]["name"], "version": packages[p]["version"], "license": packages[p]["license"],
                    "upstream": packages[p].get("repository") or "",
                    "source": f"https://crates.io/crates/{packages[p]['name']}/{packages[p]['version']}"}
                   for p in seen), key=lambda c: c["name"])


def swift_packages() -> list:
    """Swift packages linked into the dmx binary, from Package.resolved."""
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    # Only swift-argument-parser today; its license is Apache-2.0 (Apple).
    known = {"swift-argument-parser": "Apache-2.0"}
    items = []
    for pin in pins:
        if pin["identity"] not in known:
            sys.exit(f"no license recorded for Swift package {pin['identity']}; add it to swift_packages()")
        items.append({"name": pin["identity"], "version": pin["state"].get("version", pin["state"]["revision"]),
                      "license": known[pin["identity"]], "upstream": pin["location"],
                      "source": f"{pin['location']}/tree/{pin['state']['revision']}"})
    return items


def fetch_license(spdx_id: str) -> bytes:
    want = LICENSE_TEXTS.get(spdx_id)
    if want is None:
        sys.exit(f"no license text pinned for {spdx_id}; add it to LICENSE_TEXTS in {Path(__file__).name}")
    with urllib.request.urlopen(f"{SPDX}/{spdx_id}.txt") as r:
        data = r.read()
    if sha256(data) != want:
        sys.exit(f"sha256 mismatch for the {spdx_id} license text: got {sha256(data)}")
    return data


def third_party_md(title: str, intro: str, items: list) -> str:
    lines = [f"# {title}", "", intro, "", "| Package | Version | License | Source |", "|---|---|---|---|"]
    for i in items:
        lines.append(f"| {i['name']} | {i['version']} | {i['license']} | {i['source']} |")
    lines.append("")
    return "\n".join(lines)


def deterministic_targz(path: Path, members: list):
    """members: (name, bytes, mode). Fixed order, owner and mtime, so the same inputs give the
    same bytes (and the same sha256 in GuestPin.swift)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tar:
        dirs = set()
        for name, data, mode in sorted(members):
            parts = name.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                d = "/".join(parts[:i])
                if d not in dirs:
                    dirs.add(d)
                    ti = tarfile.TarInfo(d)
                    ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
                    tar.addfile(ti)
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 0
            tar.addfile(ti, io.BytesIO(data))
    path.write_bytes(gzip.compress(buf.getvalue(), compresslevel=9, mtime=0))


def write_pin(tag: str, archive: str, data: bytes, files: dict) -> bool:
    """Writes GuestPin.swift; returns whether it changed."""
    entries = "\n".join(f'            "{name}": "{digest}",' for name, digest in sorted(files.items()))
    text = f"""// Written by scripts/release.py; do not edit by hand. The guest release this dmx downloads when
// ~/.dmx/guest is missing or came from another release.
extension GuestRelease {{
    public static let pinned: GuestRelease? = GuestRelease(
        tag: "{tag}",
        archive: "{archive}",
        bytes: {len(data)},
        sha256: "{sha256(data)}",
        files: [
{entries}
        ]
    )
}}
"""
    old = PIN_FILE.read_text()
    PIN_FILE.write_text(text)
    return old != text


def write_sha256(path: Path) -> str:
    digest = sha256(path.read_bytes())
    Path(f"{path}.sha256").write_text(f"{digest}  {path.name}\n")
    return digest


def main():
    home = Path(os.environ.get("DMX_HOME", Path.home() / ".dmx"))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--version", required=True, help="e.g. 0.1.0; must match `version` in Sources/dmx/DMX.swift")
    ap.add_argument("--out", type=Path, help="default .build/dist/v<version>")
    ap.add_argument("--guest", type=Path, default=home / "guest", help="what `make guest` wrote")
    ap.add_argument("--cache", type=Path, default=home / "cache", help="the cache `make guest` used (read only)")
    ap.add_argument("--no-build", action="store_true", help="package .build/release/dmx as it is")
    args = ap.parse_args()

    tag = f"v{args.version}"
    declared = re.search(r'^let version = "([^"]+)"', (ROOT / "Sources" / "dmx" / "DMX.swift").read_text(), re.M).group(1)
    if declared != args.version:
        sys.exit(f"Sources/dmx/DMX.swift says version {declared}; set it to {args.version} first")
    out = args.out or ROOT / ".build" / "dist" / tag
    out.mkdir(parents=True, exist_ok=True)

    manifest = json.loads((args.guest / "manifest.json").read_text())
    if manifest.get("kernel") != guest.DMX_KERNEL_RELEASE or "docker" not in manifest:
        sys.exit(f"{args.guest} is not a full dmx guest (kernel {manifest.get('kernel')}); run `make guest`")
    kernel_tar = args.cache / f"kernel-{guest.DMX_KERNEL_RELEASE}.tar"
    if sha256(kernel_tar.read_bytes()) != manifest["files"][kernel_tar.name]:
        sys.exit(f"{kernel_tar} is not the kernel in {args.guest}; rebuild the guest with `make guest`")

    # Licenses and the inventory of what the guest ships.
    items = inventory(args.cache, kernel_tar)
    ids = set().union(*(license_ids(i["license"]) for i in items))
    texts = {i: fetch_license(i) for i in sorted(ids)}
    guest_notes = third_party_md(
        "Software in the dmx guest",
        "The dmx guest (Image, initramfs.gz, docker.img) contains these programs. Each runs as a "
        "separate program in the VM under its own license; the texts are in LICENSES/. "
        "Alpine packages are unmodified binaries from Alpine Linux 3.24: their corresponding source "
        f"is the aports directory at the listed commit plus the upstream files it names (mirrored at "
        f"{ALPINE_DISTFILES}). The kernel uses kernel.org source with the free-page-reporting "
        f"budget patch in kernel-{guest.DMX_KERNEL_RELEASE}.build.py and the config in this release. "
        f"Source is also available on request for three years: see NOTES.md of the release.",
        items)

    # 1. The guest archive.
    archive_name = f"dmx-guest-{args.version}.tar.gz"
    members = [(name, (args.guest / name).read_bytes(), 0o644) for name in BOOT_FILES]
    members.append(("THIRD_PARTY.md", guest_notes.encode(), 0o644))
    members += [(f"LICENSES/{i}.txt", t, 0o644) for i, t in texts.items()]
    archive = out / archive_name
    deterministic_targz(archive, members)
    archive_sha = write_sha256(archive)

    # 2. The pin, then 3. the binary that carries it.
    pin_changed = write_pin(tag, archive_name, archive.read_bytes(), {name: sha256(data) for name, data, _ in members if name in BOOT_FILES})
    binary = ROOT / ".build" / "release" / "dmx"
    if not args.no_build:
        subprocess.run(["make", "build"], cwd=ROOT, check=True)
    status = json.loads(subprocess.run([str(binary), "guest", "--json"], check=True, capture_output=True, text=True,
                                       env={**os.environ, "DMX_HOME": str(out / "no-such-home")}).stdout)
    if (status.get("pinned") or {}).get("sha256") != archive_sha:
        sys.exit(f"{binary} does not carry the new pin; build it again (or drop --no-build)")
    entitlements = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(binary)], capture_output=True, text=True).stdout
    if "com.apple.security.hypervisor" not in entitlements:
        sys.exit(f"{binary} is not signed with the hypervisor entitlement; run `make build`")
    swift = swift_packages()
    binary_notes = third_party_md("Software in the dmx binary", "Linked into dmx; the license texts are in LICENSE.", swift)
    binary_name = f"dmx-{args.version}-darwin-arm64.tar.gz"
    deterministic_targz(out / binary_name, [("dmx", binary.read_bytes(), 0o755), ("LICENSE", (ROOT / "LICENSE").read_bytes(), 0o644),
                                            ("THIRD_PARTY.md", binary_notes.encode(), 0o644)])
    binary_sha = write_sha256(out / binary_name)

    # 4. Everything else on the release page.
    install = (ROOT / "scripts" / "install.sh").read_text()
    install = install.replace('release_version=""', f'release_version="{args.version}"', 1)
    install = install.replace('release_sha256=""', f'release_sha256="{binary_sha}"', 1)
    (out / "install.sh").write_text(install)
    with tarfile.open(kernel_tar) as tar:
        (out / f"kernel-{guest.DMX_KERNEL_RELEASE}.config").write_bytes(tar.extractfile("boot/config").read())
    (out / f"kernel-{guest.DMX_KERNEL_RELEASE}.build.py").write_bytes((ROOT / "scripts/build-kernel.py").read_bytes())
    (out / "third-party.json").write_text(json.dumps({"guest": items, "dmx": swift}, indent=2) + "\n")
    (out / "NOTES.md").write_text(release_notes(args.version, archive_name, binary_name, items))
    assets = sorted(p for p in out.iterdir() if p.is_file() and p.name != "SHA256SUMS" and not p.name.endswith(".sha256"))
    (out / "SHA256SUMS").write_text("".join(f"{sha256(p.read_bytes())}  {p.name}\n" for p in assets))

    print(json.dumps({"ok": True, "out": str(out), "tag": tag, "pin_changed": pin_changed,
                      "guest": {"name": archive_name, "bytes": archive.stat().st_size, "sha256": archive_sha},
                      "binary": {"name": binary_name, "bytes": (out / binary_name).stat().st_size, "sha256": binary_sha},
                      "licenses": sorted(texts), "packages": len(items)}))
    if pin_changed:
        print(f"GuestPin.swift changed: commit it (and the version) before tagging {tag}, so the tag builds this binary",
              file=sys.stderr)


def release_notes(version: str, archive: str, binary: str, items: list) -> str:
    gpl = sorted({f"{i['name']} {i['version']}" for i in items if "GPL" in i["license"]})
    return f"""# dmx {version}

Install (macOS 15 or later on Apple Silicon; no Xcode, Python or Rust needed):

```sh
curl -fsSL {REPO}/releases/download/v{version}/install.sh | sh
```

The first boot downloads the Linux guest ({archive}) and checks it against the sha256 built
into dmx; `dmx guest fetch` does it ahead of time.

## Assets

- `{binary}`: the dmx binary (ad-hoc signed), its license and third-party notices
- `{archive}`: the Linux guest: kernel, initramfs, Docker image, licenses and THIRD_PARTY.md
- `install.sh`: installs dmx into ~/.local/bin after checking the tarball's sha256
- `kernel-{guest.DMX_KERNEL_RELEASE}.config`: the configuration the guest kernel was built with
- `kernel-{guest.DMX_KERNEL_RELEASE}.build.py`: pinned inputs and the exact kernel source patch
- `third-party.json`: every package in the guest and the binary, with license and source
- `SHA256SUMS`, `*.sha256`: checksums

## Source code

dmx is Apache-2.0; its source is this tag. The guest contains programs under the GPL and LGPL,
among them {", ".join(gpl)}. The Alpine Linux 3.24 packages are unmodified
(corresponding source: the Alpine aports directory at the commit listed in THIRD_PARTY.md and the
upstream files it names). The kernel uses kernel.org Linux source with the reporting-budget
patch in the build script and the config above.
For three years from this release, the maintainer provides the complete corresponding source of
these programs on request (open an issue at {REPO}/issues), for no more than the cost of
distribution.
"""


if __name__ == "__main__":
    main()
