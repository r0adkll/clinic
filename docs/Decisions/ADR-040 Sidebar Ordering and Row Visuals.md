---
status: accepted
date: 2026-09-07
tags: [adr, ui]
---
# ADR-040: Sidebar Ordering and Row Visuals

## Decision
Projects ordered by most recent session activity (~~superseded~~: registration order, [[ADR-077 Persistent Projects and Sidebar Polish]]); sessions within a project by last activity descending; open tabs are not pulled to the top. Row = state glyph + name + relative time. Glyphs: animated dot `working`, orange dot waiting states, blue dot `unread`, hollow dot `exited`, none for sessions not open in Clinic. Colors are system semantic colors. Archived sessions are hidden in milestone 1.
