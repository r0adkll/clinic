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
| swiftlang/swift-cmark (cmark-gfm, cmark-gfm-extensions) | 0.9.0 | BSD-2-Clause | GitHub-flavoured Markdown to HTML for the Files pane's preview ([[ADR-191 The Files Pane Renders Markdown]]) |
| mermaid (`dist/mermaid.min.js`, vendored in `Sources/Clinic/Vendor/Mermaid`, not a Swift package) | 12.0.0 | MIT | diagrams in the Markdown preview ([[ADR-193 The Preview Highlights Code, Finds Text And Draws Diagrams]]) |
| grpc/grpc-swift-2 (GRPCCore), grpc/grpc-swift-nio-transport (GRPCNIOTransportHTTP2, with swift-nio and swift-nio-ssl), grpc/grpc-swift-protobuf (GRPCProtobuf), apple/swift-protobuf | 2.4.4, 2.11.0, 2.5.0, 1.39.0 | Apache-2.0 | the Android emulator's gRPC control service for the Device pane, through `Packages/AndroidEmulator` ([[ADR-224 Emulators Run In A Device Pane]]) |

Build note: CodeEditSourceEditor uses the SwiftLint build plugin; `xcodebuild` runs pass `-skipPackagePluginValidation -skipMacroValidation` (Makefile, CI, release script).

## Consequences
- Sparkle becomes a normal dependency when signing lands ([[ADR-010 Distribution]]).
- ClinicCore stays Foundation-only so its tests remain fast; packages attach to the app target.
