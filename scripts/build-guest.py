#!/usr/bin/env python3
"""Build the dmx guest: an arm64 Linux kernel Image and a gzip'd initramfs.

Inputs are pinned Alpine Linux artifacts (verified by sha256) and the dmx kernel that
scripts/build-kernel.py builds from pinned inputs (`make kernel`). Outputs:
  <out>/Image           uncompressed arm64 kernel (what VZLinuxBootLoader wants)
  <out>/initramfs.gz    minirootfs + selected kernel modules + guest/init + dmx-agent
  <out>/manifest.json   versions and hashes, read by `dmx doctor`

Only the Python standard library is used, so this runs on a stock Mac.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
import struct
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ALPINE = "https://dl-cdn.alpinelinux.org/alpine/v3.24"
SOURCES = {
    "minirootfs": {
        "url": f"{ALPINE}/releases/aarch64/alpine-minirootfs-3.24.3-aarch64.tar.gz",
        "sha256": "4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50",
    },
    "kernel": {
        "url": f"{ALPINE}/main/aarch64/linux-virt-6.18.58-r0.apk",
        "sha256": "b46c51ddf572d85b2ba7b9adfaa64f4c38fc490c93d97a20ffd2418d51284085",
    },
}
KERNEL_RELEASE = "6.18.58-0-virt"
# The kernel the guest runs: Alpine's source and config with 16K pages, from scripts/build-kernel.py.
# The Alpine kernel above is used only to boot the VM that builds it (`--kernel alpine`).
DMX_KERNEL_RELEASE = "6.18.58-dmx"

# Modules the guest may load. Dependencies are added from modules.dep.
MODULES = [
    "virtio_mmio",
    "virtio_balloon",
    "vmw_vsock_virtio_transport",
    "virtio_rng",
    "virtio_net",
    "virtio_blk",
    "virtiofs",
    "overlay",
    "ext4",
    "zram",
    "veth",
    "bridge",
    "nf_tables",
]

AGENT_TARGET = "aarch64-unknown-linux-musl"

# Fixed mtime so the same inputs give a byte-identical initramfs.
EPOCH = 0


def fetch(name: str, cache: Path) -> Path:
    src = SOURCES[name]
    path = cache / Path(src["url"]).name
    if not path.exists():
        print(f"download {src['url']}", file=sys.stderr)
        tmp = path.with_suffix(path.suffix + ".part")
        with urllib.request.urlopen(src["url"]) as r, open(tmp, "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        tmp.rename(path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != src["sha256"]:
        path.unlink()
        sys.exit(f"sha256 mismatch for {path.name}: got {digest}")
    return path


def build_agent(root: Path) -> bytes:
    """Cross compile guest/agent to a static aarch64 musl binary (target set in .cargo/config.toml).
    Crates are pinned by the checksums in Cargo.lock; --locked refuses to change them."""
    crate = root / "guest" / "agent"
    subprocess.run(["cargo", "build", "--release", "--locked"], cwd=crate, check=True)
    return (crate / "target" / AGENT_TARGET / "release" / "dmx-agent").read_bytes()


def extract_zboot(pe: bytes) -> bytes:
    """vmlinuz-virt is an EFI zboot image; pull out and inflate the raw Image."""
    if pe[:2] != b"MZ" or pe[4:8] != b"zimg":
        sys.exit("vmlinuz is not an EFI zboot image")
    offset, size = struct.unpack_from("<II", pe, 8)
    comp = pe[24:32].rstrip(b"\0").decode()
    if comp != "gzip":
        sys.exit(f"unsupported zboot compression: {comp}")
    image = gzip.decompress(pe[offset : offset + size])
    if image[56:60] != b"ARM\x64":
        sys.exit("extracted kernel has no arm64 Image magic")
    return image


class Cpio:
    """Minimal writer for the newc format the kernel unpacks into rootfs."""

    def __init__(self):
        self.buf = io.BytesIO()
        self.ino = 1
        self.seen = set()

    def _entry(self, name, mode, data=b"", rdev=(0, 0)):
        name = name.lstrip("./")
        if not name or name in self.seen:
            return
        self.seen.add(name)
        fields = [
            self.ino, mode, 0, 0, 1, EPOCH, len(data), 0, 0,
            rdev[0], rdev[1], len(name) + 1, 0,
        ]
        self.ino += 1
        self.buf.write(b"070701" + b"".join(b"%08X" % f for f in fields))
        self.buf.write(name.encode() + b"\0")
        self._pad()
        self.buf.write(data)
        self._pad()

    def _pad(self):
        self.buf.write(b"\0" * (-self.buf.tell() % 4))

    def dir(self, name, perm=0o755):
        self._entry(name, 0o040000 | perm)

    def file(self, name, data, perm=0o644):
        self._entry(name, 0o100000 | perm, data)

    def symlink(self, name, target):
        self._entry(name, 0o120000 | 0o777, target.encode())

    def chardev(self, name, major, minor, perm=0o600):
        self._entry(name, 0o020000 | perm, rdev=(major, minor))

    def parents(self, name):
        parts = name.strip("/").split("/")[:-1]
        for i in range(1, len(parts) + 1):
            self.dir("/".join(parts[:i]))

    def finish(self) -> bytes:
        self._entry("TRAILER!!!", 0)
        return self.buf.getvalue()


def add_tar(cpio: Cpio, tar: tarfile.TarFile, keep=lambda name: True):
    for m in tar.getmembers():
        name = m.name.lstrip("./")
        if not name or not keep(name):
            continue
        cpio.parents(name)
        perm = m.mode & 0o7777
        if m.isdir():
            cpio.dir(name, perm)
        elif m.issym():
            cpio.symlink(name, m.linkname)
        elif m.islnk():
            cpio.file(name, tar.extractfile(tar.getmember(m.linkname)).read(), perm)
        elif m.isfile():
            cpio.file(name, tar.extractfile(m).read(), perm)


def module_closure(dep_text: str, release: str) -> set:
    deps = {}
    for line in dep_text.splitlines():
        path, _, rest = line.partition(":")
        deps[path] = rest.split()
    by_name = {
        Path(p).name.split(".ko")[0].replace("-", "_"): p for p in deps
    }
    want, todo = set(), []
    for mod in MODULES:
        if mod not in by_name:
            sys.exit(f"module {mod} not found in {release}")
        todo.append(by_name[mod])
    while todo:
        p = todo.pop()
        if p not in want:
            want.add(p)
            todo.extend(deps[p])
    return want


def main():
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get("DMX_HOME", Path.home() / ".dmx"))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=home / "guest")
    ap.add_argument("--cache", type=Path, default=home / "cache")
    ap.add_argument("--kernel", choices=["dmx", "alpine"], default="dmx",
                    help="alpine: the stock 4K page kernel, to bootstrap `make kernel`")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)

    agent = build_agent(root)
    rootfs_tgz = fetch("minirootfs", args.cache)
    if args.kernel == "alpine":
        release, kernel = KERNEL_RELEASE, fetch("kernel", args.cache)
        # An .apk is several gzip'd tar segments back to back.
        open_kernel = lambda: tarfile.open(kernel, "r:gz", ignore_zeros=True)
        read_image = lambda tar: extract_zboot(tar.extractfile("boot/vmlinuz-virt").read())
    else:
        release, kernel = DMX_KERNEL_RELEASE, args.cache / f"kernel-{DMX_KERNEL_RELEASE}.tar"
        if not kernel.exists():
            sys.exit(f"{kernel} not found; run `make kernel` to build it")
        open_kernel = lambda: tarfile.open(kernel)
        read_image = lambda tar: tar.extractfile("boot/Image").read()

    cpio = Cpio()
    with tarfile.open(rootfs_tgz, "r:gz") as tar:
        add_tar(cpio, tar)

    moddir = f"lib/modules/{release}/"
    with open_kernel() as tar:
        dep = tar.extractfile(moddir + "modules.dep").read().decode()
        want = {moddir + p for p in module_closure(dep, release)}
        meta = {moddir + f for f in ("modules.dep", "modules.alias", "modules.symbols", "modules.builtin", "modules.order")}
        add_tar(cpio, tar, keep=lambda n: n in want or n in meta)
        image = read_image(tar)

    # Kernel opens /dev/console before running /init; devtmpfs comes later.
    cpio.dir("dev")
    cpio.chardev("dev/console", 5, 1)
    cpio.file("init", (root / "guest" / "init").read_bytes(), 0o755)
    cpio.file("sbin/dmx-agent", agent, 0o755)

    initramfs = gzip.compress(cpio.finish(), mtime=EPOCH)
    (args.out / "Image").write_bytes(image)
    (args.out / "initramfs.gz").write_bytes(initramfs)
    manifest = {
        "kernel": release,
        "sources": SOURCES,
        "modules": sorted(Path(p).name for p in want),
        "files": {
            Path(kernel).name: hashlib.sha256(Path(kernel).read_bytes()).hexdigest(),
            "Image": hashlib.sha256(image).hexdigest(),
            "initramfs.gz": hashlib.sha256(initramfs).hexdigest(),
            "dmx-agent": hashlib.sha256(agent).hexdigest(),
        },
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"ok": True, "out": str(args.out), "image_bytes": len(image), "initramfs_bytes": len(initramfs), "modules": len(want)}))


if __name__ == "__main__":
    main()
