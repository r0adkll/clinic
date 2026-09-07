import Foundation
import Observation
import os
import ClinicCore

/// Per-tab git page state (ADR-052).
@MainActor
@Observable
final class GitPageModel {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "git")

    private(set) var repo: GitRepository?
    private(set) var status: GitStatusSnapshot?
    private(set) var commits: [GitCommit] = []
    private(set) var diff: UnifiedDiffFile?
    private(set) var isLoading = false
    private(set) var isBound = false
    private(set) var error: String?
    var selectedPath: String?
    var selectedStaged = false
    var commitMessage = ""
    var confirmDiscard: (() -> Void)?
    var confirmDiscardTitle = ""

    private var watcher: FSEventsWatcher?
    private var watchTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    var unstagedFiles: [GitFileStatus] { status?.files.filter { $0.hasUnstagedChanges || $0.isConflicted } ?? [] }
    var stagedFiles: [GitFileStatus] { status?.files.filter { $0.hasStagedChanges } ?? [] }
    var hasRepo: Bool { repo != nil }

    /// (Re)binds to the repository containing `directory`. Cheap when the root is unchanged.
    func bind(directory: String) async {
        let found = await GitRepository.discover(from: directory)
        defer { isBound = true }
        if let found, let current = repo, await current.root == found.root { return }
        stopWatching()
        repo = found
        status = nil; commits = []; diff = nil; selectedPath = nil; error = nil
        guard let found else { return }
        let root = await found.root
        watcher = FSEventsWatcher(paths: [root])
        watcher?.start()
        if let stream = watcher?.changes {
            watchTask = Task { [weak self] in
                for await _ in stream { self?.scheduleReload() }
            }
        }
        await reload()
    }

    func stopWatching() {
        watchTask?.cancel(); watchTask = nil
        watcher?.stop(); watcher = nil
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        guard let repo else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await repo.status()
            commits = try await repo.commits(limit: 100)
            error = nil
            if let path = selectedPath, status?.files.contains(where: { $0.path == path }) == true {
                await loadDiff()
            } else if let first = unstagedFiles.first ?? stagedFiles.first {
                select(first, staged: unstagedFiles.isEmpty)
            } else {
                selectedPath = nil; diff = nil
            }
        } catch {
            self.error = "\(error)"
            Self.log.error("git reload: \(error, privacy: .public)")
        }
    }

    func select(_ file: GitFileStatus, staged: Bool) {
        selectedPath = file.path
        selectedStaged = staged
        Task { await loadDiff() }
    }

    private func loadDiff() async {
        guard let repo, let path = selectedPath else { diff = nil; return }
        do {
            let d = try await repo.diff(path: path, staged: selectedStaged)
            diff = d.files.first
        } catch {
            diff = nil
            self.error = "\(error)"
        }
    }

    // MARK: Actions

    private func run(_ op: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard let repo else { return }
        Task {
            do { try await op(repo); error = nil } catch { self.error = "\(error)" }
            await reload()
        }
    }

    func stage(_ file: GitFileStatus) { run { try await $0.stage(paths: [file.path]) } }
    func unstage(_ file: GitFileStatus) { run { try await $0.unstage(paths: [file.path]) } }
    func stageAll() { let paths = unstagedFiles.map(\.path); run { try await $0.stage(paths: paths) } }
    func unstageAll() { let paths = stagedFiles.map(\.path); run { try await $0.unstage(paths: paths) } }

    func discard(_ file: GitFileStatus) {
        confirmDiscardTitle = file.isUntracked ? "Delete untracked file \(file.path)?" : "Discard changes to \(file.path)?"
        confirmDiscard = { [weak self] in self?.run { try await $0.discard(path: file.path) } }
    }

    func stage(hunk: DiffHunk) {
        guard let file = diff else { return }
        let patch = file.patchText(for: hunk)
        run { try await $0.apply(patch: patch, staged: true, reverse: false) }
    }

    func unstage(hunk: DiffHunk) {
        guard let file = diff else { return }
        let patch = file.patchText(for: hunk)
        run { try await $0.apply(patch: patch, staged: true, reverse: true) }
    }

    func discard(hunk: DiffHunk) {
        guard let file = diff else { return }
        let patch = file.patchText(for: hunk)
        confirmDiscardTitle = "Discard this hunk in \(file.path)?"
        confirmDiscard = { [weak self] in self?.run { try await $0.apply(patch: patch, staged: false, reverse: true) } }
    }

    func commit(amend: Bool = false) {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || amend else { return }
        run { try await $0.commit(message: message, amend: amend) }
        commitMessage = ""
    }
}
