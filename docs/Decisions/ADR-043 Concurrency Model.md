---
status: accepted
date: 2026-09-07
tags: [adr, architecture]
---
# ADR-043: Concurrency Model

## Decision
`@Observable` stores isolated to `@MainActor`: `ProjectStore`, `SessionStore`, `TabStore`, `NotificationStore`. Actors for the transcript scanner, hook socket server and file watching. All libghostty calls on the main actor. Hook payloads cross to the main actor as typed `HookEvent` values.
