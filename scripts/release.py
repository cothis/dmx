#!/usr/bin/env python3
"""Assemble a dmx release into a directory: the files to attach to a GitHub Release.

Inputs: the guest `make guest` wrote (default $DMX_HOME/guest), the pinned Alpine packages in
the cache it used, and this checkout. Steps:
  1. dmx-guest-<version>.tar.gz: Image, initramfs.gz, docker.img, manifest.json, plus
     THIRD_PARTY.md and LICENSES/ for what runs in the guest. Byte-identical for the same guest.
  2. Sources/DMXCore/GuestPin.swift: the archive's sha256 and the hash of each boot file, so the
     dmx binary verifies the guest it downloads against itself (GuestStore.swift).
  3. `make build`, a copy signed with a Developer ID and notarized by Apple (sign_and_notarize,
     settings in ~/.dmx-signing/release.json; `--ad-hoc` skips it), then
     dmx-<version>-darwin-arm64.tar.gz (dmx, LICENSE, THIRD_PARTY.md).
  4. dmx-sources-<version>.tar: the complete corresponding source of the guest (source_bundle).
  5. <asset>.sha256 next to each archive, SHA256SUMS, install.sh with the version and the
     binary's sha256 written in, the kernel config, and NOTES.md (release text).
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
import urllib.parse
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
_spec = importlib.util.spec_from_file_location("build_qemu", ROOT / "scripts" / "build-qemu.py")
qemu_build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(qemu_build)
_spec = importlib.util.spec_from_file_location("build_fex", ROOT / "scripts" / "build-fex.py")
fex_build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fex_build)

REPO = "https://github.com/cothis/dmx"
PIN_FILE = ROOT / "Sources" / "DMXCore" / "GuestPin.swift"
# Written by hand per release and kept in the repository; folded into NOTES.md.
NOTES_DIR = ROOT / "docs" / "release-notes"
# What the guest archive carries and dmx verifies one by one after unpacking it.
BOOT_FILES = ["Image", "initramfs.gz", "docker.img", "manifest.json"]
ALPINE_APORTS = "https://gitlab.alpinelinux.org/alpine/aports/-/tree"
ALPINE_DISTFILES = "https://distfiles.alpinelinux.org/distfiles/v3.24/"

# License texts from SPDX's license list at a fixed commit, pinned by sha256. Every license id
# in the inventory must be here: an unknown one stops the release so its text gets added.
SPDX = "https://raw.githubusercontent.com/spdx/license-list-data/31ba1a50e5397e00a304dbadc76531740e89ee48/text"
LICENSE_TEXTS = {
    "0BSD": "e3f18c71e10d673590eb9856c1d79dd3b4b0d65404efb5e8584dbede7edd608b",
    "Apache-2.0": "074e6e32c86a4c0ef8b3ed25b721ca23aca83df277cd88106ef7177c354615ff",
    "BSD-2-Clause": "f32fb3b417a194167cfad068223fc975ba96c5960513a10f66a3c28720aec1df",
    "BSD-3-Clause": "5a93d5831e1297ab10fe643e1a631e83be392896da14ee2951285a79012df69d",
    "BSL-1.0": "84c6ef3ea9e3254a54d0acf5d3e0c61ae011b8fef7dd6940591cf060e6380a8f",
    "GPL-2.0-only": "aaf135472f81c5b4a0dca9367e5bb5e9750032b5bebe5442b36e4c0a47430df3",
    "GPL-2.0-or-later": "aaf135472f81c5b4a0dca9367e5bb5e9750032b5bebe5442b36e4c0a47430df3",
    "GPL-3.0-or-later": "fb981668c18a279e285fc4d83fba1e836cc84dd4daa73c9697d3cfd2d8aca6e0",
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
    kernel_build.CACHE = cache  # its fetch() reads the build scripts' pinned inputs from here
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
    # Packages build-guest.py takes files from (mke2fs, Docker). The Alpine kernel
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
        "notes": f"kernel.org source with the page_reporting free-list budget patch in scripts/build-kernel.py ({REPO}) and "
                 f"Asahi Linux's TSO memory model patches ({kernel_build.ASAHI}/<commit>.patch, listed there); the exact "
                 f"config is kernel-{guest.DMX_KERNEL_RELEASE}.config in this release",
        "from": "dmx",
    })
    items.append({
        "name": "qemu-x86_64", "version": guest.DMX_QEMU.removeprefix("qemu-x86_64-"), "license": "GPL-2.0-only AND LGPL-2.1-only",
        "upstream": "https://qemu.org/", "source": qemu_build.SOURCE["url"], "source_sha256": qemu_build.SOURCE["sha256"],
        "notes": f"qemu.org source with Alpine's patches (aports {qemu_build.APORTS_COMMIT}, community/qemu) and the guest-base "
                 f"patch, built as in {guest.DMX_QEMU}.build.py ({REPO})",
        "from": "dmx",
    })
    # Libraries linked into the static qemu-x86_64, from the toolchain packages it was built with.
    for pin in qemu_build.TOOLCHAIN:
        info = apk_info(kernel_build.fetch(kernel_build.apk_url(pin), qemu_build.TOOLCHAIN[pin]))
        if info["pkgname"] in qemu_build.STATIC_LINKED:
            repo = pin.rpartition("/")[0] or "main"
            alpine(f"{info['pkgname']} (in qemu-x86_64)", info["pkgver"], info["license"], info["origin"], info["commit"],
                   info.get("url", ""), repo)
    # FEX-Emu and the libraries in its tree or submodules that end up in the binary.
    fex_source = fex_build.source_url(*fex_build.SOURCES["."][:2])
    items.append({
        "name": "FEX-Emu", "version": fex_build.VERSION, "license": "MIT", "upstream": "https://fex-emu.com/",
        "source": fex_source, "source_sha256": fex_build.SOURCES["."][2],
        "notes": f"with dmx's patch, built as in {guest.DMX_FEX}.build.py ({REPO}). Its tree also carries SoftFloat-3e "
                 "(BSD-3-Clause), tiny-json (MIT) and, in the x87 path, ten files of Stephen L. Moshier's Cephes math "
                 "library (the 128-bit set: sinll, tanll, atanll, exp2ll, log2ll, floorll, polevll, constll, mtherr and "
                 "FEX's Impl.cpp), Copyright 1984-1995 Stephen L. Moshier, releases 2.0 to 2.3. Netlib's own terms "
                 "(https://www.netlib.org/cephes/readme) are \"What you see here may be used freely but it comes with no "
                 "support or guarantee\"; the author gave written permission to license it as BSD (\"BSD license is fine, "
                 "modification is OK\", quoted in full in External/cephes/LICENSE in the source bundle)",
        "from": "dmx",
    })
    licenses = {"External/fmt": "MIT", "External/xxhash": "BSD-2-Clause", "External/range-v3": "BSL-1.0",
                "External/unordered_dense": "MIT", "External/rpmalloc": "0BSD", "External/drm-headers": "MIT",
                "Source/Common/cpp-optparse": "MIT"}
    for path, (repo, commit, digest) in fex_build.SOURCES.items():
        if path != ".":
            items.append({"name": f"{repo.split('/')[1]} (in FEX-Emu)", "version": commit[:12], "license": licenses[path],
                          "upstream": f"https://github.com/{repo}", "source": fex_build.source_url(repo, commit),
                          "source_sha256": digest, "from": "dmx"})
    for pin in fex_build.TOOLCHAIN:
        info = apk_info(kernel_build.fetch(kernel_build.apk_url(pin), fex_build.TOOLCHAIN[pin]))
        if info["pkgname"] in fex_build.STATIC_LINKED:
            repo = pin.rpartition("/")[0] or "main"
            alpine(f"{info['pkgname']} (in FEX-Emu)", info["pkgver"], info["license"], info["origin"], info["commit"],
                   info.get("url", ""), repo)
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


def download(url: str, path: Path, sha: str = None, algo: str = "sha256") -> Path:
    """url to path unless it is there; checked against sha (hex, of `algo`) when given."""
    if not path.exists():
        print(f"download {url}", file=sys.stderr)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".part")
        with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        tmp.rename(path)
    if sha:
        h = hashlib.new(algo)
        with open(path, "rb") as f:
            while chunk := f.read(1 << 20):
                h.update(chunk)
        if h.hexdigest() != sha:
            path.unlink()
            sys.exit(f"{algo} mismatch for {path.name} from {url}")
    return path


def source_bundle(path: Path, items: list, cache: Path, store: Path, kernel_tar: Path, version: str):
    """The complete corresponding source of the guest, as one uncompressed tar (its contents are
    compressed already), so the release page itself carries it (GPL-2.0 section 3, last
    paragraph). Each Alpine package: its aports directory at the commit it was built from plus
    every upstream file the APKBUILD's sha512sums names, from Alpine's distfiles mirror and
    checked against those sums; nothing from the APKBUILD is executed. Then dmx's kernel,
    qemu-x86_64 and FEX-Emu: upstream tarballs, patches, config and the build scripts that apply them."""
    members = []  # (name in the tar, file on disk or bytes)
    dirs = sorted({(i["aports_commit"], i["source"].split("/")[-2], i["origin"]) for i in items if "aports_commit" in i})
    for commit, repo, origin in dirs:
        archive = download(f"https://gitlab.alpinelinux.org/alpine/aports/-/archive/{commit}/aports-{commit}.tar.gz?path={repo}/{origin}",
                           store / f"aports-{commit[:12]}-{repo}-{origin}.tar.gz")
        prefix = f"aports-{commit}-{repo}-{origin}/{repo}/{origin}/"
        local = {}
        with tarfile.open(archive, "r:gz") as tar:
            for m in tar.getmembers():
                if m.isfile() and m.name.startswith(prefix) and "/" not in m.name[len(prefix):]:
                    local[m.name[len(prefix):]] = tar.extractfile(m).read()
        if "APKBUILD" not in local:
            sys.exit(f"no APKBUILD in aports {commit} {repo}/{origin}")
        sums = re.search(r'^sha512sums="(.*?)"', local["APKBUILD"].decode(), re.M | re.S)
        for line in (sums.group(1).strip().splitlines() if sums else []):
            digest, name = line.split(None, 1)
            if name in local:
                if hashlib.sha512(local[name]).hexdigest() != digest:
                    sys.exit(f"aports {repo}/{origin}: {name} does not match its sha512sums entry")
                continue
            local[name] = download(f"{ALPINE_DISTFILES}{urllib.parse.quote(name)}", store / "distfiles" / name, digest, "sha512")
        members += [(f"alpine/{repo}/{origin}/{name}", data) for name, data in local.items()]
        members.append((f"alpine/{repo}/{origin}/.aports-commit", f"{commit}\n".encode()))

    release = guest.DMX_KERNEL_RELEASE
    members.append((f"linux/{Path(kernel_build.SOURCE['url']).name}", kernel_build.fetch(kernel_build.SOURCE["url"], kernel_build.SOURCE["sha256"])))
    members.append((f"linux/kernel-{release}.build.py", (ROOT / "scripts/build-kernel.py").read_bytes()))
    for commit, digest in kernel_build.TSO_PATCHES.items():
        members.append((f"linux/asahi-tso/{commit}.patch", kernel_build.fetch(f"{kernel_build.ASAHI}/{commit}.patch", digest)))
    with tarfile.open(kernel_tar) as tar:
        members.append((f"linux/kernel-{release}.config", tar.extractfile("boot/config").read()))
    members.append((f"qemu/{Path(qemu_build.SOURCE['url']).name}", kernel_build.fetch(qemu_build.SOURCE["url"], qemu_build.SOURCE["sha256"])))
    for name, digest in qemu_build.ALPINE_PATCHES.items():
        members.append((f"qemu/alpine-patches/{name}", kernel_build.fetch(f"{qemu_build.APORTS}/{name}", digest)))
    members.append(("qemu/dmx-guest-base.patch", qemu_build.GUEST_BASE_PATCH.encode()))
    members.append((f"qemu/{guest.DMX_QEMU}.build.py", (ROOT / "scripts/build-qemu.py").read_bytes()))
    for _subdir, (repo, commit, digest) in fex_build.SOURCES.items():
        members.append((f"fex/{repo.split('/')[1]}-{commit}.tar.gz", kernel_build.fetch(fex_build.source_url(repo, commit), digest)))
    members.append(("fex/dmx-fex.patch", fex_build.FEX_PATCH.encode()))
    members.append((f"fex/{guest.DMX_FEX}.build.py", (ROOT / "scripts/build-fex.py").read_bytes()))
    members.append(("README.md", f"""# Source of the dmx {version} guest

The complete corresponding source of the programs in dmx-guest-{version}.tar.gz (see its
THIRD_PARTY.md for licenses).

- `alpine/<repo>/<package>/`: each Alpine Linux 3.24 package the guest ships, or whose static
  libraries are linked into qemu-x86_64 or FEX-Emu: the aports directory at the commit in `.aports-commit`
  (APKBUILD, patches, configs) and the upstream files it names, checked against its sha512sums.
  `abuild` rebuilds a package from such a directory.
- `linux/`: the kernel.org source, the exact config, Asahi Linux's TSO patches (`asahi-tso/`),
  and `kernel-{release}.build.py`, which holds the free-page-reporting patch and the build steps.
- `qemu/`: the qemu.org source, Alpine's patches, dmx's guest-base patch, and
  `{guest.DMX_QEMU}.build.py` with the configure line and build steps.
- `fex/`: FEX-Emu's source and the submodules its build uses, dmx's patch, and
  `{guest.DMX_FEX}.build.py` with the build steps.

dmx itself (dmx-agent, /init, the host program) is Apache-2.0; its source is the {REPO}
repository at tag v{version}.
""".encode()))

    names = [n for n, _ in members]
    if len(names) != len(set(names)):
        sys.exit("duplicate names in the source bundle")
    tmp = path.with_name(path.name + ".part")
    with tarfile.open(tmp, "w", format=tarfile.PAX_FORMAT) as tar:
        added = set()
        for name, data in sorted(members, key=lambda m: m[0]):
            name = f"dmx-sources-{version}/{name}"
            parts = name.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                d = "/".join(parts[:i])
                if d not in added:
                    added.add(d)
                    ti = tarfile.TarInfo(d)
                    ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
                    tar.addfile(ti)
            ti = tarfile.TarInfo(name)
            ti.mode, ti.mtime = 0o644, 0
            if isinstance(data, Path):
                ti.size = data.stat().st_size
                with open(data, "rb") as f:
                    tar.addfile(ti, f)
            else:
                ti.size = len(data)
                tar.addfile(ti, io.BytesIO(data))
    tmp.rename(path)
    return {"name": path.name, "bytes": path.stat().st_size, "packages": len(dirs)}


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
    ap.add_argument("--cache", type=Path, default=home / "cache",
                    help="the cache `make guest` used; its inputs are only read, sources download to <cache>/release-sources")
    ap.add_argument("--no-build", action="store_true", help="package .build/release/dmx as it is")
    ap.add_argument("--ad-hoc", action="store_true", help=f"package the ad-hoc signed binary; skip Developer ID signing and notarization ({SIGNING_CONFIG})")
    ap.add_argument("--notes", type=Path, help=f"the \"Changes since ...\" section for NOTES.md (default {NOTES_DIR}/<version>.md)")
    ap.add_argument("--no-notes", action="store_true", help="publish without a change summary")
    args = ap.parse_args()

    tag = f"v{args.version}"
    version_file = ROOT / "Sources" / "DMXCore" / "Version.swift"
    found = re.search(r'^public let dmxVersion = "([^"]+)"', version_file.read_text(), re.M)
    if not found:
        sys.exit(f"{version_file.relative_to(ROOT)} has no `public let dmxVersion = \"...\"` line to read the version from")
    declared = found.group(1)
    if declared != args.version:
        sys.exit(f"{version_file.relative_to(ROOT)} says version {declared}; set it to {args.version} first")
    out = args.out or ROOT / ".build" / "dist" / tag
    out.mkdir(parents=True, exist_ok=True)
    if not args.ad_hoc and not SIGNING_CONFIG.is_file():
        sys.exit(f"no signing settings in {SIGNING_CONFIG} (see sign_and_notarize); pass --ad-hoc to release unsigned")

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
        f"budget patch in kernel-{guest.DMX_KERNEL_RELEASE}.build.py, Asahi Linux's TSO patches and the config in this release. "
        f"qemu-x86_64 is qemu.org source with Alpine's patches and a guest-base patch, built by "
        f"{guest.DMX_QEMU}.build.py, which pins every input; FEX-Emu is its release source with a dmx patch, built by "
        f"{guest.DMX_FEX}.build.py. "
        f"The complete corresponding source of all of it is dmx-sources-{args.version}.tar on the same release page.",
        items)

    # 1. The guest archive.
    archive_name = f"dmx-guest-{args.version}.tar.gz"
    members = [(name, (args.guest / name).read_bytes(), 0o644) for name in BOOT_FILES]
    members.append(("THIRD_PARTY.md", guest_notes.encode(), 0o644))
    members += [(f"LICENSES/{i}.txt", t, 0o644) for i, t in texts.items()]
    archive = out / archive_name
    deterministic_targz(archive, members)
    archive_sha = write_sha256(archive)

    # The guest's source, next to it on the release page.
    sources = source_bundle(out / f"dmx-sources-{args.version}.tar", items, args.cache, args.cache / "release-sources",
                            kernel_tar, args.version)
    write_sha256(out / sources["name"])

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
    signing = "ad-hoc signed"
    if not args.ad_hoc:
        binary = sign_and_notarize(binary, ROOT / ".build" / "signed")
        signing = "signed with a Developer ID and notarized by Apple"
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
    (out / f"{guest.DMX_QEMU}.build.py").write_bytes((ROOT / "scripts/build-qemu.py").read_bytes())
    (out / f"{guest.DMX_FEX}.build.py").write_bytes((ROOT / "scripts/build-fex.py").read_bytes())
    (out / "third-party.json").write_text(json.dumps({"guest": items, "dmx": swift}, indent=2) + "\n")
    notes_md = changes(args.version, None if args.no_notes else args.notes or NOTES_DIR / f"{args.version}.md")
    (out / "NOTES.md").write_text(release_notes(args.version, archive_name, binary_name, items, signing, notes_md))
    assets = sorted(p for p in out.iterdir() if p.is_file() and p.name != "SHA256SUMS" and not p.name.endswith(".sha256"))
    (out / "SHA256SUMS").write_text("".join(f"{sha256(p.read_bytes())}  {p.name}\n" for p in assets))

    print(json.dumps({"ok": True, "out": str(out), "tag": tag, "pin_changed": pin_changed,
                      "guest": {"name": archive_name, "bytes": archive.stat().st_size, "sha256": archive_sha},
                      "binary": {"name": binary_name, "bytes": (out / binary_name).stat().st_size, "sha256": binary_sha},
                      "sources": sources, "licenses": sorted(texts), "packages": len(items)}))
    if pin_changed:
        print(f"GuestPin.swift changed: commit it (and the version) before tagging {tag}, so the tag builds this binary",
              file=sys.stderr)


SIGNING_CONFIG = Path(os.environ.get("DMX_SIGNING_CONFIG", Path.home() / ".dmx-signing" / "release.json"))


def sign_and_notarize(binary: Path, work: Path) -> Path:
    """A copy of `binary` signed with the Developer ID in SIGNING_CONFIG (hardened runtime, secure
    timestamp, dmx's entitlements) and accepted by Apple's notary service. Command-line tools
    cannot carry a stapled ticket; Gatekeeper finds the ticket online on first launch.

    SIGNING_CONFIG (never in this repository) holds: identity (certificate SHA-1 or name),
    keychain and keychain_password_file (a keychain kept for signing, unlocked here), and
    notary_key, notary_key_id, notary_issuer (an App Store Connect API key)."""
    config = json.loads(SIGNING_CONFIG.read_text())
    path = lambda key: str(Path(config[key]).expanduser())
    signed = work / "dmx"
    work.mkdir(parents=True, exist_ok=True)
    signed.write_bytes(binary.read_bytes())
    signed.chmod(0o755)
    keychain = path("keychain")
    password = Path(path("keychain_password_file")).read_text().strip()
    subprocess.run(["security", "unlock-keychain", "-p", password, keychain], check=True)
    # codesign looks for identities only in the search list; add the keychain for the signature
    # and put the list back exactly as it was.
    listed = subprocess.run(["security", "list-keychains", "-d", "user"], check=True, capture_output=True, text=True).stdout
    before = [line.strip().strip('"') for line in listed.splitlines() if line.strip()]
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", keychain, *before], check=True)
    try:
        subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp",
                        "--entitlements", str(ROOT / "dmx.entitlements"), "--sign", config["identity"], str(signed)], check=True)
    finally:
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *before], check=True)
    details = subprocess.run(["codesign", "-dvv", str(signed)], capture_output=True, text=True).stderr
    if "Authority=Developer ID Application" not in details or "(runtime)" not in details:
        sys.exit(f"{signed} is not signed with a Developer ID and the hardened runtime:\n{details}")
    archive = work / "dmx-notarize.zip"
    archive.unlink(missing_ok=True)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(signed), str(archive)], check=True)
    notary = ["--key", path("notary_key"), "--key-id", config["notary_key_id"], "--issuer", config["notary_issuer"]]
    result = json.loads(subprocess.run(["xcrun", "notarytool", "submit", str(archive), *notary, "--wait", "--output-format", "json"],
                                       check=True, capture_output=True, text=True).stdout)
    archive.unlink()
    if result.get("status") != "Accepted":
        log = subprocess.run(["xcrun", "notarytool", "log", result.get("id", ""), *notary], capture_output=True, text=True).stdout
        sys.exit(f"notarization {result.get('id')}: {result.get('status')}\n{log}")
    print(f"notarized: {result['id']}", file=sys.stderr)
    return signed


def changes(version: str, path: Path | None) -> str:
    """The "Changes since ..." section, which only a person can write. It lives in
    docs/release-notes/<version>.md so it is reviewed and kept with the code; 0.2.2, 0.3.0 and
    0.3.1 had it pasted into the generated NOTES.md by hand and the SHA256SUMS line recomputed,
    which is exactly the step that is easy to forget."""
    if path is None:
        return ""
    if not path.is_file():
        sys.exit(f"no release notes in {path}: write what changed since the last release "
                 f"(a \"## Changes since <version>\" section), or pass --no-notes")
    text = path.read_text().strip()
    if not text.startswith("## "):
        sys.exit(f"{path} should start with a heading, e.g. \"## Changes since 0.3.1\"")
    return text + "\n\n"


def release_notes(version: str, archive: str, binary: str, items: list, signing: str, changes_md: str = "") -> str:
    gpl = sorted({f"{i['name']} {i['version']}" for i in items if "GPL" in i["license"]})
    return f"""# dmx {version}

Install (macOS 15 or later on Apple Silicon; no Xcode, Python or Rust needed):

```sh
curl -fsSL {REPO}/releases/download/v{version}/install.sh | sh
```

The first boot downloads the Linux guest ({archive}) and checks it against the sha256 built
into dmx; `dmx guest fetch` does it ahead of time.

{changes_md}
## Assets

- `{binary}`: the dmx binary ({signing}), its license and third-party notices
- `{archive}`: the Linux guest: kernel, initramfs, Docker image, licenses and THIRD_PARTY.md
- `install.sh`: installs dmx into ~/.local/bin after checking the tarball's sha256
- `kernel-{guest.DMX_KERNEL_RELEASE}.config`: the configuration the guest kernel was built with
- `kernel-{guest.DMX_KERNEL_RELEASE}.build.py`: pinned inputs and the exact kernel source patch
- `{guest.DMX_QEMU}.build.py`: pinned inputs, patches and configure line of qemu-x86_64
- `{guest.DMX_FEX}.build.py`: pinned inputs, patch and build steps of FEX-Emu
- `dmx-sources-{version}.tar`: the complete corresponding source of everything in the guest
- `third-party.json`: every package in the guest and the binary, with license and source
- `SHA256SUMS`, `*.sha256`: checksums

## Source code

dmx is Apache-2.0; its source is this tag. The guest contains programs under the GPL and LGPL,
among them {", ".join(gpl)}. Their complete corresponding source is
`dmx-sources-{version}.tar` on this page: for each Alpine Linux 3.24 package (unmodified) the
aports directory at the commit it was built from and the upstream files it names; the kernel.org
Linux source with dmx's reporting-budget patch, Asahi Linux's TSO patches, config and build script;
the qemu.org source with Alpine's patches, dmx's guest-base patch and build script; FEX-Emu's
source with dmx's patch and build script.
"""


if __name__ == "__main__":
    main()
