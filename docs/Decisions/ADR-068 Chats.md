---
status: accepted
date: 2026-09-07
tags: [adr, sessions, ui, milestone-4]
---
# ADR-068: Chats — sessions without a repository

## Context
Milestone 4 batch 7. Collins has a pinned "Chats" virtual project: a throwaway, pre-trusted directory per chat for questions that need no project. Clinic cannot pre-trust directories ([[ADR-018 Claude Data Write Policy]]), so a directory per chat would prompt for trust every time.

## Decision
- One shared scratch directory, `~/Library/Application Support/Clinic/Chats/`, is the working directory of every chat, so trust is answered once. Its sessions group under a pinned **Chats** project (speech-bubble icon) at the top of the sidebar.
- "New Chat" (Session menu ⌥⌘N, Chats header menu, header click) starts a session there with the default model; the New Session sheet is skipped.
- ~~The Chats project is hidden until it has a session; Remove Project hides it again until the next chat.~~ (superseded by [[ADR-077 Persistent Projects and Sidebar Polish]]: Chats is always pinned at the top, empty or not, and is not removable.)

## Consequences
- `ClinicPaths.chatsDirectory`; `SessionStore` pins the chats path first regardless of manual order.
