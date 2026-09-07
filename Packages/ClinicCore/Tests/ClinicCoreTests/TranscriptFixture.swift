import Foundation
@testable import ClinicCore

/// Synthetic transcript builder (ADR-044). Mirrors the record shapes seen in real 2.1.x transcripts.
struct TranscriptFixture {
    let sessionId: SessionID
    var cwd: String
    var gitBranch: String? = "main"
    private(set) var lines: [String] = []

    init(sessionId: SessionID = SessionID("11111111-2222-3333-4444-555555555555"), cwd: String = "/Users/me/repo") {
        self.sessionId = sessionId; self.cwd = cwd
    }

    private func base(_ type: String, timestamp: String?) -> [String: Any] {
        var o: [String: Any] = ["type": type, "sessionId": sessionId.rawValue, "cwd": cwd, "uuid": UUID().uuidString, "isSidechain": false, "version": "2.1.263"]
        if let gitBranch { o["gitBranch"] = gitBranch }
        if let timestamp { o["timestamp"] = timestamp }
        return o
    }

    private mutating func append(_ obj: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        lines.append(String(decoding: data, as: UTF8.self))
    }

    mutating func user(_ text: String, at ts: String = "2026-09-07T10:00:00.000Z", meta: Bool = false) {
        var o = base("user", timestamp: ts)
        o["message"] = ["role": "user", "content": text]
        if meta { o["isMeta"] = true }
        append(o)
    }

    mutating func userBlocks(_ text: String, at ts: String = "2026-09-07T10:00:00.000Z") {
        var o = base("user", timestamp: ts)
        o["message"] = ["role": "user", "content": [["type": "text", "text": text]]]
        append(o)
    }

    mutating func assistant(_ text: String, model: String = "claude-sonnet-5", at ts: String = "2026-09-07T10:00:05.000Z") {
        var o = base("assistant", timestamp: ts)
        o["message"] = ["role": "assistant", "model": model, "content": [["type": "text", "text": text]]]
        append(o)
    }

    mutating func aiTitle(_ t: String) { append(["type": "ai-title", "aiTitle": t, "sessionId": sessionId.rawValue]) }
    mutating func customTitle(_ t: String) { append(["type": "custom-title", "customTitle": t, "sessionId": sessionId.rawValue]) }
    mutating func costState(_ usd: Double) { append(["type": "cost-state", "totalCostUSD": usd, "sessionId": sessionId.rawValue]) }
    mutating func unknown() { append(["type": "atis-latch", "atis": "", "sessionId": sessionId.rawValue]) }
    mutating func raw(_ s: String) { lines.append(s) }

    var data: Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
}
