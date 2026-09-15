import Foundation
import Darwin

/// Watches a fixed set of paths — files or directories, present or not — without recursing (ADR-154).
///
/// Each path that exists gets a kqueue vnode source of its own. A path that does not exist yet is
/// represented by its nearest existing ancestor, so `<repo>/.clinic/icon.svg` in a repo with no
/// `.clinic/` costs one descriptor on `<repo>`, and the watcher learns the moment the directory or
/// the file appears. Every event re-resolves the whole set (descriptors follow inodes, so an atomic
/// save or a deletion leaves the old source watching a ghost) and emits one debounced change.
/// Foundation + Dispatch only; consumers decide whether anything they care about actually changed.
public final class PathWatcher: @unchecked Sendable {
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "com.r0adkll.clinic.path-watcher")
    private let debounce: TimeInterval
    private let lock = NSLock()
    private var paths: Set<String> = []
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceWork: DispatchWorkItem?
    private var stopped = false

    public init(debounce: TimeInterval = 0.3) {
        self.debounce = debounce
        var c: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        continuation = c
    }

    deinit { stop() }

    /// Replaces the watched set. Paths already covered keep their sources; the rest are opened or closed.
    public func watch(_ newPaths: Set<String>) {
        lock.lock()
        paths = newPaths
        lock.unlock()
        queue.async { self.rearm() }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        debounceWork?.cancel()
        for s in sources.values { s.cancel() }
        sources.removeAll()
        continuation.finish()
    }

    /// The path a source must sit on to hear about `path`: the path itself, or the nearest ancestor that exists.
    static func anchor(for path: String) -> String {
        var p = path
        while !FileManager.default.fileExists(atPath: p) {
            let parent = (p as NSString).deletingLastPathComponent
            guard parent != p, !parent.isEmpty else { return "/" }
            p = parent
        }
        return p
    }

    /// Runs on `queue`. Closes every source and opens one per distinct anchor, so descriptors always
    /// point at the inode that currently lives at each anchor.
    private func rearm() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        for s in sources.values { s.cancel() }
        sources.removeAll()
        let anchors = Set(paths.map(Self.anchor(for:)))
        for anchor in anchors {
            let fd = open(anchor, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib, .extend, .link], queue: queue)
            source.setEventHandler { [weak self] in self?.noteChange() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[anchor] = source
        }
    }

    private func noteChange() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rearm()
            self.continuation.yield(())
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
