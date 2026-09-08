// clinic-hook: two modes, no dependencies, always exits 0.
//   clinic-hook <socket-path>                     forward a Claude Code hook payload (stdin JSON) to Clinic (ADR-015)
//   clinic-hook mcp <socket-path> <session-id>    MCP stdio server relaying tools/list and tools/call to Clinic (ADR-056)
import Foundation
import Darwin

// MARK: - Unix socket client

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }) == 0 else { close(fd); return nil }
    return fd
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    while offset < data.count {
        let n = data.withUnsafeBytes { raw in write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset) }
        if n <= 0 { return false }
        offset += n
    }
    return true
}

func readAll(_ fd: Int32, timeoutSeconds: Int = 20) -> Data {
    var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var data = Data(); var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count < 8 * 1024 * 1024 {
        let n = read(fd, &buf, buf.count)
        if n > 0 { data.append(buf, count: n) } else { break }
    }
    return data
}

/// One request → one response over a fresh connection.
func roundTrip(socketPath: String, payload: Data) -> Data? {
    guard let fd = connectSocket(socketPath) else { return nil }
    defer { close(fd) }
    var out = payload; out.append(0x0A)
    guard writeAll(fd, out) else { return nil }
    shutdown(fd, SHUT_WR)
    let response = readAll(fd)
    return response.isEmpty ? nil : response
}

// MARK: - Hook mode

func runHookMode(socketPath: String) {
    var payload = FileHandle.standardInput.readDataToEndOfFile()
    guard !payload.isEmpty else { return }
    payload.append(0x0A)
    if let fd = connectSocket(socketPath) {
        _ = writeAll(fd, payload); shutdown(fd, SHUT_WR); close(fd)
    } else if let traceDir = ProcessInfo.processInfo.environment["CLINIC_HOOK_TRACE_DIR"] {
        let sessionId = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["session_id"] as? String ?? "unknown"
        let url = URL(fileURLWithPath: traceDir).appendingPathComponent("\(sessionId).jsonl")
        try? FileManager.default.createDirectory(atPath: traceDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(payload); try? h.close() } else { try? payload.write(to: url) }
    }
}

// MARK: - MCP stdio mode

struct JSONRPC {
    static func response(id: Any, result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    static func error(id: Any?, code: Int, message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]] }
}

final class MCPShim {
    let socketPath: String
    let sessionId: String
    let stdout = FileHandle.standardOutput
    let lock = NSLock()

    init(socketPath: String, sessionId: String) { self.socketPath = socketPath; self.sessionId = sessionId }

    func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        lock.lock(); stdout.write(data); lock.unlock()
    }

    /// Relay to Clinic; nil when the app is unreachable.
    func relay(method: String, params: Any?) -> [String: Any]? {
        let req: [String: Any] = ["session_id": sessionId, "method": method, "params": params ?? [:]]
        guard let payload = try? JSONSerialization.data(withJSONObject: req),
              let data = roundTrip(socketPath: socketPath, payload: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]
        switch method {
        case "initialize":
            let requested = (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
            send(JSONRPC.response(id: id ?? NSNull(), result: [
                "protocolVersion": requested,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "clinic", "version": "0.1.0"],
                "instructions": "Tools provided by Clinic, the macOS app hosting this session. Use notify_user when you need the user's attention and set_session_title once you know what the session is about.",
            ]))
        case "notifications/initialized", "notifications/cancelled":
            break
        case "ping":
            send(JSONRPC.response(id: id ?? NSNull(), result: [:]))
        case "tools/list":
            if let r = relay(method: "tools/list", params: msg["params"]), let result = r["result"] {
                send(JSONRPC.response(id: id ?? NSNull(), result: result))
            } else {
                send(JSONRPC.response(id: id ?? NSNull(), result: ["tools": []]))
            }
        case "tools/call":
            if let r = relay(method: "tools/call", params: msg["params"]) {
                if let result = r["result"] { send(JSONRPC.response(id: id ?? NSNull(), result: result)) }
                else if let err = r["error"] as? [String: Any] { send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": err]) }
                else { send(JSONRPC.error(id: id, code: -32603, message: "Empty response from Clinic")) }
            } else {
                send(JSONRPC.response(id: id ?? NSNull(), result: ["content": [["type": "text", "text": "Clinic is not running; tool unavailable."]], "isError": true]))
            }
        default:
            if id != nil { send(JSONRPC.error(id: id, code: -32601, message: "Method not found: \(method)")) }
        }
    }

    func run() {
        // Line-delimited JSON on stdin (Claude Code's stdio transport); each message handled on its own thread so a slow tool cannot block pings.
        let stdin = FileHandle.standardInput
        var buffer = Data()
        let inflight = DispatchGroup()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty, let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                inflight.enter()
                Thread.detachNewThread { [self] in self.handle(msg); inflight.leave() }
            }
        }
        // stdin closed: let in-flight tool calls finish before exiting.
        _ = inflight.wait(timeout: .now() + 25)
    }
}

// MARK: - Entry

let args = CommandLine.arguments
if args.count >= 4, args[1] == "mcp" {
    signal(SIGPIPE, SIG_IGN)
    MCPShim(socketPath: args[2], sessionId: args[3]).run()
} else if args.count >= 2 {
    runHookMode(socketPath: args[1])
}
exit(0)
