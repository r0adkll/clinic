import Foundation
import Darwin

/// Request/response Unix socket server for the MCP shim (ADR-056). One NDJSON request per connection, one JSON response.
public final class MCPServer: @unchecked Sendable {
    /// JSON-carrying request; the dictionary is only ever read, so unchecked Sendable is sound here.
    public struct Request: @unchecked Sendable {
        public var sessionId: SessionID
        public var method: String       // tools/list | tools/call
        public var params: [String: Any]
        public var toolName: String? { params["name"] as? String }
        public var arguments: [String: Any] { params["arguments"] as? [String: Any] ?? [:] }
    }

    public let socketPath: String
    /// JSON-carrying response wrapper (see Request).
    public struct Response: @unchecked Sendable {
        public var json: [String: Any]
        public init(_ json: [String: Any]) { self.json = json }
    }
    /// Set by the app; must return `result` or `error` in the wrapped dictionary.
    public var handler: (@Sendable (Request) async -> Response)?
    private let queue = DispatchQueue(label: "com.r0adkll.clinic.mcp-server", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let lock = NSLock()

    public init(socketPath: String) { self.socketPath = socketPath }

    public static func defaultSocketPath(appSupport: URL = ClinicPaths.appSupport) -> String {
        appSupport.appendingPathComponent("Clinic", isDirectory: true).appendingPathComponent("mcp.sock").path
    }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listenFD < 0 else { return }
        guard socketPath.utf8.count < 104 else { throw HookServerError.pathTooLong(socketPath) }
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.posix("socket", errno) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in socketPath.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) } }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }) == 0 else { let e = errno; close(fd); throw HookServerError.posix("bind", e) }
        chmod(socketPath, 0o600)
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); throw HookServerError.posix("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "com.r0adkll.clinic.mcp-accept"))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        acceptSource?.cancel(); acceptSource = nil
        if listenFD >= 0 { listenFD = -1; unlink(socketPath) }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data(); var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < 4 * 1024 * 1024 {
            let n = read(fd, &buf, buf.count)
            if n > 0 { data.append(buf, count: n) } else { break }
            if data.last == 0x0A { break }
        }
        let response: [String: Any]
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sid = obj["session_id"] as? String, let method = obj["method"] as? String, let handler {
            let req = Request(sessionId: SessionID(sid), method: method, params: obj["params"] as? [String: Any] ?? [:])
            let sem = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            Task { box.value = await handler(req).json; sem.signal() }
            if sem.wait(timeout: .now() + 20) == .timedOut { response = ["error": ["code": -32000, "message": "Clinic timed out handling \(method)"]] }
            else { response = box.value ?? ["error": ["code": -32603, "message": "No response"]] }
        } else {
            response = ["error": ["code": -32600, "message": "Invalid request"]]
        }
        if var out = try? JSONSerialization.data(withJSONObject: response) {
            out.append(0x0A)
            _ = out.withUnsafeBytes { raw in write(fd, raw.baseAddress!, out.count) }
        }
        shutdown(fd, SHUT_WR)
        close(fd)
    }

    private final class ResponseBox: @unchecked Sendable { var value: [String: Any]? }
}

/// Tool descriptions in MCP `tools/list` form. Handlers live in the app; this is the shared catalogue.
public struct MCPToolSpec: Sendable, Identifiable, Hashable {
    public var name: String
    public var description: String
    public var schema: String   // JSON schema text (kept as a string so the struct stays Sendable/Hashable)
    public var defaultEnabled: Bool
    public var id: String { name }

    public var listEntry: [String: Any] {
        let schemaObj = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) ?? ["type": "object"]
        return ["name": name, "description": description, "inputSchema": schemaObj]
    }

    public static let all: [MCPToolSpec] = [
        MCPToolSpec(name: "set_session_title", description: "Set the title Clinic shows for this session in its sidebar. Call once you know what the session is about (≤ 8 words).", schema: #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#, defaultEnabled: true),
        MCPToolSpec(name: "notify_user", description: "Notify the user through Clinic (system notification when they are away). Use when you need their attention or finished something they asked to be told about.", schema: #"{"type":"object","properties":{"message":{"type":"string"},"title":{"type":"string"}},"required":["message"]}"#, defaultEnabled: true),
        MCPToolSpec(name: "show_image", description: "Show an image file to the user in Clinic's attachments panel (screenshots, diagrams, generated images). Path must be absolute.", schema: #"{"type":"object","properties":{"path":{"type":"string"},"caption":{"type":"string"}},"required":["path"]}"#, defaultEnabled: true),
        MCPToolSpec(name: "read_terminal", description: "Read the text currently visible in this session's terminal (what the user sees), up to `lines` lines from the bottom.", schema: #"{"type":"object","properties":{"lines":{"type":"integer","minimum":1,"maximum":500}}}"#, defaultEnabled: true),
        MCPToolSpec(name: "run_in_terminal", description: "Type a shell command into the user's shell panel beside this session (not your own tool shell). The user sees it run. Returns immediately.", schema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#, defaultEnabled: false),
        MCPToolSpec(name: "attach_pr", description: "Attach a GitHub pull request URL to this session so Clinic shows its status and page.", schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#, defaultEnabled: true),
        MCPToolSpec(name: "start_session", description: "Start a sibling Claude Code session in Clinic (background tab) with an initial prompt, optionally in another directory.", schema: #"{"type":"object","properties":{"prompt":{"type":"string"},"directory":{"type":"string"},"model":{"type":"string"}},"required":["prompt"]}"#, defaultEnabled: true),
        // Run configurations (ADR-122): the project's own `.clinic/run.json`, in this session's checkout.
        MCPToolSpec(name: "list_run_configurations", description: "List this project's run configurations (from .clinic/run.json) with each one's state in this session's checkout: not started, running, succeeded, failed or stopped.", schema: #"{"type":"object","properties":{}}"#, defaultEnabled: true),
        MCPToolSpec(name: "run", description: "Start (or restart) one of this project's run configurations in this session's checkout, e.g. to launch the app after a change. Returns at once; poll read_run_output for the result. Only commands the user has run or saved in Clinic are allowed.", schema: #"{"type":"object","properties":{"name":{"type":"string","description":"The configuration's name or id"}},"required":["name"]}"#, defaultEnabled: true),
        MCPToolSpec(name: "read_run_output", description: "Read a run's state (running, succeeded, failed with its exit code, stopped), how long it ran, and the last `lines` lines of its output.", schema: #"{"type":"object","properties":{"name":{"type":"string"},"lines":{"type":"integer","minimum":1,"maximum":1000}},"required":["name"]}"#, defaultEnabled: true),
        MCPToolSpec(name: "stop_run", description: "Stop a running run configuration in this session's checkout.", schema: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#, defaultEnabled: true),
    ]

    public static func textResult(_ text: String, isError: Bool = false) -> [String: Any] {
        var r: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError { r["isError"] = true }
        return ["result": r]
    }
}

/// Per-session `--mcp-config` file contents (ADR-056).
public enum MCPConfig {
    public static func json(helperPath: String, socketPath: String, sessionId: SessionID) throws -> Data {
        let root: [String: Any] = ["mcpServers": ["clinic": ["type": "stdio", "command": helperPath, "args": ["mcp", socketPath, sessionId.rawValue]]]]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
