#!/usr/bin/env python3
"""Checks Alpine packages before they are pinned: each .apk's signature against the Alpine keys
in the pinned minirootfs, and its data against the datahash the signed control part names.

An .apk is three gzip streams: the signature (.SIGN.RSA*.<key>.rsa.pub), the control tar whose
.PKGINFO holds `datahash` (the sha256 of the third stream), and the data. `--lock` in the build
scripts pins what the mirror serves over HTTPS; run this on the files it downloaded (they are in
the cache) and on any package pinned by hand. Prints one line per file with its sha256; exits
non-zero if one fails.

    python3 -I scripts/verify-apk.py ~/.dmx/cache/docker-engine-29.9.3-r1.apk ...
"""

import hashlib
import io
import os
import subprocess
import sys
import tarfile
import tempfile
import zlib
from pathlib import Path

CACHE = Path(os.environ.get("DMX_HOME", Path.home() / ".dmx")) / "cache"
MINIROOTFS = CACHE / "alpine-minirootfs-3.24.3-aarch64.tar.gz"  # pinned in build-guest.py


def segments(raw):
    out, rest = [], raw
    while rest:
        d = zlib.decompressobj(31)
        body = d.decompress(rest)
        used = len(rest) - len(d.unused_data)
        out.append((rest[:used], body))
        rest = d.unused_data
    return out


def verify(path, keys):
    raw = path.read_bytes()
    try:
        segs = segments(raw)
        signature = tarfile.open(fileobj=io.BytesIO(segs[0][1]))
        member = next(m for m in signature.getmembers() if m.name.startswith(".SIGN."))
        key = keys / member.name.split(".", 3)[3]
        digest = "-sha256" if member.name.startswith(".SIGN.RSA256.") else "-sha1"
        with tempfile.NamedTemporaryFile() as sig, tempfile.NamedTemporaryFile() as control:
            sig.write(signature.extractfile(member).read())
            sig.flush()
            control.write(segs[1][0])
            control.flush()
            signed = subprocess.run(["openssl", "dgst", digest, "-verify", str(key), "-signature", sig.name, control.name],
                                    capture_output=True).returncode == 0
        info = tarfile.open(fileobj=io.BytesIO(segs[1][1])).extractfile(".PKGINFO").read().decode()
        datahash = next(line.split(" = ", 1)[1] for line in info.splitlines() if line.startswith("datahash"))
        data = hashlib.sha256(segs[2][0]).hexdigest() == datahash
    except Exception as e:  # a damaged file fails here rather than at the signature
        return False, f"unreadable: {e}"
    return signed and data, f"signature {'ok' if signed else 'BAD'}, data {'ok' if data else 'BAD'}"


def main():
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(MINIROOTFS, "r:gz") as tar:
            members = [m for m in tar.getmembers() if m.name.startswith("./etc/apk/keys/") and m.isfile()]
            tar.extractall(tmp, members=members)
        keys = Path(tmp) / "etc/apk/keys"
        failed = 0
        for name in sys.argv[1:]:
            path = Path(name)
            ok, detail = verify(path, keys)
            failed += not ok
            print(f"{'ok  ' if ok else 'FAIL'} {path.name} {hashlib.sha256(path.read_bytes()).hexdigest()} ({detail})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
