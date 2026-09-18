import Foundation
import Testing
@testable import ClinicCore

@Suite struct GitPullFailureTests {
    @Test func diverged() {
        let stderr = """
        hint: Diverging branches can't be fast-forwarded, you need to either:
        hint:
        hint: \tgit merge --no-ff
        fatal: Not possible to fast-forward, aborting.
        """
        #expect(GitPullFailure.classify(stderr) == .diverged(ahead: nil, behind: nil))
        #expect(GitPullFailure.classify("fatal: Not possible to fast-forward, aborting.") == .diverged(ahead: nil, behind: nil))
    }

    @Test func localChangesListTheFiles() {
        let stderr = """
        Updating 1111111..2222222
        error: Your local changes to the following files would be overwritten by merge:
        \tREADME.md
        \tSources/App.swift
        Please commit your changes or stash them before you merge.
        Aborting
        """
        #expect(GitPullFailure.classify(stderr) == .localChanges(files: ["README.md", "Sources/App.swift"]))
        #expect(GitPullFailure.classify("error: cannot pull with rebase: You have unstaged changes.") == .localChanges(files: []))
    }

    @Test func untrackedFilesListTheFiles() {
        let stderr = """
        error: The following untracked working tree files would be overwritten by merge:
        \tnew.txt
        Please move or remove them before you merge.
        """
        #expect(GitPullFailure.classify(stderr) == .untrackedFiles(files: ["new.txt"]))
    }

    @Test func upstreamGoneNamesTheRef() {
        let stderr = """
        Your configuration specifies to merge with the ref 'refs/heads/feature/x'
        from the remote, but no such ref was fetched.
        """
        #expect(GitPullFailure.classify(stderr, branch: "feature/x") == .upstreamGone(branch: "feature/x", upstream: "feature/x"))
    }

    @Test func branchStates() {
        #expect(GitPullFailure.classify("You are not currently on a branch.\nPlease specify which branch you want to merge with.") == .detachedHead)
        #expect(GitPullFailure.classify("There is no tracking information for the current branch.", branch: "wip") == .noUpstream(branch: "wip"))
    }

    @Test func remoteTrouble() {
        #expect(GitPullFailure.classify("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.") == .authentication)
        #expect(GitPullFailure.classify("fatal: could not read Username for 'https://github.com': terminal prompts disabled") == .authentication)
        #expect(GitPullFailure.classify("fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com") == .network)
        #expect(GitPullFailure.classify("ssh: connect to host github.com port 22: Operation timed out\nfatal: Could not read from remote repository.") == .network)
        #expect(GitPullFailure.classify("fatal: something new") == .other)
    }
}

/// Real git: a bare remote with two clones, one to push from and one to pull into.
@Suite(.serialized) struct GitPullReportTests {
    struct Fixture {
        let remote: URL, upstream: URL, local: URL
        var repo: GitRepository { GitRepository(root: local.path) }
    }

    static func git(_ dir: URL, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
    }

    static func identify(_ dir: URL) throws {
        try git(dir, ["config", "user.name", "Clinic Tests"])
        try git(dir, ["config", "user.email", "tests@clinic.local"])
        try git(dir, ["config", "commit.gpgsign", "false"])
        try git(dir, ["config", "core.hooksPath", "/dev/null"])
    }

    static func commit(_ dir: URL, _ file: String, _ content: String, _ message: String) throws {
        try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git(dir, ["add", "."]); try git(dir, ["commit", "-q", "-m", message])
    }

    static func make() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-pull-\(UUID().uuidString)")
        let remote = base.appendingPathComponent("remote.git"), upstream = base.appendingPathComponent("upstream"), local = base.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(remote, ["init", "-q", "--bare", "-b", "main"])
        try git(base, ["clone", "-q", remote.path, upstream.path]); try identify(upstream)
        try commit(upstream, "a.txt", "one\n", "First")
        try git(upstream, ["push", "-q", "origin", "main"])
        try git(base, ["clone", "-q", remote.path, local.path]); try identify(local)
        return Fixture(remote: remote, upstream: upstream, local: local)
    }

    @Test func upToDate() async throws {
        let f = try Self.make()
        let report = try await f.repo.pullReport()
        #expect(report.isUpToDate && report.branch == "main" && report.upstream == "origin/main" && report.commitCount == 0)
    }

    @Test func fastForwardReportsCommitsAndLines() async throws {
        let f = try Self.make()
        try Self.commit(f.upstream, "a.txt", "one\ntwo\n", "Second")
        try Self.commit(f.upstream, "b.txt", "b\n", "Third")
        try Self.git(f.upstream, ["push", "-q", "origin", "main"])
        let report = try await f.repo.pullReport(commitLimit: 1)
        #expect(!report.isUpToDate)
        #expect(report.commitCount == 2)
        #expect(report.commits.map(\.subject) == ["Third"])
        #expect(report.stat == DiffStat(files: 2, additions: 2, deletions: 0))
    }

    @Test func divergedCountsBothSides() async throws {
        let f = try Self.make()
        try Self.commit(f.upstream, "a.txt", "upstream\n", "Theirs")
        try Self.git(f.upstream, ["push", "-q", "origin", "main"])
        try Self.commit(f.local, "c.txt", "mine\n", "Mine")
        try Self.commit(f.local, "d.txt", "mine\n", "Mine again")
        do { _ = try await f.repo.pullReport(); Issue.record("expected a refusal") }
        catch { #expect(error.failure == .diverged(ahead: 2, behind: 1)); #expect(error.upstream == "origin/main") }
    }

    @Test func localChangesNameTheFile() async throws {
        let f = try Self.make()
        try Self.commit(f.upstream, "a.txt", "theirs\n", "Theirs")
        try Self.git(f.upstream, ["push", "-q", "origin", "main"])
        try "mine\n".write(to: f.local.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        do { _ = try await f.repo.pullReport(); Issue.record("expected a refusal") }
        catch { #expect(error.failure == .localChanges(files: ["a.txt"])); #expect(!error.output.isEmpty) }
    }

    @Test func upstreamDeletedOnTheRemote() async throws {
        let f = try Self.make()
        try Self.git(f.local, ["checkout", "-q", "-b", "feature"])
        try Self.git(f.local, ["push", "-q", "-u", "origin", "feature"])
        try Self.git(f.upstream, ["push", "-q", "origin", "--delete", "feature"])
        do { _ = try await f.repo.pullReport(); Issue.record("expected a refusal") }
        catch { #expect(error.failure == .upstreamGone(branch: "feature", upstream: "feature")) }
    }

    @Test func noUpstreamAndDetachedNeverFetch() async throws {
        let f = try Self.make()
        try Self.git(f.local, ["checkout", "-q", "-b", "wip"])
        do { _ = try await f.repo.pullReport(); Issue.record("expected a refusal") }
        catch { #expect(error.failure == .noUpstream(branch: "wip")) }
        try Self.git(f.local, ["checkout", "-q", "--detach"])
        do { _ = try await f.repo.pullReport(); Issue.record("expected a refusal") }
        catch { #expect(error.failure == .detachedHead) }
    }
}
