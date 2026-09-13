---
status: accepted (built 2026-09-13)
date: 2026-09-13
amends: "[[ADR-016 Launch Shape]] (what a session's shell inherits from Clinic)"
tags: [adr, terminal, environment, milestone-4]
---
# ADR-145: Clinic's terminals do not inherit Xcode's debugger

## Context
User (2026-09-13): *"Attempting to open my Campfire project (at a worktree) results in Android Studio
crashing."*

Android Studio Preview aborted three to five seconds after launch, every time, opening
`.claude/worktrees/shiny-frolicking-quasar`. Four crash reports, one stack:

```
GrMtlGpu::onGetOpsRenderPass → GrMtlOpsRenderPass::setupRenderCommandEncoder
  → -[CaptureMTLCommandBuffer renderCommandEncoderWithDescriptor:]     (GPUToolsCapture)
  → _MTLDebugValidateRenderPassDescriptorAndTrackAttachments           (MetalTools)
  → __assert_rtn → abort                                               (JVM: AWT-EventQueue-0)
```

`MetalTools` and `GPUToolsCapture` are the Metal API validation layer and the frame-capture shim. They
are not in a JetBrains IDE unless something puts them there, and the loaded-image list said what did:
`libViewDebuggerSupport.dylib` and three inspection frameworks, all out of `Xcode.app`.

They came from us. Clinic was running from Xcode, whose environment is:

```
DYLD_INSERT_LIBRARIES=…/libMainThreadChecker.dylib:…/GPUToolsCapture:…/libViewDebuggerSupport.dylib
DYLD_LIBRARY_PATH=…/DerivedData/Clinic-…/Build/Products/Debug:/usr/lib/system/introspection
DYLD_FRAMEWORK_PATH=…/DerivedData/Clinic-…/Build/Products/Debug/PackageFrameworks
METAL_DEVICE_WRAPPER_TYPE=1   METAL_LOAD_INTERPOSER=1   MallocNanoZone=1   OS_ACTIVITY_TOOLS_*
```

Shells spawned by libghostty inherit Clinic's environment — [[ADR-016 Launch Shape]] wants that, because
a session's shell should be the user's shell. What it should not inherit is Xcode's opinion of how
*Clinic* should be debugged. Read from inside a live Clinic session, the shell two levels below the app
carries `METAL_DEVICE_WRAPPER_TYPE=1`, `METAL_LOAD_INTERPOSER=1`, `MallocNanoZone`, `OS_ACTIVITY_TOOLS_*`
and `__XPC_DYLD_FRAMEWORK_PATH`. `METAL_DEVICE_WRAPPER_TYPE` alone is the validation layer, and the
validation layer alone is the abort.

**Which hop launched the crashed Studio is not pinned down**, and does not need to be: the variables are
Clinic's either way. `/usr/bin/login`, which every session shell goes through, is setuid and so makes
dyld drop `DYLD_*` — yet the crashed Studio had `/usr/lib/system/introspection/libdispatch.dylib` and
the Xcode debugger dylibs loaded, which needs `DYLD_LIBRARY_PATH` and `DYLD_INSERT_LIBRARIES` intact. The
likeliest route is therefore not the terminal but **Open In** ([[ADR-078 Open In Targets and Quick Action]]),
whose `.app` case hands the path to `NSWorkspace.open`: LaunchServices revives `DYLD_*` from the caller's
`__XPC_DYLD_*` on the far side of the launchd handoff, which also explains why the report names `launchd`
as Studio's parent. Every candidate route begins in the same place, so the fix belongs at the source
rather than at any one of them.

The crash is not Android Studio's and not the worktree's. **The worktree was a red herring** — the path
was simply what the user happened to be opening, and the stable Studio, launched from the Dock, had the
same project open the whole time without trouble.

This is the same defect as `scrubInheritedClaudeEnvironment`, which already unsets `CLAUDECODE` and
friends for exactly this reason. That one was found because Clinic mis-*read* the inherited variables.
This one escaped because Clinic never reads these — it only passes them on, to a program that does.

## Decision

### Xcode's diagnostics stop at Clinic
A sibling scrub runs beside the Claude one at `applicationDidFinishLaunching`, unsetting everything
Xcode injects for its own instrumentation: any `DYLD_`, `METAL_`, `MTL_`, `__XCODE` or `__XPC_DYLD`
variable, plus the malloc, zombie and `OS_ACTIVITY_TOOLS_*` switches.

dyld read these before `main`, so unsetting them changes nothing for the running Clinic and everything
for its children. A Clinic launched from Finder, `open`, or a release build has none of them, so the
scrub is a no-op there.

### The rule this settles
**A terminal Clinic opens is the user's shell, not Clinic's debugger.** Anything in Clinic's environment
that exists to instrument *Clinic* is ours to consume and ours to remove; only what the user's login
shell would have had should reach a session. Inheritance is the default because the shell needs it, and
every exception to it needs to be listed somewhere — there are now two such lists, and they sit together.

`DYLD_*` is the sharpest case and the reason to scrub by prefix rather than name the three that bit us:
it pointed at Clinic's DerivedData, so *any* program started from a Clinic terminal was being offered
Clinic's debug dylibs first. Studio was the one that died loudly.

## Consequences
- Debugging Clinic from Xcode no longer contaminates the sessions it hosts. The main-thread checker and
  view debugger still work on Clinic itself, which is what they were enabled for.
- Anything that genuinely wanted a `DYLD_*` or `MTL_*` variable in a Clinic session must set it in the
  shell, not inherit it. Nothing does today.
- Clinic must not lazily `dlopen` a framework that only `DYLD_FRAMEWORK_PATH` could find. It does not —
  the app and its SwiftPM frameworks resolve through `@rpath` at load — but a future `dlopen` of a
  DerivedData framework would now fail under Xcode and work in a release build, which is a confusing
  way round.
- `openInGhostty` copies `ProcessInfo.processInfo.environment` for the standalone-window path; it is
  fixed by this too, because the copy happens after the scrub.

## Verification
- **The cause**: `ps eww` on the running Xcode-launched Clinic showed the full injection set above, and
  the four `studio-*.ips` reports all abort on the same Metal validation assertion, on
  `AWT-EventQueue-0`, three to five seconds after launch, with `MetalTools` and `GPUToolsCapture` in the
  frame list and four `Xcode.app` dylibs in the loaded images.
- **The leak, from inside a session**: reading the environment of this session's own shell — Clinic →
  `login` → `fish` → `claude` — under the *old* build printed `METAL_DEVICE_WRAPPER_TYPE=1`,
  `METAL_LOAD_INTERPOSER=1`, `METAL_DEBUG_ERROR_MODE`, `MallocNanoZone`, both `OS_ACTIVITY_TOOLS_*` and
  `__XPC_DYLD_FRAMEWORK_PATH`.
- **The scrub**: a smoke instance of the fixed build, launched with `open -n --env` carrying
  `DYLD_INSERT_LIBRARIES`, `DYLD_FRAMEWORK_PATH`, both `METAL_*`, `MallocNanoZone` and
  `OS_ACTIVITY_TOOLS_PRIVACY`, and `-ClinicOpenShellOnLaunch YES`: its shell tab's `login` and `fish`
  both carry `CLINIC=1` and `GHOSTTY_BRIDGE_SURFACE_ID`, and **not one** `DYLD_`, `METAL_`, `MTL_`,
  `__XCODE` or `__XPC_DYLD` variable. Same check, same machine, same minute, opposite answers.
- Note `ps eww` reads a process's env as it was at `exec`, not as `unsetenv` left it, so the app's own
  `ps` output is unchanged by the fix and is not the check. What a child inherits is.
- `make build` clean, 460 ClinicCore tests pass.
- **Studio survives** (user, 2026-09-13, on a Clinic restarted onto this build): the Campfire worktree
  opens and stays open. This was the one claim the smoke instance could not make for itself — it showed
  the variables gone, not the program that died of them living.
