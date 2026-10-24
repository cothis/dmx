# Releasing dmx

A release lets people use dmx without Xcode, Python, Rust or Homebrew: they run one install
script, and dmx downloads its Linux guest on first use. Everything a release needs is built on the
maintainer's Mac by `make release`; nothing is uploaded by a script.

## What a user gets

```sh
curl -fsSL https://github.com/cothis/dmx/releases/download/v0.1.0/install.sh | sh
dmx install            # optional: launchd and the docker context
dmx exec -- uname -a   # the first boot downloads the guest (62 MB) and checks it
```

- `install.sh` downloads `dmx-<version>-darwin-arm64.tar.gz`, checks it against the sha256 written
  into that copy of the script (or, with `DMX_VERSION` set to another version, the `.sha256` file
  next to the tarball), and installs `dmx` to `~/.local/bin` (`PREFIX` to change). It needs no
  sudo and changes nothing else: no shell profile, no launchd, no `~/.dmx`.
- The dmx binary carries the sha256 of the guest it was released with
  (`Sources/DMXCore/GuestPin.swift`). Before a boot (the daemon's, or `dmx boot`) it downloads
  `<base>/<tag>/dmx-guest-<version>.tar.gz` when `~/.dmx/guest` is missing or came from another
  release, checks the archive and each boot file against the pin, unpacks it next to the old guest
  and swaps the directories. One process downloads at a time (`~/.dmx/guest.lock`).
- `<base>` is `https://github.com/cothis/dmx/releases/download`; `DMX_RELEASE_URL` replaces it
  (a mirror, or a local server when testing).
- A guest built with `make guest` is never replaced by itself: dmx tells it apart because
  `~/.dmx/guest/release.json` (written after a download) no longer matches `manifest.json`.
  `dmx guest fetch --force` replaces it.
- If updating a guest from an older release fails (offline), the old guest boots.
- Cost: from a local server the download, check and unpack take 0.3 to 0.6 s. A daemon that
  downloaded keeps ~6 MB more footprint (10 MB instead of 4 with the VM stopped; CFNetwork) until
  it exits at idle; a later daemon does not.
- `dmx guest` shows where the guest came from; `dmx doctor` also hashes a downloaded guest
  against its release. Errors: `guest_download_failed`, `checksum_mismatch`, `no_guest_release`
  (a dmx built from source without a pin: run `make guest`).

## Cutting a release

1. Build the guest from a clean checkout: `make kernel` and `make qemu` if they changed, then `make guest`.
2. Set `version` in `Sources/dmx/DMX.swift` (the tag is `v<version>`).
3. Run the local checks. There is no CI: these need the real VM, which hosted runners cannot
   provide (no nested virtualization).

   ```sh
   make build && make test && make selftest
   make daemontest && make mcptest && make x86test && make dockertest
   ```

4. `make release VERSION=0.1.0` writes `.build/dist/v0.1.0/` and rewrites
   `Sources/DMXCore/GuestPin.swift` for the new guest. Commit the pin and the version
   ("Release v0.1.0"), then run `make release VERSION=0.1.0` again: it must say
   `"pin_changed": false`, so the binary in the directory is the one the commit builds.
5. Try the directory as a user would, from a local server:

   ```sh
   python3 -m http.server --bind 127.0.0.1 --directory .build/dist 23456 &
   export DMX_RELEASE_URL=http://127.0.0.1:23456
   DMX_HOME=$(mktemp -d) .build/release/dmx boot --selftest      # downloads the guest, boots it
   PREFIX=$(mktemp -d) sh .build/dist/v0.1.0/install.sh             # installs from the tarball
   ```

6. Tag and publish (the only steps that make anything public):

   ```sh
   git tag -a v0.1.0 -m "dmx 0.1.0" && git push origin main v0.1.0
   gh release create v0.1.0 --title "dmx 0.1.0" --notes-file .build/dist/v0.1.0/NOTES.md .build/dist/v0.1.0/*
   ```

## What is in the release directory

| File | What |
|---|---|
| `dmx-<version>-darwin-arm64.tar.gz` (+ `.sha256`) | `dmx` (ad-hoc signed with the hypervisor entitlement), `LICENSE`, `THIRD_PARTY.md` (swift-argument-parser) |
| `dmx-guest-<version>.tar.gz` (+ `.sha256`) | `Image`, `initramfs.gz`, `docker.img`, `manifest.json`, `THIRD_PARTY.md`, `LICENSES/` |
| `install.sh` | `scripts/install.sh` with the version and the tarball's sha256 written in |
| `kernel-<release>.config` | the exact config of the guest kernel |
| `kernel-<release>.build.py` | the build recipe, pinned inputs and exact reporting-budget source patch |
| `qemu-x86_64-<version>.build.py` | qemu-x86_64's recipe: pinned source, Alpine patches, guest-base patch, configure line |
| `third-party.json` | every package in the guest and the binary: version, license, upstream, source |
| `NOTES.md` | release text: install line, assets, source offer |
| `SHA256SUMS` | all of the above |

Both archives are byte-identical for the same inputs (fixed order, owner and mtime), so the pin
does not change when nothing in the guest did.

## Licenses and the GPL

dmx is Apache-2.0. The guest is a collection of separate programs that run in the VM, each under
its own license; dmx does not link to any of them, so it stays Apache-2.0. Shipping their binaries
still carries obligations. What `release.py` does for them:

- **Inventory.** Every shipped package with its version and license, read from the Alpine apk
  metadata (`.PKGINFO`, or the minirootfs's apk database), the aports commit it was built from,
  and its upstream; the kernel; the agent's crates (from `cargo metadata`, without build-time
  proc-macro crates). In `THIRD_PARTY.md` (inside the guest archive, so it lands in
  `~/.dmx/guest`) and `third-party.json`. Today that is 25 Alpine packages under GPL-2.0,
  LGPL-2.0/2.1, MIT, BSD, Apache-2.0 and MPL-2.0 (busybox, musl, e2fsprogs, util-linux libraries,
  iptables, libnftnl, libmnl, libseccomp, docker, containerd, runc, tini, CA bundle...), dmx's
  qemu-x86_64 and the Alpine static libraries linked into it (`STATIC_LINKED` in build-qemu.py).
- **License texts.** One per SPDX id in the inventory, from SPDX's license list at a fixed commit,
  each pinned by sha256, in `LICENSES/`. A new id stops the release until its text is pinned.
- **Source.** GPL-2.0 section 3 requires, with the binaries, either the complete corresponding
  source (3a) or a written offer valid for three years to provide it (3b); LGPL-2.1 section 6 is
  similar. The source of every GPL/LGPL program in the guest is public; dmx's kernel and QEMU changes are recorded below:
  - Alpine packages: the aports directory at the commit in `THIRD_PARTY.md` (APKBUILD, patches,
    configs) plus the upstream tarballs it names, which Alpine mirrors at
    `https://distfiles.alpinelinux.org/distfiles/v3.24/`.
  - qemu-x86_64: `qemu-11.0.3.tar.xz` from qemu.org with Alpine's patches from aports
    `51049924607603c9d9b7132c187a7f31085d7a12` (`community/qemu`), all pinned by sha256 in
    `scripts/build-qemu.py`, which also holds the guest-base patch and the configure line and is
    shipped as `qemu-x86_64-<version>.build.py`. As with the kernel, the modified source must be
    included when delivering its corresponding source; the static glib, libintl, pcre2, musl and
    GCC runtime libraries in it are the Alpine packages listed in `THIRD_PARTY.md`.
  - The kernel: `linux-<version>.tar.xz` from kernel.org (sha256 in `scripts/build-kernel.py`),
    with `kernel-<release>.config` and `scripts/build-kernel.py`. The build script contains the
    exact `mm/page_reporting.c` free-list budget patch and refuses a source that does not match;
    its modified source must be included when delivering the corresponding kernel source.

  Pointing at Alpine's and kernel.org's servers is not enough on its own: the distributor must
  make sure the source stays available as long as it offers the binaries. `NOTES.md` therefore
  carries a written offer (3b). The alternative is to attach the sources to each release (3a; about
  300 MB: kernel ~150 MB, QEMU ~130 MB, the rest small), which ends the obligation with the upload.
  Choosing between the two is the maintainer's decision; see below.
- **Notices.** MIT and BSD licenses ask that the copyright notice travel with binaries. The SPDX
  texts carry placeholders, not each project's copyright line; those lines are in each package's
  source. Attaching sources covers this; otherwise `THIRD_PARTY.md` should grow the copyright lines.

## Decisions before the first public release

- **Version and tag scheme**: `v0.1.0` and SemVer are assumed; the guest archive is named after the
  dmx version and republished with each release (62 MB), even when unchanged.
- **Source offer or attached sources** for the GPL/LGPL programs (above).
- **Signing**: binaries are ad-hoc signed. `curl` does not quarantine files, so `install.sh` works;
  a tarball downloaded in a browser is quarantined and Gatekeeper refuses the binary until
  `xattr -d com.apple.quarantine dmx`. Developer ID signing and notarization remove that and need a
  paid Apple Developer account; the hypervisor entitlement is allowed with Developer ID and the
  hardened runtime.
- **CI**: none, by choice (2026-10-24). Hosted macOS runners could build and run `swift test`, but
  not the VM tests.

## Recommendation (2026-10-25)

Waiting for the maintainer's approval; nothing has been tagged or published.

- **Version:** `v0.1.0`, SemVer, an ordinary GitHub release (not a draft). 0.x already says
  "early"; `install.sh` pins its own version, so "latest" pointing at it costs nothing. The guest
  archive keeps the dmx version in its name and is re-uploaded with each release.
- **GPL source: attach it (3a), don't rely on the written offer (3b).** A `dmx-sources-<version>.tar`
  (~300 MB: the kernel.org and qemu.org tarballs, the aports directories and distfiles of every
  shipped Alpine package, dmx's patches and recipes) on the same release page counts as
  "equivalent access from the same place". That ends the obligation with the upload, avoids a
  three-year personal promise to answer source requests, and carries the copyright notices the
  MIT/BSD texts need. The kernel and qemu-x86_64 are now modified builds, so pointing at Alpine
  alone is not enough for them anyway. GitHub allows 2 GiB per asset; re-attach only when the
  guest changes and link the earlier bundle otherwise. Needs a `release.py` step (not written yet).
- **Signing: ship v0.1.0 ad-hoc signed.** The supported install is `curl … | sh`, which does not
  quarantine, so Gatekeeper is not involved; README tells browser downloaders the `xattr` step.
  Developer ID and notarization need a paid Apple account in the maintainer's name ($99/year);
  get it when there is a browser or GUI download to support.
- **Name and wording:** keep "dmx". Never "Docker for Mac" or any name containing "Docker":
  Docker, Inc.'s trademark guidelines forbid names implying affiliation, and Docker for Mac was
  its own product. Describe it as Docker-compatible; README carries the trademark notice.
- **Before tagging:** replace README's "no public release yet", run the local-server dry run in
  "Cutting a release", and quote the benchmark numbers only with their caveats (load 2–6).
