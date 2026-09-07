import Foundation
import CoreServices

/// Recursive file-system watcher built on FSEvents. Emits one batch of changed paths per FSEvents
/// callback (coalesced by `latency`). Events under `.git/objects/` are ignored.
public final class FSEventsWatcher: @unchecked Sendable {
    /// Changed paths per batch (debounced by FSEvents latency). Finishes when `stop()` is called.
    public let changes: AsyncStream<[String]>

    private let paths: [String]
    private let latency: TimeInterval
    private let sink: Sink
    private let queue = DispatchQueue(label: "com.r0adkll.clinic.fsevents")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var stopped = false

    /// Receives callbacks; retained by the FSEvents stream context so a callback can never reach a freed object.
    private final class Sink: @unchecked Sendable {
        let continuation: AsyncStream<[String]>.Continuation
        init(_ c: AsyncStream<[String]>.Continuation) { continuation = c }

        func deliver(_ paths: [String]) {
            let kept = paths.filter { !FSEventsWatcher.isIgnored($0) }
            if !kept.isEmpty { continuation.yield(kept) }
        }
    }

    public init(paths: [String], latency: TimeInterval = 0.4) {
        self.paths = paths
        self.latency = latency
        var c: AsyncStream<[String]>.Continuation!
        changes = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        sink = Sink(c)
    }

    deinit { stop() }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil, !stopped, !paths.isEmpty else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(sink).toOpaque()
        context.retain = { info in
            guard let info else { return nil }
            _ = Unmanaged<Sink>.fromOpaque(info).retain()
            return UnsafeRawPointer(info)
        }
        context.release = { info in
            guard let info else { return }
            Unmanaged<Sink>.fromOpaque(info).release()
        }

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            sink.deliver(array.compactMap { $0 as? String })
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            // The context's retain callback was never invoked, so balance our passRetained.
            Unmanaged<Sink>.fromOpaque(context.info!).release()
            return
        }
        // FSEventStreamCreate retains the info through `context.retain`; drop our own reference.
        Unmanaged<Sink>.fromOpaque(context.info!).release()
        FSEventStreamSetDispatchQueue(s, queue)
        if !FSEventStreamStart(s) {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }
        stream = s
    }

    /// Stops the stream and finishes `changes`. Safe to call repeatedly and from `deinit`.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        if !stopped {
            stopped = true
            sink.continuation.finish()
        }
    }

    static func isIgnored(_ path: String) -> Bool {
        path.contains("/.git/objects/") || path.hasSuffix("/.git/objects")
    }
}
