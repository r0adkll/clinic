import Foundation
import Testing
@testable import ClinicCore

/// ADR-190: the CLI's worktree exit dialog, read off the terminal, and the facts Clinic states first.
struct WorktreeExitTests {
    /// The dialog as the probe of 2026-10-08 read it from a pty, gaps and all.
    static let dialog = """
    Press Ctrl-C again to exit

    ────────────────────────────────────────────────────────────────────────────────
    Exiting worktree session
    You have 1 uncommitted file. These will be lost if you remove the worktree.

    ❯ 1. Keep worktree    Stays at
    /private/tmp/claude-501/scr
    atchpad/wt-order/repo/.claude/worktrees/exitorder
      2. Remove worktree  All changes and commits will be lost.

    Enter to confirm · Esc to cancel
    """

    @Test func seesTheDialogWhileItWaits() {
        #expect(WorktreeExitDialog.isShowing(in: Self.dialog))
        #expect(WorktreeExitDialog.isShowing(in: Self.dialog.filter { !$0.isWhitespace }))
    }

    @Test func doesNotSeeAnAnsweredDialog() {
        #expect(!WorktreeExitDialog.isShowing(in: Self.dialog + "\n✢ Keeping worktree…"))
        #expect(!WorktreeExitDialog.isShowing(in: Self.dialog + "\nRemoving worktree…\nWorktree removed. Uncommitted changes were discarded."))
        #expect(!WorktreeExitDialog.isShowing(in: "❯ Try \"write a test for <filepath>\"\n⏵⏵ auto mode on"))
    }

    @Test func answersAreDigits() {
        #expect(WorktreeExitAnswer.keep.digit == "1")
        #expect(WorktreeExitAnswer.remove.digit == "2")
        #expect(WorktreeExitAnswer.ask.digit == nil)
        #expect(WorktreeExitAnswer(rawValue: "remove") == .remove)
    }

    @Test func worktreeRootFromAnyDirectoryInside() {
        #expect(WorktreeExitFacts.worktreeRoot(forCwd: "/r/.claude/worktrees/foo") == "/r/.claude/worktrees/foo")
        #expect(WorktreeExitFacts.worktreeRoot(forCwd: "/r/.claude/worktrees/foo/src/a") == "/r/.claude/worktrees/foo")
        #expect(WorktreeExitFacts.worktreeRoot(forCwd: "/r/src") == nil)
        #expect(WorktreeExitFacts.worktreeRoot(forCwd: "/r/.claude/worktrees/") == nil)
    }

    @Test func summarySaysWhatWouldBeLost() {
        #expect(WorktreeExitFacts(path: "/r/.claude/worktrees/x", branch: "worktree-x", uncommittedFiles: 2, commits: 1).summary
                == "It holds 2 uncommitted files and 1 commit of its own on worktree-x.")
        #expect(WorktreeExitFacts(path: "/r/.claude/worktrees/x", uncommittedFiles: 1).summary == "It holds 1 uncommitted file.")
        #expect(WorktreeExitFacts(path: "/r/.claude/worktrees/x", branch: "worktree-x").isClean)
        #expect(WorktreeExitFacts(path: "/r/.claude/worktrees/x", unverified: true).isClean == false)
        #expect(WorktreeExitFacts(path: "/r/.claude/worktrees/x").name == "x")
    }

    @Test func factsFromARealWorktree() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wt-exit-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        func git(_ args: [String], in dir: String = tmp) async throws {
            let r = await GitProcess.run(args, in: dir)
            #expect(r.status == 0, "git \(args): \(r.stderr)")
        }
        try await git(["init", "-q", "-b", "main"])
        try await git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"])
        let wt = tmp + "/.claude/worktrees/x"
        try await git(["worktree", "add", "-q", "-b", "worktree-x", wt])
        var facts = await GitRepository.worktreeExitFacts(at: wt)
        #expect(facts.isClean && facts.branch == "worktree-x")
        try "a".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        try await git(["add", "a.txt"], in: wt)
        try await git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"], in: wt)
        try "b".write(toFile: wt + "/b.txt", atomically: true, encoding: .utf8)
        facts = await GitRepository.worktreeExitFacts(at: wt)
        #expect(facts.commits == 1 && facts.uncommittedFiles == 1 && !facts.isClean)
    }
}
