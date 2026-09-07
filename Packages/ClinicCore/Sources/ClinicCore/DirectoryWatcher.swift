import Foundation
import Darwin

/// Watches the Claude projects directory and each project subdirectory for changes (ADR-029).
/// Emits debounced change notifications; the consumer rescans. Foundation + Dispatch only.
public final class DirectoryWatcher: @unchecked Sendable {
    public let root: URL
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "com.r0adkll.clinic.dir-watcher")
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceWork: DispatchWorkItem?
    private let debounce: TimeInterval
    private let lock = NSLock()

    public init(root: URL, debounce: TimeInterval = 0.5) {
        self.root = root
        self.debounce = debounce
        var c: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        continuation = c
    }

    public func start() {
        queue.async { self.refreshWatchedDirectories(); }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        for s in sources.values { s.cancel() }
        sources.removeAll()
        continuation.finish()
    }

    /// Watches root plus every immediate subdirectory (project dirs). Called on every change so new project dirs get picked up.
    private func refreshWatchedDirectories() {
        var wanted: [String] = [root.path]
        if let subs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for sub in subs where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { wanted.append(sub.path) }
        }
        lock.lock(); defer { lock.unlock() }
        let wantedSet = Set(wanted)
        for (path, source) in sources where !wantedSet.contains(path) { source.cancel(); sources[path] = nil }
        for path in wanted where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib, .extend], queue: queue)
            source.setEventHandler { [weak self] in self?.noteChange() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
    }

    private func noteChange() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWatchedDirectories()
            self.continuation.yield(())
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
