---
name: dmx
description: Native macOS engine controls with a quiet container-block app icon.
colors:
  app-icon-mint: "rgb(79% 91% 86%)"
  app-icon-slate: "rgb(12% 16% 21%)"
---

# Design System: dmx

## Overview

**Creative North Star: "Native engine controls"**

dmx is a compact macOS utility. Its interface uses AppKit menus, SF Symbols and a native
alert, letting macOS own appearance, typography, keyboard navigation and control spacing.
The manually launched app lives in the menu bar while its engine is in use.

The custom identity is confined to the app icon: three mint container blocks on a slate
ground. These artwork colors do not theme the menu or its controls.

**Key Characteristics:**

- Native platform appearance and accessible text status.
- Compact information followed by direct container actions.
- A simple container-block silhouette for the app icon.

## Colors

The app icon pairs a pale mint foreground with an opaque slate ground. The frontmatter
preserves the exact sRGB channel values in [the artwork source](scripts/draw-app-icon.swift).

### Primary

- **App Icon Mint** (`app-icon-mint`): the three container blocks in the app icon.

### Neutral

- **App Icon Slate** (`app-icon-slate`): the rounded ground behind those blocks.
- **macOS semantic appearance**: menu text, disabled text, selection, separators and alert
  controls are supplied by AppKit; no custom color values are assigned to them.

**The Artwork Boundary Rule.** Keep the mint/slate palette in the app icon. Native menu and
alert appearance follows macOS, including the user's appearance and accessibility settings.

## Typography

NSMenu, NSMenuItem and NSAlert use their native system typography. The app assigns plain
strings and does not override font family, size, weight, line height or tracking. There is
no custom typography scale to export as tokens.

Status, memory and section labels are non-actionable menu rows. Action titles retain normal
macOS menu treatment; disabled controls use the platform's disabled presentation.

## Layout

A square-length NSStatusItem opens a native NSMenu. AppKit determines menu width, row height,
submenu placement, separators and scrolling. There is no persistent content window or custom
responsive grid.

The menu places engine status and available memory figures first, then error recovery when
needed, container rows, Refresh, Open logs and Quit dmx. Separators divide these groups.
Each container opens a submenu with its image, status and one Start or Stop action.

Menu titles have newlines flattened to spaces and are shortened beyond 72 characters to a
69-character prefix plus an ellipsis. Container rows retain the full name and status in a
tooltip; the image row retains its full image value in a tooltip. The menu lists up to 100
containers and points larger lists to `docker ps -a`.

## Elevation & Depth

Menus, submenus and alerts inherit macOS materials, borders and shadows. The app defines no
custom elevation or shadow tokens. The icon source draws flat, filled shapes without its
own shadow or gradient.

## Shapes

The app icon has a rounded square ground and three equal rounded rectangular container
blocks, arranged as one above two. Its 1024-unit artwork geometry, scaling and output sizes
come from [scripts/draw-app-icon.swift](scripts/draw-app-icon.swift) and are recorded in
[the native artwork sidecar](.impeccable/design.json). Those dimensions are artwork
coordinates, not a radius or spacing scale for AppKit controls.

The status item uses template SF Symbols: `shippingbox` while starting or stopping,
`shippingbox.fill` while running, and `exclamationmark.triangle` for an error. Container rows
use `play.circle.fill` or `stop.circle`. No custom control outlines or corner radii are set.

## Components

### Status item and menu

The status item exposes the engine phase through its accessibility label and tooltip as
well as its symbol. Text in the menu states the phase explicitly. Opening the menu requests
fresh engine and container data; loading, empty and error states have visible text.

### Container submenu

Each row names a container and shows its running/stopped symbol. The submenu presents image
and status as disabled information rows, followed by Start or Stop. Container actions are
disabled while another container action runs, during shutdown, or outside the running phase.
Refresh is also disabled while a refresh is active.

### Error alert

A modeless native warning NSAlert uses the title “dmx needs attention”, the error message,
an optional recovery hint separated by a blank line, and one OK button. OK dismisses the
alert while the menu retains Show error and Retry recovery. Reopening the app can show the
outstanding error again. There is no custom dialog layout, button styling or animation.

Verification scope: the error alert has a captured native screenshot. Full menu/submenu
screenshots and a GUI container action remain unverified; this document records their source
configuration and does not claim whole-interface visual approval.

## Do's and Don'ts

### Do

- Do use native AppKit controls and semantic appearance for menus, submenus and alerts.
- Do pair status symbols with text, tooltips and accessibility labels.
- Do preserve the app icon's source colors and three-block geometry.
- Do keep information, recovery and container actions grouped by native menu separators.

### Don't

- Don't apply the icon palette as custom menu or alert colors.
- Don't invent fixed font, spacing, radius or shadow tokens for native defaults.
- Don't replace native menu navigation with a custom dashboard or persistent content window.
- Don't use color alone to communicate engine or container state.
