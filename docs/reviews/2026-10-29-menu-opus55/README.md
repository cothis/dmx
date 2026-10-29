# Native app release review

The maintainer requested actual Opus 5.5 review and release after defects were resolved.
The Claude CLI ran read-only against immutable Git index/archive snapshots, with
`claude-opus-5-5` requested and observed in both initialization and assistant messages.
Original Korean reports are preserved without rewriting; model metadata omits private
verbose environment/provider output. These are code reviews, not tests run by the reviewer.

| Stage | Code gate | Outcome |
|---|---|---|
| initial | needs-fixes | Operation/lifecycle errors,304, CLI independence, cancellation and secondary races |
| second | needs-fixes | Postboot setup failure and first-download deadline |
| third | needs-fixes | Late startup snapshot, overlapping passive lease and identity-check order |
| fourth | approve | All correctness findings resolved; one cosmetic Retry timing issue |
| final | approve | Cosmetic fix, generated guest pin and identity regression verified |

Runtime source in the final reviewed index matches the release; later changes are docs and
additional qualification tests. The deterministic state regression and actual native app
callbacks have different proof scopes. Direct container/Quit GUI clicks remain a manual
acceptance item. See [release measurements](../../measurements/2026-10-29-release-0.4.0.json)
and [menu app guide](../../menu-app.md). Signing, final installer roundtrip and public
download verification follow code approval; code approval alone is not publication evidence.
