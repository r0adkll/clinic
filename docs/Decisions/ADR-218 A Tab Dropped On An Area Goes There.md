---
status: accepted (built 2026-10-15; the drag awaits a check by hand)
date: 2026-10-15
amends: "[[ADR-215 Tabs Move By Dragging]] (the payload's type, and drops on an area's content)"
tags: [adr, ui, tabs, panel, drag]
---
# ADR-218: A tab dropped on an area goes there

## Context
User (2026-10-15): *"Another nice design item is when dragging a tab, if we enter a "zone" far enough on the right
(or the bottom when we implement a bottom panel) it should show us some indication that dropping the tab will open
it into a right panel"*.

Building it found a fault in [[ADR-215 Tabs Move By Dragging]]: the dragged tab was text (`clinic-pane:<id>`), and
`GhosttySurfaceView` registers for `.string`, `.fileURL` and `.URL`. A tab released over Claude or a shell was
pasted into the terminal.

## Decision
- **A tab drags as Clinic's own type**, `com.r0adkll.clinic.pane` (`PaneDragItem`, a Codable id), declared under
  `UTExportedTypeDeclarations` in `project.yml`. No terminal or other app takes it.
- **`TabContentView` is a drop target for it.** The surfaces do not register for the type, so a drag over a terminal
  or a page passes up to it. The strips keep their own drops (before a chip, or at the end).
- **The zones** (`PaneDropZones`, in ClinicCore, tested):
  - With the right panel hidden, the main area's right edge — a quarter of its width, 140 pt at least, half at
    most — means *Open in Right Panel*. The drop shows the panel with the tab in it.
  - With the panel showing, its content means the right panel, and there is no edge zone.
  - The rest of the main area takes a tab from the panel: *Move Beside Claude*.
  - Over its own area a tab has no zone, since nothing would change.
- **What shows:** an accent wash with an accent border over the zone, and the drop's words in its middle
  (`DropZoneHighlightView`), which takes no mouse events.
- **A bottom area**, when it comes, is another `Area` and another edge in `PaneDropZones.target`.

## Consequences
- A drop on content goes to the end of the area. A place between tabs is still chosen on the strip.
- **Not driven by a script**, for the reason ADR-215 gives: this session cannot post synthetic events. The zones are
  covered by 5 tests. The type was checked in the built app's `Info.plist`, and Clinic Dev was launched and a tab
  opened. To check by hand:
  1. With the panel hidden and Files open beside Claude, drag the Files chip down into the terminal and towards
     the right edge. *Open in Right Panel* lights up over the edge, and nothing lights up over the rest. Dropping
     there opens the panel with Files in it, and nothing is typed into the terminal.
  2. Drag Files from the panel's strip over the main area. *Move Beside Claude* covers it. Drop it, and it is
     back beside Claude.
