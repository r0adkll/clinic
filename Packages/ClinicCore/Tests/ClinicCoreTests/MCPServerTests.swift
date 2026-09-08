import Foundation
import Testing
@testable import ClinicCore

@Suite struct MCPServerTests {
    @Test func roundTripsAToolCall() async throws {
        let path = "/tmp/clinic-mcp-\(UInt32.random(in: 0...UInt32.max)).sock"
        let server = MCPServer(socketPath: path)
        server.handler = { req in
            if req.method == "tools/list" { return MCPServer.Response(["result": ["tools": MCPToolSpec.all.map(\.listEntry)]]) }
            return MCPServer.Response(MCPToolSpec.textResult("echo:\(req.arguments["message"] ?? "") for \(req.sessionId.rawValue)"))
        }
        try server.start()
        defer { server.stop() }
        let sid = SessionID("11111111-2222-3333-4444-555555555555")
        let request: [String: Any] = ["session_id": sid.rawValue, "method": "tools/call", "params": ["name": "notify_user", "arguments": ["message": "hi"]]]
        let payload = try JSONSerialization.data(withJSONObject: request) + Data([0x0A])
        let reply = await Task.detached { () -> Data? in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) } }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }) == 0 else { return nil }
            _ = payload.withUnsafeBytes { raw in write(fd, raw.baseAddress!, payload.count) }
            shutdown(fd, SHUT_WR)
            var out = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while true { let n = read(fd, &buf, buf.count); if n > 0 { out.append(buf, count: n) } else { break } }
            return out
        }.value
        let replyData = try #require(reply)
        let obj = try #require(try JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        let result = try #require(obj["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect((content.first?["text"] as? String)?.hasPrefix("echo:hi") == true)
    }
}
