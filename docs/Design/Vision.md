# Vision

Clinic is a native macOS app for people who run many Claude Code sessions at once and want one place to see them, switch between them, and know which one needs them. It is a reimplementation of [Collins](https://github.com/episode6/collins) for macOS (see [[Collins]]), with the real `claude` CLI running unmodified inside libghostty terminals (see [[libghostty]]).

Built first for the author's own daily work ([[ADR-001 Audience]]), structured to be publishable ([[ADR-010 Distribution]], [[ADR-011 Repo Naming and License]]). Collins is the milestone 1 spec ([[ADR-002 Collins as the Milestone 1 Spec]]); after that Clinic goes its own way.

What makes it different from just running Ghostty tabs:
- Sessions are the unit, not terminals. The sidebar is built from Claude Code's own session store on disk.
- State is known, not guessed: hooks tell Clinic when a session is working, waiting, or done ([[ADR-003 Claude Code Integration Model]]).
- Every terminal is a real Ghostty surface with the user's own config ([[ADR-009 Terminal Configuration Source]]).
