import Foundation

/// Bounded head/tail reader for Claude Code transcript JSONL (ADR-029).
/// The format is internal to Claude Code and undocumented; every field is optional and unknown record types are ignored.
public struct TranscriptReader: Sendable {
    public var headLimit: Int = 256 * 1024
    public var tailLimit: Int = 64 * 1024

    public init(headLimit: Int = 256 * 1024, tailLimit: Int = 64 * 1024) {
        self.headLimit = headLimit; self.tailLimit = tailLimit
    }

    public func read(fileAt path: String) throws -> SessionSummary {
        let url = URL(fileURLWithPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let headData = try handle.read(upToCount: headLimit) ?? Data()
        var tailData = Data()
        if size > Int64(headLimit) {
            let tailStart = max(Int64(headLimit), size - Int64(tailLimit))
            try handle.seek(toOffset: UInt64(tailStart))
            tailData = try handle.readToEnd() ?? Data()
        }
        let idFromName = SessionID((url.lastPathComponent as NSString).deletingPathExtension)
        return parse(id: idFromName, path: path, head: headData, tail: tailData, size: size, mtime: mtime)
    }

    /// Pure parser, used by tests with synthetic fixtures (ADR-044).
    public func parse(id: SessionID, path: String, head: Data, tail: Data, size: Int64 = 0, mtime: Date = .distantPast) -> SessionSummary {
        var s = SessionSummary(id: id, transcriptPath: path, fileSize: size, fileModifiedAt: mtime)
        let headLines = Self.lines(in: head, dropTrailingPartial: !tail.isEmpty || size > Int64(head.count))
        let tailLines = tail.isEmpty ? [] : Self.lines(in: tail, dropLeadingPartial: true)

        for line in headLines { apply(record: line, to: &s, fromHead: true) }
        for line in tailLines { apply(record: line, to: &s, fromHead: false) }
        return s
    }

    private func apply(record: Data, to s: inout SessionSummary, fromHead: Bool) {
        guard let obj = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if let sid = obj["sessionId"] as? String ?? obj["session_id"] as? String, !sid.isEmpty, fromHead, s.cwd == nil {
            // Trust the file name for identity, but a mismatch is worth surfacing later via diagnostics.
            _ = sid
        }
        if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            if s.cwd == nil { s.cwd = cwd }
            s.lastCwd = cwd
        }
        if let branch = obj["gitBranch"] as? String, !branch.isEmpty { s.gitBranch = branch }
        if let ts = obj["timestamp"] as? String, let date = Self.parseDate(ts) {
            if s.createdAt == nil || date < s.createdAt! { s.createdAt = date }
            if s.lastActivityAt == nil || date > s.lastActivityAt! { s.lastActivityAt = date }
        }
        switch type {
        case "user":
            if s.firstPrompt == nil, (obj["isMeta"] as? Bool) != true, (obj["isCompactSummary"] as? Bool) != true,
               let text = Self.userText(from: obj["message"]), !text.isEmpty, !Self.looksLikeSystemInjected(text) {
                s.firstPrompt = text
                for ref in PullRequestRef.refs(in: text, fromPrompt: true) { Self.link(ref, into: &s) }
            }
        case "assistant":
            if let message = obj["message"] as? [String: Any] {
                if let model = message["model"] as? String, !model.isEmpty { s.model = model }
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    guard let name = block["name"] as? String, Self.writingTools.contains(name),
                          let input = block["input"] as? [String: Any],
                          let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String), path.hasPrefix("/") else { continue }
                    s.recentFiles.removeAll { $0 == path }
                    s.recentFiles.append(path)
                    if s.recentFiles.count > 50 { s.recentFiles.removeFirst(s.recentFiles.count - 50) }
                }
            }
        case "ai-title":
            if let t = obj["aiTitle"] as? String, !t.isEmpty { s.aiTitle = t }
        case "custom-title":
            if let t = obj["customTitle"] as? String, !t.isEmpty { s.customTitle = t }
        case "cost-state":
            if let c = obj["totalCostUSD"] as? Double { s.totalCostUSD = c }
        case "pr-link":
            // {"type":"pr-link","prNumber":1040,"prUrl":"https://github.com/o/r/pull/1040","prRepository":"o/r",…}
            if let ref = Self.pullRequestRef(from: obj) { Self.link(ref, into: &s) }
        default:
            break
        }
    }

    private static func pullRequestRef(from obj: [String: Any]) -> PullRequestRef? {
        if let raw = obj["prUrl"] as? String, let url = URL(string: raw), let ref = PullRequestRef(url: url) { return ref }
        // Fall back to number + repository when the URL is missing or malformed.
        guard let number = (obj["prNumber"] as? NSNumber)?.intValue ?? Int(obj["prNumber"] as? String ?? ""),
              let repo = obj["prRepository"] as? String, repo.split(separator: "/").count == 2,
              let url = URL(string: "https://github.com/\(repo)/pull/\(number)") else { return nil }
        return PullRequestRef(number: number, repository: repo, url: url)
    }

    /// Unique by URL, newest link last; a prompt-derived flag survives a later `pr-link` for the same URL.
    private static func link(_ ref: PullRequestRef, into s: inout SessionSummary) {
        var ref = ref
        if let i = s.pullRequests.firstIndex(where: { $0.id == ref.id }) {
            ref.fromPrompt = ref.fromPrompt || s.pullRequests[i].fromPrompt
            s.pullRequests.remove(at: i)
        }
        s.pullRequests.append(ref)
    }

    static let writingTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    private static func userText(from message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func looksLikeSystemInjected(_ text: String) -> Bool {
        text.hasPrefix("<") && (text.hasPrefix("<system-reminder>") || text.hasPrefix("<local-command") || text.hasPrefix("<command-name>"))
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func parseDate(_ s: String) -> Date? { isoFractional.date(from: s) ?? iso.date(from: s) }

    static func lines(in data: Data, dropLeadingPartial: Bool = false, dropTrailingPartial: Bool = false) -> [Data] {
        var result: [Data] = []
        var start = data.startIndex
        var isFirst = true
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            let complete = end < data.endIndex
            if !(isFirst && dropLeadingPartial) && !(!complete && dropTrailingPartial) && !line.isEmpty {
                result.append(Data(line))
            }
            isFirst = false
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return result
    }
}
