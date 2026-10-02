import Foundation
import Darwin

/// Unix-domain socket server receiving hook payloads from `clinic-hook` (ADR-015) and from Clinic's
/// session mod (ADR-177).
/// Protocol: one connection per payload. The helper writes the JSON document and closes its write side.
/// The mod can only speak HTTP, so it sends the same document as the body of a `POST` and is answered
/// `204`; `HookWire` tells the two apart by the first bytes.
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
        appSupport.appendingPathComponent(ClinicPaths.directoryName, isDirectory: true).appendingPathComponent("hook\(suffix).sock").path
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
        var message = HookWire.Message.incomplete
        while data.count < 4 * 1024 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
            // The helper ends its payload by closing; an HTTP client keeps the connection open and
            // waits for an answer, so its request is over when the body it announced has arrived.
            message = HookWire.read(data)
            if case .http = message { break }
        }
        guard !data.isEmpty else { return }
        let payload: Data
        switch message {
        case .http(let body):
            payload = body
            respond(HookWire.accepted, to: fd)
        case .incomplete:
            respond(HookWire.rejected, to: fd)
            onUndecodable?(data, HookServerError.truncatedRequest)
            return
        case .raw(let document):
            payload = document
        }
        do {
            continuation.yield(try HookEvent.decode(payload))
        } catch {
            onUndecodable?(payload, error)
        }
    }

    /// Best effort: a client that stopped waiting must not take the app down with `SIGPIPE`.
    private func respond(_ response: Data, to fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        response.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress, raw.count) }
    }
}

/// How one hook payload is framed on the socket (ADR-177).
///
/// `clinic-hook` writes a bare JSON document and closes. The session mod reaches the socket through the
/// CLI's `$.http.fetch`, which speaks HTTP: a `POST` with a `Content-Length` and the same document as
/// its body. A JSON document starts with `{`, so the request line is unambiguous.
public enum HookWire {
    public enum Message: Equatable, Sendable {
        /// A bare document, complete when the client closes.
        case raw(Data)
        /// A whole HTTP request; the associated value is its body.
        case http(body: Data)
        /// An HTTP request whose headers or body have not all arrived.
        case incomplete
    }

    public static let accepted = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    public static let rejected = Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

    private static let requestLine = Data("POST ".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    public static func read(_ data: Data) -> Message {
        guard data.starts(with: requestLine) else {
            // Fewer bytes than the method name could still become one.
            return data.count < requestLine.count && requestLine.starts(with: data) ? .incomplete : .raw(data)
        }
        guard let end = data.range(of: headerEnd) else { return .incomplete }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var length = 0
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .http(body: Data(body.prefix(length)))
    }
}

public enum HookServerError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case posix(String, Int32)
    case truncatedRequest
    public var description: String {
        switch self {
        case .truncatedRequest: return "an HTTP request ended before its body did"
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
