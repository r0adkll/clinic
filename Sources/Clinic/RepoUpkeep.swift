import AppKit
import ClinicCore
import os

/// Git pull / checkout default / archive project / worktree trash with undo (ADR-065).
@MainActor
enum RepoUpkeep {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "upkeep")

    static func pull(project: Project) async -> String? {
        guard let repo = await GitRepository.discover(from: project.path) else { showError("Not a git repository", project.path); return nil }
        do { let out = try await repo.pull(); return out.isEmpty ? "Already up to date." : out }
        catch { showError("Git pull failed", "\(error)"); return nil }
    }

    /// The default branch when the project is currently on a different one.
    static func checkoutTarget(project: Project) async -> String? {
        guard let repo = await GitRepository.discover(from: project.path), let def = await repo.defaultBranch() else { return nil }
        let current = await repo.currentBranch()
        return current == def ? nil : def
    }

    static func checkoutDefault(project: Project) async {
        guard let repo = await GitRepository.discover(from: project.path), let def = await repo.defaultBranch() else { return }
        do { try await repo.checkout(def) } catch { showError("Checkout failed", "\(error)") }
    }

    static func showError(_ title: String, _ message: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.alertStyle = .warning; a.runModal()
    }

    // MARK: Worktree trash on archive

    struct TrashedWorktree { let repoRoot: String; let path: String; let branch: String?; let trashURL: URL }

    /// If the session's directory is a `<repo>/.claude/worktrees/<name>` worktree not in use, offer to trash it. Returns the record needed for Undo.
    static func offerWorktreeTrash(for summary: SessionSummary, tabs: TabStore, agents: BackgroundAgentsService?) async -> TrashedWorktree? {
        guard let cwd = summary.lastCwd ?? summary.cwd, cwd.contains("/.claude/worktrees/"), FileManager.default.fileExists(atPath: cwd) else { return nil }
        let inUse = tabs.tabs.contains { ($0.pwd ?? $0.projectPath).hasPrefix(cwd) } || (agents?.background.contains { $0.isRunning && ($0.cwd ?? "").hasPrefix(cwd) } ?? false)
        guard !inUse else { return nil }
        let pref = UserDefaults.standard.string(forKey: "ClinicArchiveWorktree") ?? "ask"
        var trash = pref == "always"
        if pref == "ask" {
            let a = NSAlert()
            a.messageText = "Move the session's worktree to the Trash?"
            a.informativeText = "\(cwd)\n\nThe branch is kept; uncommitted changes go to the Trash with the folder. Undo Archive restores it."
            a.addButton(withTitle: "Trash Worktree"); a.addButton(withTitle: "Keep Worktree"); a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: trash = true
            case .alertSecondButtonReturn: trash = false
            default: return nil
            }
        }
        guard trash else { return nil }
        let repoRoot = ProjectGrouping.projectPath(forCwd: cwd)
        let repo = GitRepository(root: repoRoot)
        let branch = (try? await repo.worktrees())?.first { $0.path == cwd }?.branch
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: cwd), resultingItemURL: &trashed)
            try? await repo.pruneWorktrees()
            guard let t = trashed as URL? else { return nil }
            return TrashedWorktree(repoRoot: repoRoot, path: cwd, branch: branch, trashURL: t)
        } catch {
            showError("Could not trash the worktree", "\(error)")
            return nil
        }
    }

    /// Undo: move the folder back and re-register the worktree.
    static func restore(_ t: TrashedWorktree) async {
        do {
            try FileManager.default.createDirectory(atPath: (t.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: t.trashURL, to: URL(fileURLWithPath: t.path))
            let repo = GitRepository(root: t.repoRoot)
            try? await repo.pruneWorktrees()
            if let b = t.branch {
                // The directory already exists with its contents; re-link it as a worktree of the branch.
                let gitFile = URL(fileURLWithPath: t.path).appendingPathComponent(".git")
                if !FileManager.default.fileExists(atPath: gitFile.path) { try await repo.addWorktree(path: t.path, branch: b) }
                else { try? await repo.pruneWorktrees() }
            }
        } catch {
            showError("Could not restore the worktree", "\(error)")
        }
    }
}
