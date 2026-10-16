---
status: accepted (built 2026-10-16)
date: 2026-10-16
supersedes: "[[ADR-059 Replay and Session Details]] (replay as its own tab over the content), [[ADR-013 Milestone 1 Slice]] (shell tabs), [[ADR-120 The Empty Screen Is A Home]] (the New Shell card)"
amends: "[[ADR-212 A Session Is A Workspace Of Tabs]] (step 3, built), [[ADR-168 A Project Can Arrive From A Git URL]] (the clone sheet's shell buttons), [[ADR-122 Projects Have Run Configurations]] (a run with no session to host it)"
tags: [adr, ui, tabs, terminal, replay]
---
# ADR-221: Terminals live in sessions, and replays in their Claude tab

## Context
Step 3 of [[ADR-212 A Session Is A Workspace Of Tabs]]: the user chose "only inside a session" for shells, and
*Replay…* opening a session not running, with the replay in its Claude tab and Resume in its header.

Since step 1, shell and replay tabs had no row anywhere. Eleven places opened a standalone shell. Some of them
typed a command into it (`claude mcp login`, `claude logs <agent>`, the clone sheet's ssh probe); others were a
run with no tab to host its pane, and Ghostty's own new-tab and split actions.

## Decision
- **`Tab.Kind` is a session or a replay.** The shell kind is gone, with `newShell`.
- **⌘T is *New Terminal Tab*** (the action keeps the id `newShell`, so a rebinding survives): a shell beside Claude
  in the selected session, disabled with none in view. Ghostty's new tab, window or split from inside a session does
  the same. The toolbar's New Shell button and the Home screen's New Shell cards are removed.
- **A shell for a folder, `openTerminal(in:initialInput:)`**, used by *Open Shell Here* (project menu, quick action,
  Pull sheet), MCP login and an agent's *Show Logs*. It opens a terminal tab beside Claude in the open session
  working there — the selected one, else one in that folder, else one in that project. With none, it opens the
  user's own terminal app, which also takes over the clone sheet's *Connect in a Shell* and *Open Shell Here*
  (`openExternalTerminal`). Ghostty runs a command in a login shell that stays open afterwards; Terminal, the
  fallback, is opened in the folder with the command put on the pasteboard.
- **A run started from the project menu with no session in its checkout** runs without a pane. The toolbar's pill
  reports it, and any session in the checkout can show it.
- **A replay is a workspace.** It is hosted like a session, its transcript fills the main area where Claude would
  be, and its chip is *Replay* with a play glyph. The header shows the *Replay* pill and a **Resume** button, and
  its menu offers *Close Replay*. Resuming — from the header, the sidebar or anywhere that opens the session —
  closes the replay and opens the running session. *Replay…* on a session that is running shows that session
  instead. A replay has no footer, since there is no model, effort or context to show.

## Consequences
- The `-ClinicOpenShellOnLaunch` seam is gone. The panel seams that hung off it act on the tab
  `-ClinicSessionOnLaunch` opens.
- A replay's views beside it (Files, Diff) can be opened by hand. Layouts are not saved
  ([[ADR-223 A Session Comes Back Fresh]]).

## Verification
In Clinic Dev with `-ClinicOpenSessionOnLaunch <id> -ClinicReplayOnLaunch YES`, the replay showed in the main area
under a *Replay* chip, with the pill and a filled Resume in the header, and *New Terminal Tab* disabled. Pressing
Resume (through the accessibility API) replaced it with the running session, which showed *Idle* and its footer.
*File ▸ New Terminal Tab* then opened a shell beside Claude. Not driven: the outside-terminal fallback, MCP login,
*Show Logs*, and a run from the project menu with no session.
