---
status: accepted
date: 2026-09-07
tags: [adr, sessions, ui]
---
# ADR-041: One Tab Per Session

## Decision
A session id is open in at most one tab. Selecting an already-open session focuses its tab. Enforced in `TabStore`, not in the UI.
