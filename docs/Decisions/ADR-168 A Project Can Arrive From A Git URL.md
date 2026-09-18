---
status: accepted (built 2026-09-18)
date: 2026-09-18
amends: "[[ADR-077 Persistent Projects and Sidebar Polish]] (a project is also registered when Clinic clones it; the add-project control is a menu); [[ADR-120 The Empty Screen Is A Home]] and [[ADR-121 The New Session Sheet Picks A Project]] (their folder drops also take a repository's web address)"
tags: [adr, git, ui, projects]
---
# ADR-168: A project can arrive from a git URL

## Context
User (2026-09-18): *"It would be nice if we could import projects from git (ssh/https) urls"*

Every way of adding a project ended in one `NSOpenPanel` (`ProjectFolderPicker`): the sidebar's
`folder.badge.plus`, the home screen's *Add Project…* card, the first-launch *Choose Folder…*, and the New
Session sheet's footer. A repository that was not on this Mac yet meant leaving Clinic for a terminal, cloning,
and coming back to pick the folder.

## Options
- **Clone in a shell tab.** Open a shell and type `git clone` for the reader. No new UI, and prompts would work,
  but Clinic cannot tell when the clone finished or where it landed, so it cannot register the project.
  Rejected.
- **`gh repo clone`.** Picks the protocol for you, but it is GitHub only and the request named URLs. Rejected.
- **A sheet that runs `git clone` and follows it**, in the manner of [[ADR-165 Git Pull Says What Arrived]].
  **Chosen.**

## Decision
**Model (ClinicCore, tested).**
- `GitRemoteURL.parse` takes what people actually paste: `https://`, `http://`, `ssh://` and `git://` URLs,
  scp-like `git@host:owner/repo.git`, a bare `host/owner/repo`, a `git clone <url>` line with or without a
  `$ ` prompt, and quoted text. A browser address is cut back to its repository: two path components on
  github.com and bitbucket.org, everything before `/-/` on any host (GitLab). A self-hosted path is left alone.
- It refuses what should never reach git: anything starting with `-` (an option), whitespace, a user or host
  starting with `-`, `ext::` and every other `transport::address`, and `file://`. A local folder is *Add
  Folder*, not a clone. git is still given `--` before the URL.
- `GitClone.run` runs `git clone --progress -- <url> <destination>` under the same environment as every other
  git call (C locale, no terminal prompt; now `GitProcess.environment`). stderr is split on `\r` and `\n`.
  Progress lines become `GitCloneProgress` (stage, percent, git's rate text) and are dropped. The rest is kept
  for the classifier and the *Git output* disclosure.
- One fraction for the whole clone, by stage: counting 0–2 %, compressing 2–5 %, receiving 5–80 %, resolving
  deltas 80–95 %, checkout 95–100 %. The sheet only lets it rise.
- Cancelling the task sends git `SIGTERM`. git removes its own partial clone on a signal and on failure, so
  **Clinic never deletes a directory**. The reader waits two seconds for stderr to close after git exits, so a
  helper that outlives git cannot hang the sheet.
- `GitCloneFailure`, read from stderr: git missing, host key, authentication, not found, network, destination
  exists, disk full, cancelled, `other`. *Not found* is tested before authentication and network, because
  GitHub follows "Repository not found" with the same "Could not read from remote repository" a dead link gets.
- `GitClone.destination(at:)` says what already sits at the target (free, empty directory, repository,
  occupied) from the filesystem alone, so the form can ask on every keystroke.

**The sheet** (`CloneSheet`), in the New Session sheet's look ([[ADR-121 The New Session Sheet Picks A Project]]):
- **Form**: a URL field, a *Clone into* folder with *Choose…*, and a folder name that follows the URL until it
  is edited. A caption under the URL says what was understood (*github.com/owner/repo over SSH*) or why not.
  A caption under the folder says where the clone lands, or that the name is taken. When the folder is already
  a checkout, *Add It Instead* registers it. *Clone* stays disabled until both captions are good.
- **Where clones go**: the folder last cloned into (`ClinicCloneDirectory`), else the parent most registered
  projects share (`GitClone.commonParent`), else `~/Developer`, else home.
- **Cloning**: a linear bar, the stage in words with its percent, git's rate on the right, and *Stop*. Stop
  returns to the form with *Stopped. Nothing was left behind.*
- **Done**: the project is registered ([[ADR-077 Persistent Projects and Sidebar Polish]]), and the sheet offers
  *New Session* (default) and *Done*. Opened from the New Session sheet, it skips this and goes to the composer,
  because a session was the point.
- **Refused**: a headline and a sentence per failure, git's output behind a disclosure that opens itself only
  for `other`, and *Cancel*, *Edit…*, *Try Again*. A host key refusal offers *Connect in a Shell*, which runs
  `ssh -T git@host` in a new shell so the key can be accepted. That line is typed for the reader, so
  `sshProbeCommand` is nil unless user and host are plain words (`[A-Za-z0-9._-]`); otherwise the button is
  *Open Shell Here*, which authentication failures get too.

**Ways in.**
- The sidebar's add-project control and the home screen's *Add Project…* card become menus of two items:
  *Add Folder…* and *Clone from URL…*.
- First launch gets *Or clone one from a URL…* under *Choose Folder…*.
- The New Session sheet's footer gets *Clone…*. It closes, and the Clone sheet opens 0.4 s later, because
  SwiftUI presents one sheet at a time.
- *File ▸ Add Project Folder…* and *File ▸ Clone Repository…*. Adding a folder had no menu item before.
- A repository's web address dropped on the first-launch home or the New Session sheet opens the Clone sheet
  on it.
- Smoke keys (ADR-038): `-ClinicCloneOnLaunch <url|YES>`, `-ClinicCloneStartOnLaunch YES`,
  `-ClinicCloneDirectory <dir>`.

**Not done, on purpose.**
- No clipboard prefill. Reading the pasteboard without a paste is what macOS now warns people about, and ⌘V in
  a focused field is one keystroke.
- No submodules, branch, depth or `owner/repo` shorthand. A session can run `git submodule update --init`, and
  shorthand has to guess a host and a protocol.
- No answer to credential or passphrase prompts. Clinic has no terminal to show one in; the refusal says what
  to set up instead.

## Consequences
- Adding a folder from the sidebar is now two clicks instead of one. The drop targets and the File menu item
  are the one-step routes.
- The failure classifier depends on git's and GitHub's English wording, as ADR-165's does. Unrecognised text is
  `other`, which shows git's output.
- `RootView.body` would not type-check with one more sheet, so the Clone sheet is presented from its own
  modifier (`CloneRouting`), as the Tasks routing already is.
- Checked in a smoke instance (`~/Library/Caches/clinic-cl`, deleted) over the accessibility API and
  screenshots: an HTTPS clone from a pull request's browser address, an SSH clone showing *Resolving deltas ·
  35 %* at 0.8525, a repository that does not exist, *Edit…* keeping the form, *already a project* disabling
  *Clone*, and both menus present. The run wrote `ClinicCloneDirectory` into the real defaults domain; it was
  deleted and the domain diffed identical to the export taken before. Not driven: *Stop* in the app (a unit
  test covers cancellation), the hand-off from the New Session sheet, the drops, and a host key refusal.
