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
import lzma
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
# mke2fs, to format the data disk on first boot (busybox has no ext4 mkfs), e2fsck, to check it at
# every boot, and the libraries they link. Signatures checked against the Alpine keys in the minirootfs when these were pinned.
MKFS_PACKAGES = {
    "e2fsprogs": ("e2fsprogs-1.47.4-r0.apk", "52fd401e79ce6b0ff7648733ba4de3135083cd0132543534e72106e7ea767a00"),
    "e2fsprogs-libs": ("e2fsprogs-libs-1.47.4-r0.apk", "52124971ae397d599aadd79263fcd68fc9e271922ccf8185b124f35fe24c60c8"),
    "libcom_err": ("libcom_err-1.47.4-r0.apk", "a75b5955ff57046e33fc2842cfe466dc77d8e68305d5c86c6646b38a069490a2"),
    "libblkid": ("libblkid-2.42.3-r1.apk", "9d0f24976c575c53c12526b6e078edf34c980c153bc8e5f1c1053cbece5b8cfa"),
    "libuuid": ("libuuid-2.42.3-r1.apk", "9ce20c7ffe2ccaa7c321893c10564abbca13c3f2edb82f60a35f1f68e004f86c"),
    "libeconf": ("libeconf-0.8.3-r0.apk", "cf0899d49ded0a6891e3cdf1b37887f2ecd77293afe1d8f3cb8937763c83f183"),
}
for _name, (_file, _sha) in MKFS_PACKAGES.items():
    SOURCES[_name] = {"url": f"{ALPINE}/main/aarch64/{_file}", "sha256": _sha}
# Only these files, all in one directory that /init deletes once the disk is mounted, so they
# cost guest RAM only during boot.
MKFS_FILES = {
    "sbin/mke2fs", "sbin/e2fsck", "etc/mke2fs.conf", "usr/lib/libext2fs.so.2", "usr/lib/libe2p.so.2", "usr/lib/libcom_err.so.2",
    "usr/lib/libblkid.so.1", "usr/lib/libuuid.so.1", "usr/lib/libeconf.so.0",
}
MKFS_DIR = "usr/libexec/dmx-mkfs"

# x86_64 programs run through FEX-Emu (or QEMU user mode, a setting), which /init registers with
# binfmt_misc. DMX_FEX and DMX_QEMU are static PIEs, so they need no libraries. They come as an
# xz'd tar at the end of docker.img, not in the initramfs, where qemu cost ~2 MB of idle footprint
# (freed boot pages that free page reporting misses). /init unpacks the one in use from there onto
# the data disk when the copy there is missing, another version or the other emulator, so an
# emulator costs guest RAM only while an x86 program runs.

# Docker in the guest (docs/docker.md): dockerd, containerd, runc and what they run. Not in the
# initramfs (~150 MB would sit in guest RAM): they go into docker.img, a read-only disk that
# guest/docker unpacks onto the data disk when its contents change. ca-certificates-bundle is
# the CA file dockerd checks registries against. Signatures checked against the Alpine keys in
# the minirootfs when these were pinned.
DOCKER_PACKAGES = {
    "docker-engine": ("community", "docker-engine-29.9.2-r0.apk", "54020dff7d00fc5b165a37029ff23233af981bdd022ce4d15d13e2eb7e4195db"),
    "containerd": ("community", "containerd-2.3.7-r0.apk", "6ec45c52859e40f2b2ecf23a9be1d45d2199a86a5caa00f31586a29a53725646"),
    "runc": ("community", "runc-1.4.3-r2.apk", "969ef33f23a2a3586505cf9b5f9adda397851e615431a3267bfb970d16df4143"),
    "tini-static": ("community", "tini-static-0.19.0-r3.apk", "1cab1e98b70661fb92f53309f2dd7c2526c615eca9a1f57badc86b66f90607bc"),
    "iptables": ("main", "iptables-1.8.13-r0.apk", "9d22aef2e74346e9d537f6dc964786ab14b35580e3ccc0e4001dc3a725e8fe77"),
    "libxtables": ("main", "libxtables-1.8.13-r0.apk", "7535f18d9c7229178bc5e3809e5fea171033e33dfa054d88846512e1f25eefa8"),
    "libnftnl": ("main", "libnftnl-1.3.1-r0.apk", "8b31395671e910c294d7f0e29d3ac3c7efe9d89264db255f39aa9944dd4b6cac"),
    "libmnl": ("main", "libmnl-1.0.5-r2.apk", "0ca382c70f78affef3a4a28016aab25ad8c3ccf1bcdad59f3968d4536a7b2478"),
    "libseccomp": ("main", "libseccomp-2.6.1-r0.apk", "9a2a2a5ff3b17ca394a484a5905bceaa57c7d4d392079f07d68a03e44cdcdcd6"),
    "ca-certificates-bundle": ("main", "ca-certificates-bundle-20261020-r0.apk", "d0a573c27d337c369ad3abe3f39f09ffe67b95af23861577a8d134738375176a"),
}
for _name, (_repo, _file, _sha) in DOCKER_PACKAGES.items():
    SOURCES[_name] = {"url": f"{ALPINE}/{_repo}/aarch64/{_file}", "sha256": _sha}
# What dockerd needs from the packages: binaries under usr/, libraries, the CA file. tini-static
# is docker-init (the package links it from /sbin).
DOCKER_SKIP = ("usr/share/", "etc/containerd/", "etc/ethertypes", "etc/ssl1.1", "usr/bin/scmp_sys_resolver", "usr/sbin/iptables-apply",
               "usr/sbin/ip6tables-apply", "sbin/tini-static")
# Kernel modules Docker networking loads (bridge, veth, iptables over nf_tables, network drivers),
# kept on the data disk with the rest; guest/docker puts them at /lib/modules.
DOCKER_MODULE_DIRS = ("kernel/net/netfilter/", "kernel/net/ipv4/netfilter/", "kernel/net/ipv6/netfilter/", "kernel/net/bridge/")
DOCKER_MODULES = ["veth", "bridge", "br_netfilter", "macvlan", "ipvlan", "vxlan", "dummy", "tun", "af_packet"]
# docker.img: a 4 KB header, one field per line: "dmx-docker 3", the sha256 and length of the
# payload, the build key, then the sha256, offset and length of x86.tar.xz; then the payload, a
# gzip'd tar, and x86.tar.xz (the x86 emulators, X86_EMULATORS), each padded to 4 KB blocks.
DOCKER_IMAGE_MAGIC = b"dmx-docker 3\n"

KERNEL_RELEASE = "6.18.58-0-virt"
# The kernel the guest runs: trimmed 4K config and reporting patch, from scripts/build-kernel.py.
# The Alpine kernel above is used only to boot the VM that builds it (`--kernel alpine`).
DMX_KERNEL_RELEASE = "6.18.58-dmx-4k"
# qemu-x86_64, the other x86 emulator, from scripts/build-qemu.py (`make qemu`).
DMX_QEMU = "qemu-x86_64-11.0.3-dmx1"
# FEX-Emu, the default x86 emulator, from scripts/build-fex.py (`make fex`).
DMX_FEX = "fex-2610-dmx9"

# Modules the guest may load. Dependencies are added from modules.dep; the ones the kernel has
# built in are skipped.
MODULES = [
    "virtio_mmio",
    "virtio_balloon",
    "virtio_mem",
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
    "binfmt_misc",
]

# Minirootfs packages the dmx guest leaves out: apk and the TLS stack only it uses (~6 MB of
# initramfs that would sit in guest RAM). The bootstrap guest for `make kernel` keeps them.
DROP_PACKAGES = {
    "apk-tools", "libapk", "libcrypto3", "libssl3", "ca-certificates-bundle", "ssl_client", "zlib", "alpine-keys",
}

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


def package_files(tar: tarfile.TarFile, packages: set) -> set:
    """Paths the apk database lists for `packages` (F: is a directory, R: a file in it)."""
    db = tar.extractfile("./lib/apk/db/installed").read().decode()
    files, package, directory = set(), None, ""
    for line in db.splitlines():
        key, _, value = line.partition(":")
        if key == "P":
            package = value
        elif key == "F":
            directory = value
        elif key == "R" and package in packages:
            files.add(f"{directory}/{value}")
    return files


def add_mkfs(cpio: Cpio, cache: Path):
    """MKFS_FILES from the pinned apks, flattened into MKFS_DIR. Symlinks to versioned
    libraries are resolved, so each file is there once under the name the loader looks for."""
    found = {}
    for name in MKFS_PACKAGES:
        with tarfile.open(fetch(name, cache), "r:gz", ignore_zeros=True) as tar:
            members = {m.name: m for m in tar.getmembers()}
            for path in MKFS_FILES & members.keys():
                m = members[path]
                while m.issym():
                    m = members[str(Path(path).parent / m.linkname)]
                found[path] = (tar.extractfile(m).read(), m.mode & 0o777)
    if missing := MKFS_FILES - found.keys():
        sys.exit(f"not in the e2fsprogs packages: {sorted(missing)}")
    cpio.parents(MKFS_DIR + "/mke2fs")
    for path, (data, perm) in sorted(found.items()):
        cpio.file(f"{MKFS_DIR}/{Path(path).name}", data, perm)
    # The guest has no real-time clock: until the host sets it, its clock is far behind the times
    # e2fsck finds in the superblock, which would force a full check at every boot.
    cpio.file(f"{MKFS_DIR}/e2fsck.conf", b"[options]\n\tbroken_system_clock = 1\n", 0o644)


# The x86 emulators /init unpacks to /var/lib/dmx/x86: the file name there, the cached build and
# the make target that builds it. FEX is the default; `dmx config set x86_emulator qemu` picks qemu.
X86_EMULATORS = {"FEX": (DMX_FEX, "make fex"), "qemu-x86_64": (DMX_QEMU, "make qemu")}


def x86_binaries(cache: Path) -> dict:
    out = {}
    for name, (build, target) in X86_EMULATORS.items():
        path = cache / build
        if not path.exists():
            sys.exit(f"{path} not found; run `{target}` to build it")
        out[name] = path.read_bytes()
    return out


def x86_tar_xz(cache: Path) -> tuple:
    """X86_EMULATORS as an xz'd tar, and the tar's sha256, which /init compares with the one it
    unpacked last. A 1 MB dictionary (instead of preset 9's 64 MB) keeps what busybox unxz
    allocates small and costs a few KB."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in x86_binaries(cache).items():
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), 0o755, EPOCH
            tar.addfile(ti, io.BytesIO(data))
    packed = lzma.compress(buf.getvalue(), format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32,
                           filters=[{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME, "dict_size": 1 << 20}])
    return packed, hashlib.sha256(buf.getvalue()).hexdigest()


def docker_image(cache: Path, out: Path, open_kernel, kernel_sha: str, moddir: str, modules: set) -> dict:
    """Writes out/docker.img (see DOCKER_IMAGE_MAGIC) unless the one there has the same inputs.
    The payload unpacks to usr/ (dockerd and the rest, at the paths they were built for), etc/ssl
    and lib/modules/<release>/ (DOCKER_MODULES and MODULES, with the kernel's module index).
    x86.tar.xz follows it, for /init."""
    key = hashlib.sha256(json.dumps([sorted(v[2] for v in DOCKER_PACKAGES.values()), sorted(modules), kernel_sha,
                                     sorted(hashlib.sha256(b).hexdigest() for b in x86_binaries(cache).values()),
                                     hashlib.sha256(Path(__file__).read_bytes()).hexdigest()]).encode()).hexdigest()
    path = out / "docker.img"
    if path.exists():
        with open(path, "rb") as f:
            header = f.read(4096).split(b"\0")[0].decode(errors="replace").splitlines()
        if len(header) == 7 and header[0] + "\n" == DOCKER_IMAGE_MAGIC.decode() and header[3] == key:
            return {"bytes": path.stat().st_size, "sha256": header[1], "x86_sha256": header[4], "reused": True}

    def entry(src: tarfile.TarInfo, name: str) -> tarfile.TarInfo:
        ti = tarfile.TarInfo(name)
        ti.type, ti.mode, ti.linkname, ti.size, ti.mtime = src.type, src.mode, src.linkname, src.size, src.mtime
        return ti

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for name in DOCKER_PACKAGES:
            with tarfile.open(fetch(name, cache), "r:gz", ignore_zeros=True) as apk:
                for m in apk.getmembers():
                    if m.name.startswith(".") or m.name.startswith(DOCKER_SKIP) and m.name != "sbin/tini-static":
                        continue
                    if m.name == "usr/bin/docker-init":
                        continue  # a link to /sbin/tini-static; the file itself goes here instead
                    if m.name == "sbin/tini-static":
                        tar.addfile(entry(m, "usr/bin/docker-init"), apk.extractfile(m))
                    elif m.islnk():
                        target = apk.getmember(m.linkname)
                        ti = entry(target, m.name)
                        tar.addfile(ti, apk.extractfile(target))
                    else:
                        tar.addfile(entry(m, m.name), apk.extractfile(m) if m.isfile() else None)
        with open_kernel() as kt:
            meta = {moddir + f for f in ("modules.dep", "modules.alias", "modules.symbols", "modules.builtin", "modules.order")}
            dirs = set()
            for m in kt.getmembers():
                if m.name in modules or m.name in meta:
                    parts = m.name.split("/")[:-1]
                    for i in range(1, len(parts) + 1):
                        d = "/".join(parts[:i])
                        if d not in dirs:
                            dirs.add(d)
                            ti = tarfile.TarInfo(d)
                            ti.type, ti.mode = tarfile.DIRTYPE, 0o755
                            tar.addfile(ti)
                    tar.addfile(entry(m, m.name), kt.extractfile(m))
    payload = gzip.compress(buf.getvalue(), compresslevel=6, mtime=EPOCH)
    digest = hashlib.sha256(payload).hexdigest()
    x86, x86_sha = x86_tar_xz(cache)
    x86_offset = 4096 + len(payload) + (-len(payload) % 4096)
    header = DOCKER_IMAGE_MAGIC + f"{digest}\n{len(payload)}\n{key}\n{x86_sha}\n{x86_offset}\n{len(x86)}\n".encode()
    image = header.ljust(4096, b"\0") + payload
    image += b"\0" * (-len(image) % 4096)
    assert len(image) == x86_offset
    image += x86 + b"\0" * (-len(x86) % 4096)
    tmp = path.with_suffix(".part")
    tmp.write_bytes(image)
    tmp.rename(path)
    return {"bytes": len(image), "sha256": digest, "x86_sha256": x86_sha, "unpacked_bytes": len(buf.getvalue()), "reused": False}


def module_closure(dep_text: str, builtin_text: str, release: str, modules=MODULES, dirs=()) -> set:
    builtin = {Path(p).name.split(".ko")[0].replace("-", "_") for p in builtin_text.split()}
    deps = {}
    for line in dep_text.splitlines():
        path, _, rest = line.partition(":")
        deps[path] = rest.split()
    by_name = {
        Path(p).name.split(".ko")[0].replace("-", "_"): p for p in deps
    }
    want, todo = set(), [p for p in deps if p.startswith(dirs)] if dirs else []
    for mod in modules:
        if mod in builtin:
            continue
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

    kernel_sha = hashlib.sha256(Path(kernel).read_bytes()).hexdigest()
    cpio = Cpio()
    with tarfile.open(rootfs_tgz, "r:gz") as tar:
        keep = lambda name: True
        if args.kernel == "dmx":
            # Without apk its database and keys only mislead.
            dropped = package_files(tar, DROP_PACKAGES)
            keep = lambda name: name not in dropped and not name.startswith(("etc/apk", "lib/apk"))
        add_tar(cpio, tar, keep)

    moddir = f"lib/modules/{release}/"
    with open_kernel() as tar:
        dep = tar.extractfile(moddir + "modules.dep").read().decode()
        builtin = tar.extractfile(moddir + "modules.builtin").read().decode()
        want = {moddir + p for p in module_closure(dep, builtin, release)}
        meta = {moddir + f for f in ("modules.dep", "modules.alias", "modules.symbols", "modules.builtin", "modules.order")}
        add_tar(cpio, tar, keep=lambda n: n in want or n in meta)
        image = read_image(tar)

    # Kernel opens /dev/console before running /init; devtmpfs comes later.
    cpio.dir("dev")
    cpio.chardev("dev/console", 5, 1)
    cpio.file("init", (root / "guest" / "init").read_bytes(), 0o755)
    cpio.file("sbin/dmx-agent", agent, 0o755)
    cpio.file("sbin/dmx-docker", (root / "guest" / "docker").read_bytes(), 0o755)
    add_mkfs(cpio, args.cache)
    docker = None
    if args.kernel == "dmx":
        docker_modules = {moddir + p for p in module_closure(dep, builtin, release, MODULES + DOCKER_MODULES, DOCKER_MODULE_DIRS)}
        docker = docker_image(args.cache, args.out, open_kernel, kernel_sha, moddir, docker_modules)

    initramfs = gzip.compress(cpio.finish(), mtime=EPOCH)
    (args.out / "Image").write_bytes(image)
    (args.out / "initramfs.gz").write_bytes(initramfs)
    manifest = {
        "kernel": release,
        "sources": SOURCES,
        "modules": sorted(Path(p).name for p in want),
        "files": {
            Path(kernel).name: kernel_sha,
            "Image": hashlib.sha256(image).hexdigest(),
            "initramfs.gz": hashlib.sha256(initramfs).hexdigest(),
            "dmx-agent": hashlib.sha256(agent).hexdigest(),
        },
    }
    if docker:
        manifest["docker"] = {"payload_sha256": docker["sha256"], "image_bytes": docker["bytes"]}
        manifest["files"]["x86.tar"] = docker["x86_sha256"]
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"ok": True, "out": str(args.out), "image_bytes": len(image), "initramfs_bytes": len(initramfs), "modules": len(want),
                      "docker": docker}))


if __name__ == "__main__":
    main()
