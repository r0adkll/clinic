---
status: accepted
date: 2026-09-07
tags: [adr, architecture, ui]
---
# ADR-005: UI Framework

## Context
libghostty needs an NSView host with a Metal layer. Ghostty's own macOS app is SwiftUI with heavy AppKit bridging; Supacode and Cormac follow the same pattern.

## Options
1. SwiftUI `App` lifecycle with AppKit escape hatches
2. AppKit app with SwiftUI views embedded

## Decision
Option 1. SwiftUI `App` lifecycle, `NavigationSplitView` for the sidebar, an `NSViewRepresentable` wrapper per libghostty surface. Drop to AppKit for window management, menus and split views when SwiftUI fights us.

## Consequences
- Follows the proven Ghostty structure, so upstream Swift code is a reference for every bridging problem.
- Terminal views must be kept alive across SwiftUI view identity changes; surface lifetime is owned by a model object, not the view.
