| # | Action | Code | Changed |
|---|---|---|---|
| 1 | `Init` |  | `slot` = "original"; `lateAcquire` = FALSE; `closed` = FALSE; `phase` = [reader \|-> "idle", writer \|-> "idle"]; `calls` = [reader \|-> 0, writer \|-> 0]; `foreignIO` = FALSE |
| 2 | `Submit("reader")` | Sources/DMXCore/Agent.swift:315-318 | `phase` = reader \|-> "pending" (changed keys) |
| 3 | `Acquire("reader")` | Sources/DMXCore/Agent.swift:232-239 | `phase` = reader \|-> "active" (changed keys) |
| 4 | `Close` | Sources/DMXCore/Agent.swift:155-161 | `slot` = "free"; `closed` = TRUE |
| 5 | `Reuse` | Tests/DMXCoreTests/FrameConnectionTests.swift:1 | `slot` = "foreign" |
| 6 | `Transfer("reader")` ⚠ | Sources/DMXCore/Agent.swift:246-264 | `calls` = reader \|-> 1 (changed keys); `foreignIO` = TRUE |
