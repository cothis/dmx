# Product

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS, Apple Silicon, macOS 15 or later.

## Users

Developers running Docker-compatible containers locally, through the Docker CLI, Compose,
agent tools, or the manually launched dmx app. Confirmed by PLAN.md and the maintainer's
2026-10-29 app discussion.

## Product Purpose

Run containers with memory that returns to macOS when unused. Preserve CLI compatibility
and structured errors; add convenient status and container controls without idle UI residency.

## Capabilities and Constraints

The maintainer approved a launchable dmx.app with a menu bar item: engine status and memory,
container listing/start/stop, errors and normal shutdown. Launching the app starts the engine;
normal app quit stops it. Idle engine shutdown also closes the app. CLI use remains independent.
No menu login item, repeated background status polling, or fixed guest memory reservation.
Memory/CPU figures must be measured rather than inferred from the icon's apparent simplicity.

## Brand Commitments

Keep the name dmx and the existing public repository's English product terminology.
The requested macOS utility surface uses native menus and familiar platform interactions.

## Evidence on Hand

docs/PLAN.md holds implementation decisions and real-VM measurements. Existing public releases
are CLI releases; the new app requires separate packaging, visual and lifecycle verification.
