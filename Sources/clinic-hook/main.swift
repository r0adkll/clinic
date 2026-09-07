// clinic-hook: forwards a Claude Code hook payload (stdin JSON) to Clinic's Unix socket (ADR-015).
// Usage: clinic-hook <socket-path>
// Always exits 0 so it can never block or fail the CLI. If the socket is unavailable and
// CLINIC_HOOK_TRACE_DIR is set, the payload is appended to a per-session trace file instead.
import Foundation
import Darwin

let args = CommandLine.arguments
guard args.count >= 2 else { exit(0) }
let socketPath = args[1]
var payload = FileHandle.standardInput.readDataToEndOfFile()
guard !payload.isEmpty else { exit(0) }
payload.append(0x0A)

func send(_ data: Data, to path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }) == 0 else { return false }
    var offset = 0
    while offset < data.count {
        let n = data.withUnsafeBytes { raw in write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset) }
        if n <= 0 { return false }
        offset += n
    }
    shutdown(fd, SHUT_WR)
    return true
}

if !send(payload, to: socketPath), let traceDir = ProcessInfo.processInfo.environment["CLINIC_HOOK_TRACE_DIR"] {
    let sessionId = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["session_id"] as? String ?? "unknown"
    let url = URL(fileURLWithPath: traceDir).appendingPathComponent("\(sessionId).jsonl")
    try? FileManager.default.createDirectory(atPath: traceDir, withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(payload); try? h.close() } else { try? payload.write(to: url) }
}
exit(0)
