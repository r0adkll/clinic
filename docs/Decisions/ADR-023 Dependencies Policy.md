---
status: superseded by ADR-058
date: 2026-09-07
tags: [adr, build]
---
# ADR-023: Dependencies Policy

## Decision
Zero third-party Swift packages in milestone 1. libghostty is the only external code. Sparkle arrives with the first tagged release.

## Consequences
- Networking, sockets, JSON, file watching all use Foundation, Dispatch and POSIX.
