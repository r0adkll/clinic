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
    private let lock = NSLock()
    /// Raw payloads that failed to decode, for diagnostics.
    public var onUndecodable: (@Sendable (Data, Error) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
        var c: AsyncStream<HookEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public static func defaultSocketPath(appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> String {
        appSupport.appendingPathComponent("Clinic", isDirectory: true).appendingPathComponent("hook.sock").path
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listenFD < 0 else { return }
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
        let bindResult = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bindResult == 0 else { let e = errno; close(fd); throw HookServerError.posix("bind", e) }
        chmod(socketPath, 0o600)
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); throw HookServerError.posix("listen", e) }
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
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { listenFD = -1; unlink(socketPath) }
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
        var tv = timeval(tv_sec: 5, tv_usec: 0)
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
