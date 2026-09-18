import Foundation
import Darwin

/// Unix-domain socket server receiving hook payloads from `clinic-hook` (ADR-015).
/// Protocol: one connection per payload; the client writes the JSON document and closes its write side.
/// Runs its accept loop on a dedicated dispatch queue; delivers decoded events through an AsyncStream.
public final class HookServer: @unchecked Sendable {
    public let socketPath: String
    public let events: AsyncStream<HookEvent>
    private let continuation: AsyncStream<HookEvent>.Continuation
    private let queue = DispatchQueue(label: "com.r0adkll.clinic.hook-server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var watchdog: DispatchSourceTimer?
    /// The inode bound at `socketPath`. A different one there means another process rebound the path.
    private var boundInode: ino_t = 0
    private let lock = NSLock()
    /// The socket path was taken or removed by another process and has been bound again (ADR-167).
    public var onRebind: (@Sendable (String) -> Void)?
    /// Raw payloads that failed to decode, for diagnostics.
    public var onUndecodable: (@Sendable (Data, Error) -> Void)?

    private let watchdogInterval: TimeInterval

    public init(socketPath: String, watchdogInterval: TimeInterval = 5) {
        self.socketPath = socketPath
        self.watchdogInterval = watchdogInterval
        var c: AsyncStream<HookEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    /// - Parameter suffix: `SocketClaim.instanceSuffix`, empty for the first instance on the directory.
    public static func defaultSocketPath(appSupport: URL = ClinicPaths.appSupport, suffix: String = "") -> String {
        appSupport.appendingPathComponent("Clinic", isDirectory: true).appendingPathComponent("hook\(suffix).sock").path
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listenFD < 0 else { return }
        try bind()
        // An older build, or anything else that unlinks the path, still cuts a live server off. Look
        // every few seconds and take the path back once nobody is listening on it (ADR-167).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkBinding() }
        timer.resume()
        watchdog = timer
    }

    private func checkBinding() {
        lock.lock(); defer { lock.unlock() }
        guard listenFD >= 0 else { return }
        var st = stat()
        let present = stat(socketPath, &st) == 0
        if present, st.st_ino == boundInode { return }
        // Someone else's live socket is theirs; fighting over the path helps neither instance.
        if present, SocketClaim.isLive(socketPath) { return }
        acceptSource?.cancel(); acceptSource = nil; listenFD = -1
        do { try bind(); onRebind?(present ? "replaced by a socket nobody listens on" : "removed") }
        catch { onRebind?("rebind failed: \(error)") }
    }

    /// Caller holds `lock`.
    private func bind() throws {
        guard socketPath.utf8.count < 104 else { throw HookServerError.pathTooLong(socketPath) }
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.posix("socket", errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        guard bindResult == 0 else { let e = errno; close(fd); throw HookServerError.posix("bind", e) }
        chmod(socketPath, 0o600)
        var st = stat()
        boundInode = stat(socketPath, &st) == 0 ? st.st_ino : 0
        // A full backlog refuses the connection outright on macOS, and the status line shares this socket.
        guard listen(fd, 256) == 0 else { let e = errno; close(fd); throw HookServerError.posix("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        watchdog?.cancel(); watchdog = nil
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            listenFD = -1
            // Only our own socket: the path may by now belong to another instance.
            var st = stat()
            if stat(socketPath, &st) == 0, st.st_ino == boundInode { unlink(socketPath) }
        }
        continuation.finish()
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            queue.async { [weak self] in self?.readAll(from: client) }
        }
    }

    private func readAll(from fd: Int32) {
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        // Reads stay on the accept queue so events keep the order they connected in: `/clear` sends a
        // `SessionEnd` and a `SessionStart` ten milliseconds apart. The helper writes the moment it
        // connects, so one second is generous, and it bounds what a stalled helper costs everyone else.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < 4 * 1024 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { data.append(buffer, count: n) } else { break }
        }
        guard !data.isEmpty else { return }
        do {
            continuation.yield(try HookEvent.decode(data))
        } catch {
            onUndecodable?(data, error)
        }
    }
}

public enum HookServerError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case posix(String, Int32)
    public var description: String {
        switch self {
        case .pathTooLong(let p): return "socket path too long (max 103 bytes): \(p)"
        case .posix(let call, let e): return "\(call) failed: \(String(cString: strerror(e))) (\(e))"
        }
    }
}

/// Client side, shared with the clinic-hook executable via source inclusion (it cannot depend on the package at runtime cheaply).
public enum HookClient {
    /// Sends `payload` to the socket. Returns false if the connection failed.
    @discardableResult
    public static func send(_ payload: Data, to socketPath: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } } == 0
        guard ok else { return false }
        var offset = 0
        while offset < payload.count {
            let n = payload.withUnsafeBytes { raw in write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        shutdown(fd, SHUT_WR)
        return true
    }
}
