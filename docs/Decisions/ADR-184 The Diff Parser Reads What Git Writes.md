---
status: accepted (built 2026-10-06)
date: 2026-10-06
amends: "[[ADR-080 Diff Panel]] (the snapshot command), [[ADR-100 Diff Body Is A Text View]] (what a document line may hold)"
tags: [adr, git, diff, parser, snapshots]
---
# ADR-184: The diff parser reads what git writes

## Context
From the 2026-10-06 review (see [[ADR-183 The Diff Panel Has One Loader]]). Four inputs the first fixtures
never held, each measured before it was fixed.

- **A CRLF file parsed as one line.** `UnifiedDiff.parse` split its text on the `Character` `"\n"`. In Swift
  `"\r\n"` is a single `Character` and does not equal `"\n"`, so no line of a CRLF hunk was split from the
  next. A four-line hunk parsed as one context line, `+0 −0`. The text view then broke it at every `\r\n`
  and drew four lines under one line number.
- **A line separator inside a line shifted everything below it.** [[ADR-100 Diff Body Is A Text View]] rests
  on line *n* being at `n × lineHeight`. A TextKit 2 harness built like the coordinator showed that holds
  exactly for 8,000 lines of ASCII, CJK, emoji and tabs. A U+2028 or a form feed inside a line makes the text
  view break there, and every tint and line number after it is one line off per occurrence.
- **Non-ASCII paths arrived as octal.** With `core.quotepath` at its default git writes `café.txt` as
  `"caf\303\251.txt"`. The parser's unquoting handled `\"`, `\t` and `\\` only.
- **A tracked file that matches `.gitignore` read as deleted.** [[ADR-080 Diff Panel]] specified
  `read-tree HEAD && add -A && write-tree`. The code ran `add -A` alone against the scratch index, and
  `add -A` leaves out an ignored file even when the repository tracks it. Against `HEAD` its absence is a
  deletion, and its edits were invisible to every turn.

## Decision
- **Lines are split on the scalar `\n`.** A trailing `\r` is the line's ending, not its text: it is taken
  off and recorded as `DiffLine.endsWithCarriageReturn`, and patches built from the line put it back.
- **A diff that only changes line endings says so.** `UnifiedDiffFile.changesOnlyLineEndings` is true when
  every changed line has the same text as its counterpart and a different ending. The viewer names it
  ([[ADR-188 The Diff Panel Is For Reviewing]]) where it used to show every line replaced by itself.
- **One document line is one visual line.** `DiffDocument.displayText` replaces the characters a text view
  breaks at — a carriage return inside a line, vertical tab, form feed, U+0085, U+2028, U+2029, NUL — with
  visible stand-ins (`␍ ␋ ␌ ␤ ¶ ␀`) of the same UTF-16 length, so token ranges computed against the original
  still address the same characters.
- **Paths are UTF-8.** Every git process runs with `-c core.quotepath=off`. The parser also decodes git's
  C-style quoting in full, octal bytes as UTF-8, for a diff that did not come from Clinic's own git: a pull
  request's.
- **The snapshot adds what the repository tracks despite `.gitignore`.** After `add -A`, the user's own
  index is asked which files are both tracked and ignored (`ls-files -ci --exclude-standard`, read-only),
  and those still on disk are added with `add -f`. Seeding with `read-tree HEAD` on every snapshot would
  throw away the scratch index's stat cache, which is what makes a repeat snapshot cheap.

## Consequences
- `DiffHardeningTests` holds a fixture for each case, and `DiffTargetTests` for the ignored file.
- A snapshot costs one more git process. Measured at 40 ms on Campfire and under 10 ms here.
- Stand-in characters are for display. A copy out of the body copies the stand-in, not the original.
