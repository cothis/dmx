#!/usr/bin/env python3
"""Run x86_64 Linux programs in the dmx guest through binfmt_misc, with FEX-Emu and with qemu-x86_64.

Real Alpine 3.24 x86_64 programs, pinned by sha256: a static busybox, the dynamically linked
busybox of the x86_64 minirootfs with its musl loader (in a chroot, as in a container, so the
emulator is not in its file system), python3 and node (V8, a JIT) installed into that chroot,
threads in both, python3 with jemalloc and mimalloc preloaded, addresses below x86-64's 47-bit
user space with and without /proc in the chroot, a setuid x86 program (FEX must ignore the
caller's configuration for it), FEX's hardware TSO, and 32-bit x86 programs (linux/386), which FEX
runs and qemu-x86_64 does not. Also times an x86 `true`, a 100 MB sha256sum against the
native one, and interpreter start-up and a python loop, per emulator. Runs a daemon in a throwaway
DMX_HOME using $DMX_HOME/guest (default ~/.dmx/guest); downloads land in $DMX_HOME/cache/x86_64.
Prints one JSON object and exits non-zero if any check failed.

    python3 -I scripts/test-x86.py [path/to/dmx]
"""

import hashlib
import importlib.util
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DMX = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/dmx").resolve()
STATE = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx")

sys.dont_write_bytecode = True  # importing build-guest.py must not leave __pycache__ in scripts/
_spec = importlib.util.spec_from_file_location("build_guest", ROOT / "scripts" / "build-guest.py")
guest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guest)

# x86_64 inputs. Signatures checked against the Alpine keys in the x86_64 minirootfs when pinned.
X86 = f"{guest.ALPINE}/main/x86_64"
guest.SOURCES["x86-minirootfs"] = {
    "url": f"{guest.ALPINE}/releases/x86_64/alpine-minirootfs-3.24.3-x86_64.tar.gz",
    "sha256": "f8e1cafba9b1b283b5d30d06f9885c8d2bc161ffe9083ade8e2e157813a53407",
}
guest.SOURCES["x86-busybox-static"] = {
    "url": f"{X86}/busybox-static-1.37.0-r31.apk",
    "sha256": "b0d6cfc585d7fdd12df359cc5d38d5e45894e9e9e78c4059eb41577d022ec734",
}
# 32-bit x86 (linux/386), which FEX runs and qemu-x86_64 cannot. The apk's signature was checked
# against the x86 key in this minirootfs when it was pinned (RSA/SHA-1 over the control segment,
# whose datahash covers the files).
I386 = f"{guest.ALPINE}/main/x86"
guest.SOURCES["i386-minirootfs"] = {
    "url": f"{guest.ALPINE}/releases/x86/alpine-minirootfs-3.24.3-x86.tar.gz",
    "sha256": "a73bd9ed20a5ed1503a0688957add539e10340c7ca1d9e8c06c34a76ddc5f715",
}
guest.SOURCES["i386-busybox-static"] = {
    "url": f"{I386}/busybox-static-1.37.0-r31.apk",
    "sha256": "26d45cc895b3fa99ba7500d0860c3934a363e74e464eeb5fc623f08147c33cfd",
}
# python3 and nodejs with their dependencies, minus what the minirootfs has.
PACKAGES = {
    "ada-libs-4.0.0-r0.apk": "8e67ac4e73afcae75033dd36efdf9ae257b4acebc17afe5af672dac9987e4591",
    "brotli-libs-1.2.1-r0.apk": "62a7e37e43bbfc1f8525a00ad2125fd5897135dc93b849733884cb78ffd8e26c",
    "c-ares-1.34.9-r0.apk": "3539a3e11c1ef1516117d8179a546ac882086e94e0d78ad51d687b3fa2b3b5f2",
    "ca-certificates-20261020-r0.apk": "ca8de7a7469e2a04b9008eb728d6de1a6da691e09e3379d83dfd77bbfce4e3f9",
    "gdbm-1.26-r0.apk": "3278ccba30b241168ca4ab93c919be805411b918fdc062f06d3684d12dc33ae3",
    "icu-data-en-78.1-r0.apk": "7fc4d3abd06b6e3301c82e9f872e4555d4a41e2abc28087f4286aba01e5dd5a7",
    "icu-libs-78.1-r0.apk": "ef9a3035f23886cf0da5869902c736a775cf3db151ae1ab7f1406e2a0f84bd64",
    "libbz2-1.0.8-r6.apk": "2737e2b23ed08d4911ee62cd0163b5f4bf0379cacf4dc35b23a00209584c98fd",
    "libexpat-2.9.0-r0.apk": "32b127f31e0a919110a18a7f0bb3780d8fb66ba4d8d61b2d301d633f0e319d0e",
    "libffi-3.5.2-r1.apk": "6da1a19313a40c56cac756fb11e2c4d5267831e1c22fc8323f24c943c94da6e0",
    "libgcc-15.2.0-r5.apk": "393dcd32629f06d7d85409c272d142d0c082772d10b87ef55ee82f47de3be637",
    "libncursesw-6.6_p20260516-r0.apk": "cf8caa8a88bc4ce9d9e395567fefaf9ef7fbd55c50ae6155b35c1b58f3755023",
    "libpanelw-6.6_p20260516-r0.apk": "057be8b1b788580f4cb72c382a6dcc03467d15bd69700f32192bd709e7a57a12",
    "libstdc++-15.2.0-r5.apk": "14c987b556f5385a5db18376e788c75f37d85321b8dc1920d926ea7daac1d6f6",
    "mpdecimal-4.0.1-r0.apk": "1278f374bbc8b4aad674244458cca5fc63e0780a921138eef400d5db64381a31",
    "ncurses-terminfo-base-6.6_p20260516-r0.apk": "ce83be6d0bd10584a53c3a5868cc1595ce5f0f8e0b621f8f7f70b6144e521fc9",
    "nghttp2-libs-1.70.0-r0.apk": "f0c4014eb2f10308dcdfd84cd49c121673c7b78cb8182b6e7a1388d8ae112a3b",
    "nodejs-24.22.1-r0.apk": "1c0128cac527b0b30d8d4cea42cd3f0cc66760d3afe9f42b7a8e8fa51f0c7c2a",
    "python3-3.14.8-r0.apk": "802caff00b3398c01bb227cd925c8f9e33585ff19f58f0f25295a761ff2509cd",
    "readline-8.3.3-r1.apk": "766911ecb986a6c5cf0841a6b556cd1e9dbbf22b3559726de32416486cd15c81",
    "simdjson-4.2.4-r0.apk": "b57ae504ace2b17f62da0de606d1d982d4a35ba9e3dd589c8a37f1444f84f535",
    "simdutf-9.0.0-r0.apk": "5d286fce7f98524973e72a1e50a89dfc2043d37565b9ee5266968c5ee64e20c6",
    "sqlite-libs-3.53.4-r0.apk": "a8a216e53d22faa3f04d2e3650c1991af66f8d0b42fadff5afcdb9afb60b19e5",
    "xz-libs-5.8.4-r0.apk": "ab362dd515ead04c31a6c302163248da7aa4813e283c971e6dd3f789b453a1d9",
    "zstd-libs-1.5.7-r2.apk": "23c6065b0049b2406441564bcf0032515a43f78e80d76fcb85535a3803ef5d4e",
    # Allocators reported to crash under upstream QEMU's layout (Redis: jemalloc; Nix: mimalloc).
    "jemalloc-5.3.0-r6.apk": "e070f30274a4048dabeffc7bd038df7467e18ff7ada2d1ff75f0da7158739e33",
    "community/mimalloc2-2.2.7-r0.apk": "78ead288ec6c0056ea973da9b74faa86b77c3d3dd62e93e1ac44e120249eb960",
}
for _file, _sha in PACKAGES.items():
    _repo, _, _name = _file.rpartition("/")
    guest.SOURCES[_file] = {"url": f"{guest.ALPINE}/{_repo or 'main'}/x86_64/{_name}", "sha256": _sha}
ALLOCATORS = {"jemalloc": "/usr/lib/libjemalloc.so.2", "mimalloc": "/usr/lib/libmimalloc.so.2"}
# Small, large (mmap'd) and freed blocks, then a check of what is left.
ALLOC_WORK = "x = [bytes([i % 251]) * (i * 4099 % 3000000) for i in range(400)]; del x[::2]; print(sum(len(b) for b in x) > 0)"

# In the guest, on the data disk (a chroot in tmpfs would hold ~100 MB of guest RAM).
DIR = "/var/lib/x86-test"

checks = []
results = {}


def check(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})


def dmx(*args, stdin=None, timeout=300):
    return subprocess.run([str(DMX), *args], input=stdin, capture_output=True, timeout=timeout, env=ENV)


def sh(script, stdin=None, timeout=300):
    return dmx("exec", "--", "sh", "-c", script, stdin=stdin, timeout=timeout)


def out(r):
    return (r.stdout + r.stderr).decode(errors="replace").strip()


def footprint():
    return json.loads(dmx("status", "--json").stdout).get("host_footprint_mb")


def chroot_tar(cache):
    """The x86_64 minirootfs plus PACKAGES' files, as one tar.gz for busybox tar in the guest."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", compresslevel=1) as dst:
        sources = [guest.fetch("x86-minirootfs", cache)] + [guest.fetch(f, cache) for f in PACKAGES]
        for path in sources:
            # An .apk is several gzip'd tar segments back to back; the first two are metadata.
            with tarfile.open(path, "r:gz", ignore_zeros=True) as src:
                for m in src.getmembers():
                    if m.name.lstrip("./").startswith(".") or not m.name.strip("./"):
                        continue
                    dst.addfile(m, src.extractfile(m) if m.isfile() else None)
    return buf.getvalue()


# Guest clock in centiseconds (busybox date has no %N).
CS = "cs() { read u _ </proc/uptime; echo ${u%.*}${u#*.}; }; "


def guest_ms(script, runs):
    """Milliseconds per run of `script`, timed in the guest (the exec round trip left out)."""
    r = sh(CS + f"s=$(cs); i=0; while [ $i -lt {runs} ]; do {script} >/dev/null || exit 1; i=$((i+1)); done; echo $(( ($(cs)-s)*10/{runs} ))")
    return int(r.stdout) if r.returncode == 0 and r.stdout.strip().isdigit() else None


# Page operations on 4K x86 pages, run by x86 python3 (ctypes for the raw calls).
# Prints name=value pairs; True means the call behaved as on x86 Linux.
PROBE = r"""
import ctypes, mmap, os
c = ctypes.CDLL(None)
c.mmap.restype = ctypes.c_void_p
c.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
for f in (c.mprotect, c.msync, c.madvise):
    f.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
c.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_ubyte)]
c.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
def faults(addr):
    pid = os.fork()
    if pid == 0:
        ctypes.c_char.from_address(addr).value
        os._exit(0)
    return os.waitpid(pid, 0)[1] & 0x7f == 11
with open("/tmp/probe", "wb") as f:
    f.write(bytes(65536))
fd = os.open("/tmp/probe", os.O_RDWR)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, offset=4096)
m[0:2] = b"ok"
s = c.mmap(None, 32768, 3, 0x01, fd, 0)
fixed = c.mmap(s + 4096, 4096, 3, 0x11, fd, 4096)
p = c.mmap(None, 32768, 3, 0x22, -1, 0)
ctypes.memset(p, 1, 32768)
u = c.mmap(None, 32768, 3, 0x22, -1, 0)
ctypes.memset(u, 1, 32768)
unmapped = c.munmap(u + 4096, 4096) == 0 and faults(u + 4096)
vec = (ctypes.c_ubyte * 1)()
# A hint at a taken address makes Linux search top-down, near the top of the host's 48-bit space.
taken = c.mmap(p, 4096, 3, 0x22, -1, 0)
big = c.mmap(None, 1 << 30, 0, 0x4022, -1, 0)
print("page_size=%d" % mmap.PAGESIZE,
      "user_space_47bit=%s" % all(a and a + 4096 <= 1 << 47 for a in (s, p, u, taken, big)),
      "map_shared_4k_offset=%s" % (os.pread(fd, 2, 4096) == b"ok"),
      "map_fixed_shared_4k=%s" % (fixed == s + 4096),
      "mincore_4k=%s" % (c.mincore(s + 4096, 4096, vec) == 0),
      "munmap_4k=%s" % (unmapped and ctypes.string_at(u, 1) == b"\1"),
      "msync_16k=%s" % (c.msync(s + 16384, 4096, 4) == 0),
      "msync_4k=%s" % (c.msync(s + 4096, 4096, 4) == 0),
      "prot_none_16k=%s" % (c.mprotect(p + 16384, 16384, 0) == 0 and faults(p + 16384)),
      "prot_none_4k=%s" % (c.mprotect(p + 4096, 4096, 0) == 0 and faults(p + 4096)),
      "dontneed_16k=%s" % (c.madvise(p, 16384, 4) == 0 and ctypes.string_at(p, 1) == b"\0"),
      "dontneed_4k=%s" % (c.madvise(p + 8192, 4096, 4) == 0 and ctypes.string_at(p + 8192, 1) == b"\0"))
"""


# Both emulators, the default first: `x86_emulator` picks the one /init registers at boot.
EMULATORS = {"fex": ("FEX-x86_64", "FEX"), "qemu": ("qemu-x86_64", "qemu-x86_64")}
# CPU-bound interpreted code (sha256sum spends its time in one tight loop).
PY_LOOP = "s = 0\nfor i in range(1000000): s = (s + i * i) % 1000003\nprint(s)\n"
THREADS = ("import threading\nn = [0]; lock = threading.Lock()\ndef work():\n    for _ in range(20000):\n        with lock: n[0] += 1\n"
           "ts = [threading.Thread(target=work) for _ in range(8)]\n[t.start() for t in ts]; [t.join() for t in ts]\nprint(n[0])\n")


def suite(emulator):
    entry_name, binary = EMULATORS[emulator]
    res = results[emulator] = {}

    def check_(name, ok, detail=""):
        check(f"{emulator}.{name}", ok, detail)

    dmx("config", "set", "x86_emulator", emulator)
    dmx("stop")
    r = dmx("exec", "--", "true")
    check_("boot", r.returncode == 0, out(r))
    res["idle_footprint_mb"] = footprint()

    # Only the chosen emulator is registered; FEX also takes 32-bit x86, qemu-x86_64 cannot.
    entries = out(sh("ls /proc/sys/fs/binfmt_misc")).split()
    entry = out(sh(f"cat /proc/sys/fs/binfmt_misc/{entry_name}"))
    expected = [entry_name, "register", "status"] + (["FEX-x86"] if emulator == "fex" else [])
    check_("binfmt_registered", sorted(entries) == sorted(expected) and "enabled" in entry and
           "flags: POCF" in entry and f"interpreter /var/lib/dmx/x86/{binary}" in entry, f"{entries} {entry}".replace("\n", "; "))

    # A static x86_64 busybox: no loader, no libraries.
    r = sh(f"mkdir -p {DIR} && cat >{DIR}/busybox && chmod +x {DIR}/busybox && {DIR}/busybox uname -m && {DIR}/busybox sh -c 'echo $((6*7))'",
           stdin=busybox)
    check_("static", r.returncode == 0 and r.stdout == b"x86_64\n42\n", out(r))
    # P: argv[0] reaches the program, so busybox picks the applet by the name it was run as.
    r = sh(f"ln -sf busybox {DIR}/basename && {DIR}/basename /a/b/c")
    check_("argv0", r.stdout == b"c\n", out(r))

    # The x86_64 minirootfs in a chroot: its dynamically linked busybox and musl loader, and
    # python3 and node from PACKAGES. The emulator is not in the chroot; F opened it at registration.
    # /proc is mounted, as in a container: that is where FEX reads the gaps it reserves above
    # 2^47 from (the probe without /proc is checked separately below).
    started = time.time()
    r = sh(f"rm -rf {DIR}/root && mkdir -p {DIR}/root && tar -xzf - -C {DIR}/root && cp /etc/resolv.conf {DIR}/root/etc/ && "
           f"mount -t proc proc {DIR}/root/proc", stdin=rootfs)
    res["chroot_unpack_s"] = round(time.time() - started, 1)
    check_("chroot_unpack", r.returncode == 0, out(r))
    run = f"chroot {DIR}/root"
    r = sh(f"{run} /bin/sh -c 'uname -m; ldd /bin/busybox | grep -o ld-musl-x86_64.so.1 | head -1; ls /usr/bin /usr/local/bin | grep -c -E \"qemu|FEX\"'")
    check_("dynamic", r.stdout == b"x86_64\nld-musl-x86_64.so.1\n0\n", out(r))
    r = sh(f"{run} /sbin/apk info -e musl busybox")
    check_("dynamic_apk", r.stdout == b"musl\nbusybox\n", out(r))

    r = sh(f"{run} python3 -c 'import hashlib, json, sqlite3, platform, ssl, zlib; db = sqlite3.connect(\":memory:\"); "
           f"print(platform.machine(), db.execute(\"select 6*7\").fetchone()[0], hashlib.sha256(b\"dmx\").hexdigest()[:8], len(ssl.OPENSSL_VERSION) > 0)'")
    check_("python3", r.stdout == b"x86_64 42 " + hashlib.sha256(b"dmx").hexdigest()[:8].encode() + b" True\n", out(r))
    # Threads exercise the emulator's thread creation and teardown, and its memory ordering.
    r = sh(f"cat >{DIR}/root/tmp/threads.py && {run} python3 /tmp/threads.py", stdin=THREADS.encode())
    check_("python3_threads", r.stdout == b"160000\n", out(r))

    # V8 writes x86 code at run time and patches it, which the emulator has to notice and translate again.
    r = sh(f"{run} node -e 'let s = 0; for (let i = 0; i < 3e7; i++) s = (s + i * i) % 1000003; "
           f"console.log(process.arch, s, [3, 1, 2].sort().join(\"\"), JSON.stringify({{a: [1, 2]}}))'")
    check_("node", r.returncode == 0 and r.stdout.startswith(b"x64 ") and r.stdout.endswith(b" 123 {\"a\":[1,2]}\n"), out(r))
    r = sh(f"{run} node -e 'const w = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11]))); console.log(w.exports.add(40, 2))'")
    check_("node_wasm", r.stdout == b"42\n", out(r))
    r = sh(f"{run} node -e 'const {{Worker}} = require(\"worker_threads\"); new Worker(\"require(\\\"worker_threads\\\").parentPort.postMessage(6 * 7)\", "
           f"{{eval: true}}).on(\"message\", m => console.log(m))'")
    check_("node_worker", r.returncode == 0 and r.stdout == b"42\n", out(r))

    if emulator == "fex":
        # FEX asks the guest kernel for the TSO memory model (Asahi's PR_SET_MEM_MODEL patches,
        # build-kernel.py), so x86 code needs no barriers; PR_GET_MEM_MODEL passes through to it.
        r = sh(f"{run} python3 -c 'import ctypes; print(ctypes.CDLL(None).prctl(0x6d4d444c, 0, 0, 0, 0))'")
        check_("hardware_tso", r.stdout == b"1\n", out(r))

        # binfmt's C flag runs the emulator with the x86 file's credentials, so for a setuid-root
        # x86 program FEX must ignore the configuration its unprivileged caller points at: the
        # FEX_* variables and $HOME/.fex-emu/Config.json (dmx's AT_SECURE patch, build-fex.py).
        # Each run writes the log FEX was asked for only if it read that configuration. Both
        # copies are named `true` because busybox picks the applet from argv[0]; only the one in
        # /suid is setuid root.
        setup = (f"rm -rf {DIR}/root/suid {DIR}/root/plain {DIR}/root/tmp/h && "
                 f"mkdir -p {DIR}/root/suid {DIR}/root/plain {DIR}/root/tmp/h/.fex-emu && "
                 f"cp {DIR}/root/bin/busybox {DIR}/root/suid/true && cp {DIR}/root/bin/busybox {DIR}/root/plain/true && "
                 f"chmod 4755 {DIR}/root/suid/true && echo '{{\"Config\":{{\"OutputLog\":\"/tmp/h/home.log\"}}}}' "
                 f">{DIR}/root/tmp/h/.fex-emu/Config.json && chown -R 65534 {DIR}/root/tmp/h")
        as_nobody = f"{run} su -s /bin/sh nobody -c"
        env = "HOME=/tmp/h FEX_OUTPUTLOG=/tmp/h/env.log FEX_SILENTLOG=0"
        r = sh(f"{setup} && {as_nobody} 'id -u; {env} /suid/true true && echo ran; ls -A /tmp/h'")
        check_("setuid_ignores_caller_config", r.stdout == b"65534\nran\n.fex-emu\n", out(r))
        # The control: the same program without setuid is an ordinary exec, so FEX does read the
        # caller's configuration and writes the log. Without it the check above proves nothing.
        r = sh(f"{as_nobody} 'rm -f /tmp/h/*.log; {env} /plain/true true && echo ran; ls -A /tmp/h'")
        check_("setuid_control_reads_config", r.stdout == b"ran\n.fex-emu\nenv.log\n", out(r))
        sh(f"rm -rf {DIR}/root/suid {DIR}/root/plain {DIR}/root/tmp/h")

        # 32-bit x86 (linux/386 images). FEX takes its vsyscall entry from a VDSO thunk, and
        # without one it writes `int 0x80` into a page of its own; dmx's patch makes that page
        # executable, without which every 32-bit program died on its first syscall.
        entry32 = out(sh("cat /proc/sys/fs/binfmt_misc/FEX-x86"))
        check_("i386_binfmt", "enabled" in entry32 and "flags: POCF" in entry32 and
               "interpreter /var/lib/dmx/x86/FEX" in entry32 and "magic 7f454c4601" in entry32, entry32.replace("\n", "; "))
        # The static one, as `busybox` so its applet multiplexer works (P passes argv[0] through).
        # FEX's emulated uname says x86_64 even for a 32-bit program, as upstream does.
        r = sh(f"mkdir -p {DIR}/i386 && cat >{DIR}/i386/busybox && chmod +x {DIR}/i386/busybox && "
               f"{DIR}/i386/busybox sh -c 'echo $((6*7))' && {DIR}/i386/busybox uname -m", stdin=busybox32)
        check_("i386_static", r.returncode == 0 and r.stdout == b"42\nx86_64\n", out(r))
        # The 32-bit minirootfs in a chroot, its own musl loader included, as a linux/386 image has.
        r = sh(f"rm -rf {DIR}/root32 && mkdir -p {DIR}/root32 && tar -xzf - -C {DIR}/root32 && "
               f"mount -t proc proc {DIR}/root32/proc && mount -o bind /dev {DIR}/root32/dev && "
               f"chroot {DIR}/root32 /bin/sh -c 'echo $((6*7)); /sbin/apk info -e musl busybox; "
               f"dd if=/dev/zero bs=1024 count=64 2>/dev/null | md5sum; "
               f"/lib/ld-musl-i386.so.1 /bin/busybox echo loader-ok'", stdin=rootfs32)
        check_("i386_dynamic", r.stdout == b"42\nmusl\nbusybox\nfcd6bcb56c1689fcef28b57c22475bad  -\nloader-ok\n", out(r))
        # As with 64-bit programs, each process is the emulator plus the program.
        r = sh(f"{DIR}/i386/busybox sleep 4 & sleep 2; grep -E '^(Rss|AnonHugePages):' /proc/$!/smaps_rollup; wait")
        rss32 = {line.split()[0].decode().rstrip(":"): int(line.split()[1]) // 1024 for line in r.stdout.splitlines()}
        res["i386_sleep_mb"] = rss32
        check_("i386_process_memory", 0 < rss32.get("Rss", 0) < 24 and rss32.get("AnonHugePages") == 0, str(rss32))
        res["i386_true_ms"] = guest_ms(f"{DIR}/i386/busybox true", 20)
        sh(f"umount {DIR}/root32/proc {DIR}/root32/dev; rm -rf {DIR}/root32 {DIR}/i386")

    # All 4K operations must work. A 16K Linux guest used to fail partial msync, fixed shared
    # mappings, MADV_DONTNEED zeroing and guard-page faults; do not count those as expected passes.
    r = sh(f"ulimit -c 0; cat >{DIR}/root/tmp/probe.py && {run} python3 /tmp/probe.py", stdin=PROBE.encode())
    probe = dict(f.split("=") for f in r.stdout.decode().split() if "=" in f)
    res["pages"] = probe
    check_("pages_4k", r.returncode == 0 and probe.get("page_size") == "4096" and
           all(probe.get(k) == "True" for k in ["user_space_47bit", "map_shared_4k_offset", "map_fixed_shared_4k", "mincore_4k", "munmap_4k", "msync_16k", "msync_4k",
                                                 "prot_none_16k", "prot_none_4k", "dontneed_16k", "dontneed_4k"]), out(r))

    for name, lib in ALLOCATORS.items():
        r = sh(f"ulimit -c 0; {run} env LD_PRELOAD={lib} python3 -c '{ALLOC_WORK}'")
        check_(f"allocator_{name}", r.returncode == 0 and r.stdout == b"True\n", out(r))

    # The same probe in a chroot without /proc, as BuildKit's emulator probe runs in. FEX reads
    # /proc/self/maps to reserve the space above 2^47 and, with dmx's patch (build-fex.py), probes
    # for it with MAP_FIXED_NOREPLACE when it cannot be read; upstream reserved nothing there, so
    # x86 programs got addresses above 2^47 and jemalloc and mimalloc aborted on them.
    sh(f"umount {DIR}/root/proc")
    r = sh(f"ulimit -c 0; {run} python3 /tmp/probe.py")
    probe = dict(f.split("=") for f in r.stdout.decode().split() if "=" in f)
    res["pages_without_proc"] = probe
    allocators = {name: sh(f"ulimit -c 0; {run} env LD_PRELOAD={lib} python3 -c '{ALLOC_WORK}'").stdout == b"True\n"
                  for name, lib in ALLOCATORS.items()}
    check_("pages_4k_without_proc", r.returncode == 0 and probe.get("page_size") == "4096" and
           probe.get("user_space_47bit") == "True" and all(allocators.values()), f"{out(r)} {allocators}")
    sh(f"mount -t proc proc {DIR}/root/proc")

    if emulator == "qemu":
        # The control: without dmx's default guest base, qemu hands out addresses above x86-64's
        # 47-bit user space, which crashed Redis's jemalloc. Shows the probe above can tell.
        r = sh(f"ulimit -c 0; {run} env QEMU_GUEST_BASE=0 python3 /tmp/probe.py")
        check_("user_space_47bit_control", "user_space_47bit=False" in r.stdout.decode(), out(r))
        res["allocators_upstream_layout"] = {
            name: sh(f"ulimit -c 0; {run} env QEMU_GUEST_BASE=0 LD_PRELOAD={lib} python3 -c '{ALLOC_WORK}'").returncode
            for name, lib in ALLOCATORS.items()}

    # Each x86 process is the emulator: its own translated code and copies of file pages it could
    # not map, on top of the program. qemu madvises its 128 MB code buffer for huge pages, which
    # cost 32 MB per process until the guest stopped making transparent huge pages.
    r = sh(f"{DIR}/busybox sleep 4 & sleep 2; grep -E '^(Rss|Anonymous|AnonHugePages):' /proc/$!/smaps_rollup; wait")
    rss = {line.split()[0].decode().rstrip(":"): int(line.split()[1]) // 1024 for line in r.stdout.splitlines()}
    res["x86_sleep_mb"] = rss
    check_("x86_process_memory", 0 < rss.get("Rss", 0) < 16 and rss.get("AnonHugePages") == 0, str(rss))

    # Speed against native. `true` measures start-up; sha256sum is one tight translated loop and
    # the python loop interpreted code.
    res["true_ms"] = {"x86_static": guest_ms(f"{DIR}/busybox true", 20), "x86_dynamic": guest_ms(f"{run} /bin/true", 20),
                      "native": guest_ms("/bin/true", 20)}
    res["python3_startup_ms"] = guest_ms(f"{run} python3 -c pass", 3)
    res["node_startup_ms"] = guest_ms(f"{run} node -e 0", 3)
    sh(f"cat >{DIR}/root/tmp/loop.py", stdin=PY_LOOP.encode())
    res["python3_loop_ms"] = guest_ms(f"{run} python3 /tmp/loop.py", 3)
    timed = CS + "s=$(cs); head -c 104857600 /dev/zero | BUSYBOX sha256sum; echo $(( ($(cs)-s)*10 ))"
    native = sh(timed.replace("BUSYBOX", "")).stdout.split()
    emulated = sh(timed.replace("BUSYBOX", f"{DIR}/busybox")).stdout.split()
    check_("sha256_100mb", len(native) == 3 and len(emulated) == 3 and native[0] == emulated[0], f"{native} {emulated}")
    if len(native) == 3 and len(emulated) == 3:
        res["sha256_100mb_ms"] = {"native": int(native[2]), "x86": int(emulated[2]), "slowdown": round(int(emulated[2]) / max(1, int(native[2])), 1)}

    res["footprint_after_x86_mb"] = footprint()
    sh(f"umount {DIR}/root/proc; rm -rf {DIR}")
    dmx("exec", "--", "sh", "-c", "sync; echo 3 >/proc/sys/vm/drop_caches")
    time.sleep(3)
    res["footprint_after_cleanup_mb"] = footprint()


HOME = Path(tempfile.mkdtemp(prefix="dmx-x86-", dir="/tmp"))
ENV = {**os.environ, "DMX_HOME": str(HOME)}
(HOME / "guest").symlink_to(STATE / "guest")
try:
    # Apart from the aarch64 packages: the same file names, other contents.
    cache = STATE / "cache" / "x86_64"
    cache.mkdir(parents=True, exist_ok=True)
    with tarfile.open(guest.fetch("x86-busybox-static", cache), "r:gz", ignore_zeros=True) as tar:
        busybox = tar.extractfile("bin/busybox.static").read()
    rootfs = chroot_tar(cache)
    cache32 = STATE / "cache" / "x86"
    cache32.mkdir(parents=True, exist_ok=True)
    with tarfile.open(guest.fetch("i386-busybox-static", cache32), "r:gz", ignore_zeros=True) as tar:
        busybox32 = tar.extractfile("bin/busybox.static").read()
    rootfs32 = guest.fetch("i386-minirootfs", cache32).read_bytes()

    dmx("config", "set", "shares", "none")
    for emulator in EMULATORS:
        suite(emulator)
finally:
    dmx("stop")
    out_pids = subprocess.run(["pgrep", "-f", f"{DMX} daemon"], capture_output=True, text=True).stdout.split()
    for pid in out_pids:
        env = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if f"DMX_HOME={HOME}" in env:
            os.kill(int(pid), signal.SIGTERM)
    shutil.rmtree(HOME, ignore_errors=True)

ok = all(c["ok"] for c in checks)
print(json.dumps({"ok": ok, **results, "checks": checks}, indent=2))
sys.exit(0 if ok else 1)
