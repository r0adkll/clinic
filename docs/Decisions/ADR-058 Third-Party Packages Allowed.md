---
status: accepted
date: 2026-09-07
supersedes: ADR-023
tags: [adr, build, dependencies]
---
# ADR-058: Third-party Swift packages are allowed when they replace substantial work

## Context
[[ADR-023 Dependencies Policy]] set zero third-party packages for milestone 1. The editor panel ([[ADR-057 Editor Panel]]) needs syntax highlighting; a hand-written tokenizer would be a permanent maintenance cost for mediocre results. User (2026-09-07): "using 3rd party packages is okay."

## Decision
Vetted third-party packages are allowed when they replace substantial work. Bar: actively maintained, permissive licence, SwiftPM, macOS 15-compatible, no network access at runtime unless that is the feature. Each adoption is recorded here.

| Package | Version | Licence | Purpose |
|---|---|---|---|
| CodeEditApp/CodeEditSourceEditor (+ CodeEditTextView, CodeEditLanguages, SwiftTreeSitter) | 0.15.2 | MIT | tree-sitter source editor for the editor panel |

Build note: CodeEditSourceEditor uses the SwiftLint build plugin; `xcodebuild` runs pass `-skipPackagePluginValidation -skipMacroValidation` (Makefile, CI, release script).

## Consequences
- Sparkle becomes a normal dependency when signing lands ([[ADR-010 Distribution]]).
- ClinicCore stays Foundation-only so its tests remain fast; packages attach to the app target.
