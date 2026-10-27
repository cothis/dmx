# Releasing dmx

A release lets people use dmx without Xcode, Python, Rust or Homebrew: they run one install
script, and dmx downloads its Linux guest on first use. Everything a release needs is built on the
maintainer's Mac by `make release`; nothing is uploaded by a script.

## What a user gets

```sh
curl -fsSL https://github.com/cothis/dmx/releases/download/v0.3.8/install.sh | sh
dmx install            # optional: launchd and the docker context
dmx exec -- uname -a   # the first boot downloads the guest (62 MB) and checks it
```

- `install.sh` downloads `dmx-<version>-darwin-arm64.tar.gz`, checks it against the sha256 written
  into that copy of the script (or, with `DMX_VERSION` set to another version, the `.sha256` file
  next to the tarball), and installs `dmx` to `~/.local/bin` (`PREFIX` to change). It needs no
  sudo and changes nothing else: no shell profile, no launchd, no `~/.dmx`.
- `dmx update` does the same for an installed dmx, from the binary itself: it resolves the newest
  release (the redirect GitHub answers for `releases/latest`, so a mirror needs `--version`),
  checks the archive against the published `.sha256` and the download's Developer ID team against
  the running binary's (skipped when this dmx is unsigned, which a build from source is), runs the
  binary it unpacked to see that it reports that version, and renames it over the file it is
  running from. It refuses to overwrite a
  build from source (`.build/...`) without `--force`, and refuses a directory it cannot write with
  a hint naming `install.sh` and `PREFIX`. A running VM is left alone and the report says
  `stop_to_switch`; an idle daemon exits on its own after ten seconds without clients
  (`exits_soon`). The updater never sends `quit`, including while a VM is starting or its state
  cannot be read. `DaemonClient` also prints a notice whenever the daemon answering is another version,
  because an old daemon keeps serving until it exits.
- The dmx binary carries the sha256 of the guest it was released with
  (`Sources/DMXCore/GuestPin.swift`). Before a boot (the daemon's, or `dmx boot`) it downloads
  `<base>/<tag>/dmx-guest-<version>.tar.gz` when `~/.dmx/guest` is missing or came from another
  release, checks the archive and each boot file against the pin, unpacks it next to the old guest
  and swaps the directories. One process downloads at a time (`~/.dmx/guest.lock`).
- `<base>` is `https://github.com/cothis/dmx/releases/download`; the `release_url` setting or `DMX_RELEASE_URL` replaces it
  (a mirror, or a local server when testing).
- A guest built with `make guest` is never replaced by itself: dmx tells it apart because
  `~/.dmx/guest/release.json` (written after a download) no longer matches `manifest.json`.
  `dmx guest fetch --force` replaces it.
- A release whose guest archive differs but whose boot files do not is not downloaded again: the
  pin and `release.json` both carry every boot file's sha256, so comparing them is free, and only
  `release.json` is rewritten. 0.3.0 and 0.3.1 were this case (their archives differ in the
  version THIRD_PARTY.md names), so 0.3.1 users will not fetch 62 MB again for 0.3.2.
- If updating a guest from an older release fails (offline), the old guest boots.
- Cost: from a local server the download, check and unpack take 0.3 to 0.6 s. A daemon that
  downloaded keeps ~6 MB more footprint (10 MB instead of 4 with the VM stopped; CFNetwork) until
  it exits at idle; a later daemon does not.
- `dmx guest` shows where the guest came from; `dmx doctor` also hashes a downloaded guest
  against its release. Errors: `guest_download_failed`, `checksum_mismatch`, `no_guest_release`
  (a dmx built from source without a pin: run `make guest`).

## Cutting a release

1. Build the guest from a clean checkout: `make kernel`, `make qemu` and `make fex` if they changed,
   then `make guest`.
2. Set `dmxVersion` in `Sources/DMXCore/Version.swift` (the tag is `v<version>`).
3. Run the local checks. There is no CI: these need the real VM, which hosted runners cannot
   provide (no nested virtualization).

   ```sh
   make build && make test && make selftest
   make daemontest && make mcptest && make x86test && make dockertest
   make sandboxtest && make imagetest
   make javatest
   ```

4. Write what changed since the last release in `docs/release-notes/<version>.md`, starting with
   a `## Changes since <previous>` heading. `make release` folds it into NOTES.md and refuses to
   package a version without one (`--no-notes` to publish without a summary, `--notes <file>` for
   another path).
5. `make release VERSION=0.1.0` writes `.build/dist/v0.1.0/` and rewrites
   `Sources/DMXCore/GuestPin.swift` for the new guest. Commit the pin and the version
   ("Release v0.1.0"), then run `make release VERSION=0.1.0` again: it must say
   `"pin_changed": false`, so the binary in the directory is the one the commit builds.
6. Try the directory as a user would, from a local server:

   ```sh
   python3 -m http.server --bind 127.0.0.1 --directory .build/dist 23456 &
   export DMX_RELEASE_URL=http://127.0.0.1:23456
   DMX_HOME=$(mktemp -d) .build/release/dmx boot --selftest      # downloads the guest, boots it
   PREFIX=$(mktemp -d) sh .build/dist/v0.1.0/install.sh             # installs from the tarball
   ```

7. Point README's install line at the new tag (`releases/download/v<version>/install.sh`): it is
   the first thing a reader copies, and nothing generates it. Commit it with the release.
8. Tag and publish (the only steps that make anything public):

   ```sh
   git tag -a v0.1.0 -m "dmx 0.1.0" && git push origin main v0.1.0
   gh release create v0.1.0 --title "dmx 0.1.0" --notes-file .build/dist/v0.1.0/NOTES.md .build/dist/v0.1.0/*
   ```

## What is in the release directory

| File | What |
|---|---|
| `dmx-<version>-darwin-arm64.tar.gz` (+ `.sha256`) | `dmx` (signed with the maintainer's Developer ID, hardened runtime and the hypervisor entitlement, notarized; ad-hoc with `--ad-hoc` and in v0.1.0), `LICENSE`, `THIRD_PARTY.md` (swift-argument-parser) |
| `dmx-guest-<version>.tar.gz` (+ `.sha256`) | `Image`, `initramfs.gz`, `docker.img`, `manifest.json`, `THIRD_PARTY.md`, `LICENSES/` |
| `install.sh` | `scripts/install.sh` with the version and the tarball's sha256 written in |
| `kernel-<release>.config` | the exact config of the guest kernel |
| `kernel-<release>.build.py` | the build recipe, pinned inputs and exact reporting-budget source patch |
| `qemu-x86_64-<version>.build.py` | qemu-x86_64's recipe: pinned source, Alpine patches, guest-base patch, configure line |
| `fex-<version>.build.py` | FEX-Emu's recipe: pinned sources, musl and x86 compatibility patches, build configuration |
| `third-party.json` | every package in the guest and the binary: version, license, upstream, source |
| `dmx-sources-<version>.tar` (+ `.sha256`) | the complete corresponding source of the guest (README inside) |
| `NOTES.md` | release text: install line, assets, where the source is |
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
    exact `mm/page_reporting.c` free-list budget patch, the Asahi TSO patches and dmx's
    ACTLR_EL1 change, and refuses a source that does not match;
    its modified source must be included when delivering the corresponding kernel source.
  - FEX-Emu: pinned source, submodules, dmx's patches and `scripts/build-fex.py` under `fex/`
    in the source bundle; the release also attaches the recipe separately. Its third-party
    license notices, including Cephes, travel with the inventory and sources.

  Pointing at Alpine's and kernel.org's servers is not enough on its own: the distributor must
  make sure the source stays available as long as it offers the binaries. So every release
  attaches `dmx-sources-<version>.tar` (3a; 467 MiB for v0.1.0: kernel 148 MiB, QEMU 135 MiB,
  GCC 96 MiB, the rest small). `release.py` builds it without running anything from aports:
  each package's aports directory at its commit, plus every upstream file named in the
  APKBUILD's `sha512sums`, fetched from Alpine's distfiles mirror and checked against those
  sums; then the kernel and QEMU tarballs, patches, config and build scripts. The tar is
  byte-identical for the same inputs; downloads are cached in `<cache>/release-sources`.
- **Notices.** MIT and BSD licenses ask that the copyright notice travel with binaries. The SPDX
  texts carry placeholders, not each project's copyright line; those lines are in each package's
  source, which the attached bundle carries.

## Decisions (maintainer, 2026-10-25)

- **Version and tag scheme:** `v0.1.0`, SemVer, an ordinary GitHub release (not a draft). 0.x
  already says "early"; `install.sh` pins its own version. The guest archive carries the dmx
  version in its name and is re-uploaded with each release (62 MB), even when unchanged.
- **GPL source: attached (3a), no written offer.** `dmx-sources-<version>.tar` on the same release
  page counts as "equivalent access to copy the source code from the same place" (GPL-2.0
  section 3), so the obligation ends with the upload and nobody has to answer source requests
  for three years. It also carries the copyright notices MIT and BSD ask for. Attached to every
  release, whether or not the guest changed, so each release page is complete on its own.
- **Signing:** v0.1.0 is ad-hoc signed. From the next release (maintainer, 2026-10-25) the binary
  is signed with the Developer ID "Developer ID Application: MINHO YUN (V4YA23448U)" with the
  hardened runtime and a secure timestamp, and notarized, so managed Macs that allow only
  notarized software run it and a browser download asks once ("downloaded from the Internet …
  Open?") instead of being blocked. `release.py` does it (`sign_and_notarize`) with settings in
  `~/.dmx-signing/release.json`, outside the repository: a keychain kept only for signing (its
  password in a 0600 file; the login keychain is not reachable from a terminal session without a
  prompt) and the App Store Connect API key used for `notarytool`. A command-line tool cannot
  carry a stapled ticket, so Gatekeeper looks the ticket up online on first launch; about a
  minute after acceptance it is found (earlier, the launch was refused once). `curl … | sh` does
  not quarantine, so the install script works the same either way. `--ad-hoc` releases unsigned.
- **Name:** "dmx", described as Docker-compatible. No name containing "Docker" (Docker, Inc.'s
  trademark guidelines forbid names implying affiliation, and "Docker for Mac" was its own
  product); README carries the trademark notice.
- **CI**: none, by choice (2026-10-24). Hosted macOS runners could build and run `swift test`, but
  not the VM tests.
