---
status: accepted (tab bar superseded by ADR-049)
date: 2026-09-07
tags: [adr, ui, architecture]
---
# ADR-019: Window and Surface Lifetime

## Context
Collins uses one window, the sidebar as navigation, and a hidden tab bar. Hidden libghostty surfaces keep rendering unless occluded (cmux patched upstream for GPU reclamation).

## Decision
One window. The sidebar is the tab strip; no visible tab bar. Every open session owns one live surface for its whole life; unselected surfaces receive `ghostty_surface_set_occlusion(false)` so they stop rendering. Surface lifetime belongs to a session model object, never to a SwiftUI view. Multiple windows are milestone 2+.

## Consequences
- The content area swaps which `NSView` is visible; it never recreates surfaces on selection change.
- A `TabStore` (MainActor) owns the surfaces and their processes.
