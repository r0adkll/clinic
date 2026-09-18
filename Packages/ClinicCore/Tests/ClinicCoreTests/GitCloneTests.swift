import Foundation
import Testing
@testable import ClinicCore

@Suite struct GitRemoteURLTests {
    private func parsed(_ s: String) throws -> GitRemoteURL { try GitRemoteURL.parse(s).get() }

    @Test func httpsAndSsh() throws {
        let https = try parsed("https://github.com/r0adkll/clinic.git")
        #expect(https.transport == .https)
        #expect(https.host == "github.com")
        #expect(https.repositoryPath == "r0adkll/clinic")
        #expect(https.directoryName == "clinic")
        #expect(https.cloneURL == "https://github.com/r0adkll/clinic.git")
        #expect(https.displayName == "github.com/r0adkll/clinic")

        let scp = try parsed("git@github.com:r0adkll/clinic.git")
        #expect(scp.transport == .ssh)
        #expect(scp.host == "github.com")
        #expect(scp.repositoryPath == "r0adkll/clinic")
        #expect(scp.cloneURL == "git@github.com:r0adkll/clinic.git")

        let ssh = try parsed("ssh://git@git.example.com:2222/team/app.git")
        #expect(ssh.transport == .ssh)
        #expect(ssh.cloneURL == "ssh://git@git.example.com:2222/team/app.git")
        #expect(ssh.directoryName == "app")

        #expect(try parsed("git://git.kernel.org/pub/scm/git/git.git").transport == .git)
        #expect(try parsed("myhost:repos/thing").directoryName == "thing")
    }

    @Test func whatPeopleActuallyPaste() throws {
        #expect(try parsed("  git clone git@github.com:o/r.git\n").cloneURL == "git@github.com:o/r.git")
        #expect(try parsed("$ git clone https://github.com/o/r").cloneURL == "https://github.com/o/r")
        #expect(try parsed("'https://github.com/o/r.git'").cloneURL == "https://github.com/o/r.git")
        #expect(try parsed("github.com/o/r").cloneURL == "https://github.com/o/r")
        #expect(try parsed("HTTPS://GitHub.com/o/r/").cloneURL == "https://github.com/o/r")
    }

    @Test func browserAddressesAreCutBackToTheRepository() throws {
        #expect(try parsed("https://github.com/o/r/pull/12/files?w=1#diff").cloneURL == "https://github.com/o/r")
        #expect(try parsed("https://github.com/o/r/tree/main/docs").directoryName == "r")
        #expect(try parsed("https://bitbucket.org/team/app/src/main/").cloneURL == "https://bitbucket.org/team/app")
        #expect(try parsed("https://gitlab.com/group/sub/app/-/merge_requests/4").cloneURL == "https://gitlab.com/group/sub/app")
        // A self-hosted path is left alone: only the host knows how deep its repositories sit.
        #expect(try parsed("https://git.example.com/a/b/c.git").repositoryPath == "a/b/c")
    }

    @Test func theSshProbeIsOnlyEverPlainWords() throws {
        #expect(try parsed("git@github.com:o/r.git").sshProbeCommand == "ssh -T git@github.com")
        #expect(try parsed("ssh://git@git.example.com:2222/team/app.git").sshProbeCommand == "ssh -T -p 2222 git@git.example.com")
        #expect(try parsed("myhost:repos/thing").sshProbeCommand == "ssh -T myhost")
        #expect(try parsed("https://github.com/o/r").sshProbeCommand == nil)
        // Typed into a shell for the reader, so nothing a shell would split or expand.
        #expect(try parsed("ssh://a;id@host/x").sshProbeCommand == nil)
        #expect(try parsed("a$(id)@host:x").sshProbeCommand == nil)
    }

    @Test func refused() {
        #expect(GitRemoteURL.parse("   ") == .failure(.empty))
        #expect(GitRemoteURL.parse("clinic") == .failure(.notARemote))
        #expect(GitRemoteURL.parse("two words") == .failure(.notARemote))
        #expect(GitRemoteURL.parse("--upload-pack=touch /tmp/x") == .failure(.notARemote))
        #expect(GitRemoteURL.parse("-oProxyCommand=x@host:path") == .failure(.notARemote))
        #expect(GitRemoteURL.parse("git@-oProxyCommand=x:path") == .failure(.notARemote))
        #expect(GitRemoteURL.parse("ext::sh -c id") == .failure(.notARemote))
        #expect(GitRemoteURL.parse("ext::sh") == .failure(.unsupportedScheme("ext")))
        #expect(GitRemoteURL.parse("file:///Users/me/repo") == .failure(.unsupportedScheme("file")))
        #expect(GitRemoteURL.parse("ftp://host/repo.git") == .failure(.unsupportedScheme("ftp")))
        #expect(GitRemoteURL.parse("https://github.com") == .failure(.missingRepository))
        #expect(GitRemoteURL.parse("git@github.com:") == .failure(.missingRepository))
    }
}

@Suite struct GitCloneProgressTests {
    @Test func stagesAndFractions() {
        #expect(GitCloneProgress.parse("Cloning into 'clinic'...")?.stage == .connecting)
        #expect(GitCloneProgress.parse("Cloning into 'clinic'...")?.fraction == nil)

        let counting = GitCloneProgress.parse("remote: Counting objects: 100% (12/12), done.")
        #expect(counting == GitCloneProgress(stage: .counting, stageFraction: 1))
        #expect(GitCloneProgress.parse("remote: Enumerating objects: 1028, done.") == GitCloneProgress(stage: .counting))

        let receiving = GitCloneProgress.parse("Receiving objects:  45% (463/1028), 1.20 MiB | 2.31 MiB/s")
        #expect(receiving?.stage == .receiving)
        #expect(receiving?.stageFraction == 0.45)
        #expect(receiving?.detail == "1.20 MiB | 2.31 MiB/s")
        #expect(abs((receiving?.fraction ?? 0) - 0.3875) < 0.0001)

        let done = GitCloneProgress.parse("Receiving objects: 100% (1028/1028), 3.40 MiB | 2.10 MiB/s, done.")
        #expect(done?.detail == "3.40 MiB | 2.10 MiB/s")
        #expect(GitCloneProgress.parse("Resolving deltas: 100% (8/8), done.")?.fraction == 0.95)
        #expect(GitCloneProgress.parse("Updating files: 100% (5012/5012), done.")?.fraction == 1)
    }

    @Test func otherLinesAreNotProgress() {
        #expect(GitCloneProgress.parse("fatal: repository 'https://x/y' not found") == nil)
        #expect(GitCloneProgress.parse("warning: You appear to have cloned an empty repository.") == nil)
        #expect(GitCloneProgress.parse("") == nil)
    }
}

@Suite struct GitCloneFailureTests {
    @Test func classify() {
        #expect(GitCloneFailure.classify("fatal: destination path 'x' already exists and is not an empty directory.") == .destinationExists)
        #expect(GitCloneFailure.classify("ERROR: Repository not found.\nfatal: Could not read from remote repository.") == .notFound)
        #expect(GitCloneFailure.classify("fatal: repository 'https://github.com/a/nope.git/' not found") == .notFound)
        #expect(GitCloneFailure.classify("fatal: repository '/srv/nope.git' does not exist") == .notFound)
        #expect(GitCloneFailure.classify("fatal: '/srv/x' does not appear to be a git repository") == .notFound)
        #expect(GitCloneFailure.classify("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.") == .authentication)
        #expect(GitCloneFailure.classify("fatal: could not read Username for 'https://github.com': terminal prompts disabled") == .authentication)
        #expect(GitCloneFailure.classify("Host key verification failed.\nfatal: Could not read from remote repository.") == .hostKey)
        #expect(GitCloneFailure.classify("fatal: unable to access 'https://nope.invalid/a/b/': Could not resolve host: nope.invalid") == .network)
        #expect(GitCloneFailure.classify("ssh: connect to host example.com port 22: Operation timed out\nfatal: Could not read from remote repository.") == .network)
        #expect(GitCloneFailure.classify("fatal: write error: No space left on device") == .noSpace)
        #expect(GitCloneFailure.classify("could not launch git: no such file") == .gitMissing)
        #expect(GitCloneFailure.classify("fatal: something new") == .other)
    }
}

@Suite struct GitCloneDestinationTests {
    @Test func whatIsAlreadyThere() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clinic-clone-dest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        #expect(GitClone.destination(at: root.appendingPathComponent("nothing")) == .free)
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(GitClone.destination(at: empty) == .emptyDirectory)
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        #expect(GitClone.destination(at: empty) == .emptyDirectory)
        try Data().write(to: empty.appendingPathComponent("notes.txt"))
        #expect(GitClone.destination(at: empty) == .occupied)
        #expect(GitClone.destination(at: empty.appendingPathComponent("notes.txt")) == .occupied)
        let repo = root.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(GitClone.destination(at: repo) == .repository)
    }

    @Test func directoryNames() {
        #expect(GitClone.isValidDirectoryName("clinic"))
        #expect(GitClone.isValidDirectoryName("my app.swift"))
        #expect(!GitClone.isValidDirectoryName(""))
        #expect(!GitClone.isValidDirectoryName(".."))
        #expect(!GitClone.isValidDirectoryName("a/b"))
    }

    @Test func commonParent() {
        #expect(GitClone.commonParent(of: []) == nil)
        #expect(GitClone.commonParent(of: ["/Users/me/Code/a", "/Users/me/Work/b", "/Users/me/Work/c"]) == "/Users/me/Work")
        #expect(GitClone.commonParent(of: ["/Users/me/Code/a", "/Users/me/Work/b"]) == "/Users/me/Code")
    }
}

/// Real git against a local bare remote. `GitRemoteURL` refuses `file://` on purpose, so the remote is
/// built by hand here: what is under test is the runner, not the parser.
@Suite(.serialized) struct GitCloneRunTests {
    static func git(_ dir: URL, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw GitError(command: args.joined(separator: " "), exitCode: p.terminationStatus, stderr: "") }
    }

    /// A bare remote with one commit on `main`, and a root to clone into.
    static func fixture(commit: Bool = true) throws -> (root: URL, remote: GitRemoteURL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clinic-clone-\(UUID().uuidString)")
        let bare = root.appendingPathComponent("remote.git"), seed = root.appendingPathComponent("seed")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        try fm.createDirectory(at: seed, withIntermediateDirectories: true)
        try git(bare, ["init", "--bare", "-b", "main", "-q"])
        if commit {
            try git(seed, ["init", "-b", "main", "-q"])
            try "hello\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try git(seed, ["add", "."])
            try git(seed, ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "First"])
            try git(seed, ["push", "-q", bare.path, "main"])
        }
        let remote = GitRemoteURL(transport: .https, host: "localhost", repositoryPath: "remote", cloneURL: bare.path)
        return (root, remote)
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [GitCloneProgress] = []
        func add(_ p: GitCloneProgress) { lock.withLock { items.append(p) } }
        var all: [GitCloneProgress] { lock.withLock { items } }
    }

    @Test func clonesAndReportsTheBranch() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let dest = f.root.appendingPathComponent("work/clinic")
        let seen = Collected()
        let report = try await GitClone.run(f.remote, to: dest) { seen.add($0) }
        #expect(report.path == dest.path)
        #expect(report.branch == "main")
        #expect(!report.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("README.md").path))
        #expect(seen.all.first?.stage == .connecting)
    }

    @Test func anEmptyRemoteIsStillARepository() async throws {
        let f = try Self.fixture(commit: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let report = try await GitClone.run(f.remote, to: f.root.appendingPathComponent("empty")) { _ in }
        #expect(report.isEmpty)
    }

    @Test func aMissingRemoteIsNotFound() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var remote = f.remote
        remote.cloneURL = f.root.appendingPathComponent("nope.git").path
        let dest = f.root.appendingPathComponent("dest")
        do {
            _ = try await GitClone.run(remote, to: dest) { _ in }
            Issue.record("expected the clone to fail")
        } catch {
            #expect(error.failure == .notFound)
            #expect(!error.output.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func anOccupiedDestinationIsRefused() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let dest = f.root.appendingPathComponent("seed")
        do {
            _ = try await GitClone.run(f.remote, to: dest) { _ in }
            Issue.record("expected the clone to fail")
        } catch {
            #expect(error.failure == .destinationExists)
        }
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("README.md").path))
    }

    @Test func aCancelledCloneSaysSo() async throws {
        let f = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let remote = f.remote
        let dest = f.root.appendingPathComponent("cancelled")
        let task = Task { () -> GitCloneFailure? in
            do throws(GitCloneError) { _ = try await GitClone.run(remote, to: dest) { _ in }; return nil } catch { return error.failure }
        }
        task.cancel()
        #expect(await task.value == .cancelled)
    }
}
