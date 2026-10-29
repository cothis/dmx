---
version: 1
slug: "sources-dmxapp-main-swift"
primary_target: "Sources/DMXApp/main.swift"
related_targets: ["Sources/DMXCore/MenuEngine.swift"]
---

# Native menu app

Mode: Operate. Audience: developers using dmx on macOS. Approved in the 2026-10-29 conversation:
manually launch dmx.app, control containers/status/memory, and close the UI with normal engine
shutdown. Preserve independent CLI use. No menu login item or periodic status polling.

## Direction contract

THESIS: Native, manually activated engine controls whose process disappears when unused.

OWN-WORLD: macOS NSMenu typography, semantic appearance, SF Symbols; slate/mint container-block
app icon drawn by scripts/draw-app-icon.swift. No custom dashboard or persistent content window.

STORY: Launch the app, inspect engine/containers, start or stop a container, then Quit dmx.
Failures explain the problem and recovery while preserving the engine's existing data.

FIRST VIEWPORT: A compact menu with engine state/memory at top, container submenus in the middle,
Refresh/logs below, and Quit at the bottom. Busy actions disable; empty/loading/error are explicit.

FORM: Precisely specified native utility; code-first. No concept roll for this narrow surface.
seed: none (unavailable)

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
