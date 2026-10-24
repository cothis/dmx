#!/bin/sh
# Installs dmx from a GitHub release into ~/.local/bin, without sudo, Homebrew, Xcode, Python or
# Rust. The copy published with a release has its version and the binary tarball's sha256
# written in by scripts/release.py:
#
#   curl -fsSL https://github.com/cothis/dmx/releases/download/v0.1.0/install.sh | sh
#
# Environment:
#   DMX_VERSION      another version than the one written in (its sha256 then comes from the
#                    .sha256 file next to the tarball, so only the transfer is checked)
#   DMX_RELEASE_URL  base URL instead of https://github.com/cothis/dmx/releases/download;
#                    files are <base>/v<version>/<name>
#   PREFIX           install into $PREFIX/bin instead of ~/.local/bin
#
# It touches nothing but $PREFIX/bin/dmx: no shell profile, no launchd, no ~/.dmx.
set -eu

release_version=""
release_sha256=""

version="${DMX_VERSION:-$release_version}"
base="${DMX_RELEASE_URL:-https://github.com/cothis/dmx/releases/download}"
base="${base%/}"
prefix="${PREFIX:-$HOME/.local}"

fail() {
    echo "dmx install: $*" >&2
    exit 1
}

[ -n "$version" ] || fail "no version: set DMX_VERSION, or use the install.sh published with a release"
[ "$(uname -s)" = Darwin ] || fail "dmx runs on macOS only"
[ "$(uname -m)" = arm64 ] || fail "dmx needs an Apple Silicon Mac (this is $(uname -m))"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || fail "dmx needs macOS 15 or later (this is $(sw_vers -productVersion))"

name="dmx-$version-darwin-arm64.tar.gz"
url="$base/v$version/$name"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# --proto-redir keeps a redirect from downgrading https to http.
fetch() {
    curl -fsSL --proto-redir =https --retry 3 -o "$2" "$1" || fail "cannot download $1"
}

echo "downloading $url"
fetch "$url" "$tmp/$name"
if [ "$version" = "$release_version" ] && [ -n "$release_sha256" ]; then
    want="$release_sha256"
else
    fetch "$url.sha256" "$tmp/$name.sha256"
    want="$(cut -d' ' -f1 < "$tmp/$name.sha256")"
fi
got="$(shasum -a 256 "$tmp/$name" | cut -d' ' -f1)"
[ "$got" = "$want" ] || fail "sha256 mismatch for $name: got $got, expected $want"

tar -xzf "$tmp/$name" -C "$tmp" dmx
mkdir -p "$prefix/bin"
# Through a temporary name in the same directory, so a running dmx keeps its old file.
install -m 755 "$tmp/dmx" "$prefix/bin/.dmx.new"
mv -f "$prefix/bin/.dmx.new" "$prefix/bin/dmx"
installed="$("$prefix/bin/dmx" --version)" || fail "$prefix/bin/dmx does not run"
echo "installed dmx $installed to $prefix/bin/dmx"

case ":$PATH:" in
    *":$prefix/bin:"*) dmx=dmx ;;
    *)
        dmx="$prefix/bin/dmx"
        echo
        echo "$prefix/bin is not on your PATH. Add it, e.g. for zsh:"
        echo "  echo 'export PATH=\"$prefix/bin:\$PATH\"' >> ~/.zprofile"
        ;;
esac
cat <<EOF

Next steps:
  $dmx install
      launchd starts dmx on demand; adds a docker context named dmx
  $dmx guest fetch
      downloads the Linux guest now (otherwise the first boot does)
  $dmx exec -- uname -a
      boots the VM and runs a command in it
EOF
if [ -f "$HOME/Library/LaunchAgents/io.github.cothis.dmx.plist" ]; then
    echo
    echo "dmx is already set up with launchd: run \`$dmx install\` again to point it at this copy."
fi
