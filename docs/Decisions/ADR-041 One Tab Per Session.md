---
status: accepted (a tab is now a session's workspace, ADR-212)
date: 2026-09-07
superseded-by: "[[ADR-212 A Session Is A Workspace Of Tabs]] (the session's tab is a workspace with its own tabs)"
tags: [adr, sessions, ui]
---
# ADR-041: One Tab Per Session

## Decision
A session id is open in at most one tab. Selecting an already-open session focuses its tab. Enforced in `TabStore`, not in the UI.
