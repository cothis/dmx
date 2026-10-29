# Public v0.4.0 qualification

Run on macOS from the repository root, with the original qualified local distribution in
`.build/dist/v0.4.0/` and the independently downloaded 14 public files in
`.build/menu-release-review/public-v0.4.0/`. Do not populate the expected distribution from the
public downloads: the byte comparison would then lose its independent reference.

`python3 -I docs/reviews/2026-10-29-menu-opus55/public-verification/verify.py`

The script creates isolated temporary VM homes, app installations, CLI prefixes and Docker
configuration, then cleans up its daemons. It checks the public installer, pinned guest,
selftest23, arm64/amd64/386, whole-app update and migration from the previous public CLI with
VM PID, running container and named-volume preservation. Signature, ticket and Gatekeeper
checks run on every installed/updated app. All 14 final checks pass; the full report is in
[the release measurements](../../../measurements/2026-10-29-release-0.4.0.json).

The first run stopped after a harness error: it read the guest tag from the JSON root rather
than `guest.tag`. The actual report had the correct tag, pin and files. The failed report and
actual output are retained here. The corrected script reran in a fresh environment; no product
code changed. Its SHA256 is `cf36e3211a53240b5d954da566e1c48ec9f5c3e7dcccf9f951e35c4f6235f863`; the image matrix SHA256 is `ec5c48ce7f25e39817ae13ca2fc5119ee7c6a2157e73bafe745f51d3731d86e1`.
Direct GUI Start/Stop/Quit input remains a separate manual acceptance item.
