import Foundation

/// Where `git clone --progress` has got to (ADR-168), read from the lines it rewrites on stderr:
/// `Receiving objects:  45% (463/1028), 1.20 MiB | 2.31 MiB/s`.
public struct GitCloneProgress: Sendable, Hashable {
    public enum Stage: Int, Sendable, Hashable, Comparable {
        case connecting, counting, compressing, receiving, resolving, checkingOut
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }

        /// The slice of the whole each stage is given. Receiving is nearly all of a real clone; the
        /// remote's own counting and the final checkout are moments either side of it.
        var span: ClosedRange<Double> {
            switch self {
            case .connecting: 0...0
            case .counting: 0...0.02
            case .compressing: 0.02...0.05
            case .receiving: 0.05...0.80
            case .resolving: 0.80...0.95
            case .checkingOut: 0.95...1
            }
        }
    }

    public var stage: Stage
    /// 0…1 within the stage; nil while git has not printed a percentage.
    public var stageFraction: Double?
    /// What git adds after the counts: `1.20 MiB | 2.31 MiB/s`.
    public var detail: String?

    public init(stage: Stage, stageFraction: Double? = nil, detail: String? = nil) {
        self.stage = stage
        self.stageFraction = stageFraction
        self.detail = detail
    }

    /// 0…1 across the whole clone; nil before the first percentage.
    public var fraction: Double? {
        guard stage != .connecting else { return nil }
        let span = stage.span
        return span.lowerBound + (span.upperBound - span.lowerBound) * (stageFraction ?? 0)
    }

    private static let stages: [(String, Stage)] = [
        ("Enumerating objects:", .counting), ("Counting objects:", .counting), ("Compressing objects:", .compressing),
        ("Receiving objects:", .receiving), ("Resolving deltas:", .resolving), ("Updating files:", .checkingOut),
    ]

    /// One stderr segment, or nil when it is not a progress line (a warning, a fatal, a hint).
    public static func parse(_ line: String) -> GitCloneProgress? {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("Cloning into ") { return GitCloneProgress(stage: .connecting) }
        if s.hasPrefix("remote: ") { s = String(s.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        guard let (prefix, stage) = stages.first(where: { s.hasPrefix($0.0) }) else { return nil }
        let rest = s.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        var progress = GitCloneProgress(stage: stage)
        if let percent = rest.firstIndex(of: "%"), let n = Int(rest[..<percent]) {
            progress.stageFraction = min(max(Double(n) / 100, 0), 1)
        }
        if let close = rest.firstIndex(of: ")") {
            var detail = rest[rest.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            if detail.hasSuffix("done.") { detail = String(detail.dropLast(5)).trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
            if !detail.isEmpty { progress.detail = detail }
        }
        return progress
    }
}

/// A finished clone: where it landed and what it checked out.
public struct GitCloneReport: Sendable, Hashable {
    public var path: String
    /// The branch git checked out; nil for an empty repository or a detached default.
    public var branch: String?
    /// The remote had no commits. The folder is a valid repository all the same.
    public var isEmpty: Bool

    public init(path: String, branch: String? = nil, isEmpty: Bool = false) {
        self.path = path
        self.branch = branch
        self.isEmpty = isEmpty
    }
}

/// Why a clone did not happen, read from git's C-locale stderr. `.other` leaves git's words as the
/// only explanation, as `GitPullFailure` does (ADR-165).
public enum GitCloneFailure: Sendable, Hashable {
    case gitMissing
    /// ssh has never seen this host and has nobody to ask.
    case hostKey
    case authentication
    case notFound
    case network
    case destinationExists
    case noSpace
    case cancelled
    case other

    public static func classify(_ stderr: String) -> GitCloneFailure {
        func has(_ needle: String) -> Bool { stderr.range(of: needle, options: .caseInsensitive) != nil }
        if has("could not launch git") || has("env: git: No such file") { return .gitMissing }
        if has("already exists and is not an empty directory") { return .destinationExists }
        if has("No space left on device") { return .noSpace }
        if has("Host key verification failed") { return .hostKey }
        // Before authentication and network: GitHub answers a missing repository over ssh with
        // "Repository not found" and then the same "Could not read from remote repository" a dead link gets.
        if has("Repository not found") || has("' not found") || has("' does not exist") || has("does not appear to be a git repository")
            || has("returned error: 404") || has("project you were looking for could not be found") { return .notFound }
        if has("Authentication failed") || has("Permission denied") || has("could not read Username") || has("could not read Password")
            || has("terminal prompts disabled") || has("returned error: 403") || has("returned error: 401") { return .authentication }
        if has("Could not resolve host") || has("unable to access") || has("Connection timed out") || has("Connection refused")
            || has("Operation timed out") || has("Network is unreachable") || has("Could not read from remote repository")
            || has("early EOF") || has("unexpected disconnect") || has("RPC failed") { return .network }
        return .other
    }
}

public struct GitCloneError: Error, Sendable, Hashable {
    public var failure: GitCloneFailure
    public var output: String

    public init(failure: GitCloneFailure, output: String = "") {
        self.failure = failure
        self.output = output
    }
}

public enum GitClone {
    /// What already sits where a clone would go. Filesystem only, so a form can ask on every keystroke.
    public enum Destination: Sendable, Hashable {
        case free
        /// git clones into an existing directory when it is empty.
        case emptyDirectory
        /// A checkout is already there: adding it is probably what was wanted.
        case repository
        case occupied
    }

    public static func destination(at url: URL, fileManager: FileManager = .default) -> Destination {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .free }
        guard isDirectory.boolValue else { return .occupied }
        if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) { return .repository }
        let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? ["?"]
        return contents.allSatisfy({ $0 == ".DS_Store" }) ? .emptyDirectory : .occupied
    }

    /// Whether a typed folder name can be one path component.
    public static func isValidDirectoryName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n != "." && n != ".." && !n.contains("/") && !n.contains(":") && !n.contains("\0")
    }

    /// The folder most of the reader's projects already live in: where a new clone most likely belongs.
    /// Ties go to the parent seen first, so the answer does not change between two launches.
    public static func commonParent(of projectPaths: [String]) -> String? {
        var counts: [String: Int] = [:], order: [String] = []
        for path in projectPaths {
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != "/" else { continue }
            if counts[parent] == nil { order.append(parent) }
            counts[parent, default: 0] += 1
        }
        return order.max { (counts[$0] ?? 0, -order.firstIndex(of: $0)!) < (counts[$1] ?? 0, -order.firstIndex(of: $1)!) }
    }

    /// `git clone --progress -- <url> <destination>`. `progress` is called off the main actor as git
    /// reports. Cancelling the task terminates git, which removes the partial clone itself; nothing
    /// here deletes a directory.
    public static func run(_ remote: GitRemoteURL, to destination: URL,
                           progress: @escaping @Sendable (GitCloneProgress) -> Void) async throws(GitCloneError) -> GitCloneReport {
        let box = ProcessBox()
        let args = ["git", "clone", "--progress", "--", remote.cloneURL, destination.path]
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: runSync(args, box: box, progress: progress))
                }
            }
        } onCancel: { box.cancel() }

        if box.isCancelled { throw GitCloneError(failure: .cancelled, output: result.output) }
        guard result.status == 0 else {
            throw GitCloneError(failure: GitCloneFailure.classify(result.output), output: result.output)
        }
        let empty = result.output.range(of: "cloned an empty repository", options: .caseInsensitive) != nil
        let branch = await GitInfo.branch(at: destination.path)
        return GitCloneReport(path: destination.path, branch: branch == "HEAD" ? nil : branch, isEmpty: empty)
    }

    struct Outcome: Sendable {
        var status: Int32
        /// stderr without the progress lines: warnings, hints and the fatal.
        var output: String
    }

    /// The running process, so a cancellation on another thread can reach it. A cancel that lands
    /// before `run` is remembered and the process is terminated the moment it starts.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func started(_ p: Process) {
            lock.withLock {
                process = p
                if cancelled { p.terminate() }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let process, process.isRunning { process.terminate() }
            }
        }
    }

    private static func runSync(_ args: [String], box: ProcessBox, progress: @escaping @Sendable (GitCloneProgress) -> Void) -> Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.environment = GitProcess.environment()
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return Outcome(status: -1, output: "could not launch git: \(error.localizedDescription)")
        }
        box.started(p)

        // git rewrites its progress line with `\r`, so segments end at either terminator. Progress is
        // reported and dropped; everything else is kept for the classifier and the details disclosure.
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var kept: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            func flush(_ segment: Data) {
                let line = String(decoding: segment, as: UTF8.self)
                if let p = GitCloneProgress.parse(line) { progress(p) }
                else if !line.trimmingCharacters(in: .whitespaces).isEmpty { kept.append(line) }
            }
            while true {
                let chunk = err.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    flush(pending[pending.startIndex..<i])
                    pending = Data(pending[pending.index(after: i)...])
                }
            }
            if !pending.isEmpty { flush(pending) }
            finished.signal()
        }
        p.waitUntilExit()
        // A helper that outlives git (an ssh control master) can hold stderr open; git's own words are
        // all written by now, so the reader is given a moment rather than for ever.
        let drained = finished.wait(timeout: .now() + 2) == .success
        return Outcome(status: p.terminationStatus, output: drained ? kept.joined(separator: "\n") : "")
    }
}
