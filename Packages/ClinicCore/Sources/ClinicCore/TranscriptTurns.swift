import Foundation

/// Full-transcript reading for Replay and Details (ADR-059). Tolerant of unknown records and fields.
public enum TranscriptTurns {
    public enum Turn: Sendable, Hashable, Identifiable {
        case user(String, Date?)
        case assistant(String, Date?)
        case toolUse(name: String, summary: String, id: String, Date?)
        case toolResult(summary: String, isError: Bool, toolUseId: String?, Date?)

        public var id: String {
            switch self {
            case .user(let t, let d): return "u|\(d?.timeIntervalSince1970 ?? 0)|\(t.hashValue)"
            case .assistant(let t, let d): return "a|\(d?.timeIntervalSince1970 ?? 0)|\(t.hashValue)"
            case .toolUse(_, _, let id, _): return "t|\(id)"
            case .toolResult(let s, _, let id, let d): return "r|\(id ?? "")|\(d?.timeIntervalSince1970 ?? 0)|\(s.hashValue)"
            }
        }
        public var date: Date? {
            switch self { case .user(_, let d), .assistant(_, let d), .toolUse(_, _, _, let d), .toolResult(_, _, _, let d): return d }
        }
    }

    public struct Stats: Sendable, Hashable {
        public var userMessages = 0
        public var assistantMessages = 0
        public var thinkingBlocks = 0
        public var toolCalls: [String: Int] = [:]
        public var models: [String] = []
        public var inputTokens = 0
        public var outputTokens = 0
        public var cacheReadTokens = 0
        public var cacheCreationTokens = 0
        public var totalCostUSD: Double?
        public var firstAt: Date?
        public var lastAt: Date?
        public var fileSize: Int64 = 0
        public var mcpServers: [String] = []
        public var totalToolCalls: Int { toolCalls.values.reduce(0, +) }
        public var duration: TimeInterval? { if let a = firstAt, let b = lastAt { return b.timeIntervalSince(a) } else { return nil } }
        public init() {}
    }

    public struct Result: Sendable {
        public var turns: [Turn]
        public var stats: Stats
    }

    public static let maxFileSize: Int64 = 50 * 1024 * 1024

    public static func read(fileAt path: String) throws -> Result {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxFileSize else { throw TranscriptError.tooLarge(size) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var r = parse(data)
        r.stats.fileSize = size
        return r
    }

    public static func parse(_ data: Data) -> Result {
        var turns: [Turn] = []
        var stats = Stats()
        var seenModels = Set<String>(); var seenServers = Set<String>()
        for line in TranscriptReader.lines(in: data) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { continue }
            let date = (obj["timestamp"] as? String).flatMap(TranscriptReader.parseDate)
            if let date { if stats.firstAt == nil || date < stats.firstAt! { stats.firstAt = date }; if stats.lastAt == nil || date > stats.lastAt! { stats.lastAt = date } }
            switch type {
            case "user":
                guard (obj["isMeta"] as? Bool) != true, let message = obj["message"] as? [String: Any] else { continue }
                if let text = message["content"] as? String {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, !isInjected(t) else { continue }
                    turns.append(.user(t, date)); stats.userMessages += 1
                } else if let blocks = message["content"] as? [[String: Any]] {
                    var texts: [String] = []
                    for b in blocks {
                        switch b["type"] as? String {
                        case "text": if let t = b["text"] as? String, !isInjected(t.trimmingCharacters(in: .whitespaces)) { texts.append(t) }
                        case "tool_result":
                            turns.append(.toolResult(summary: resultSummary(b["content"]), isError: (b["is_error"] as? Bool) ?? false, toolUseId: b["tool_use_id"] as? String, date))
                        default: break
                        }
                    }
                    let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { turns.append(.user(joined, date)); stats.userMessages += 1 }
                }
            case "assistant":
                guard let message = obj["message"] as? [String: Any] else { continue }
                if let model = message["model"] as? String, !model.isEmpty, seenModels.insert(model).inserted { stats.models.append(model) }
                if let usage = message["usage"] as? [String: Any] {
                    stats.inputTokens += (usage["input_tokens"] as? Int) ?? 0
                    stats.outputTokens += (usage["output_tokens"] as? Int) ?? 0
                    stats.cacheReadTokens += (usage["cache_read_input_tokens"] as? Int) ?? 0
                    stats.cacheCreationTokens += (usage["cache_creation_input_tokens"] as? Int) ?? 0
                }
                var counted = false
                for b in message["content"] as? [[String: Any]] ?? [] {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { turns.append(.assistant(t, date)); counted = true }
                    case "thinking": stats.thinkingBlocks += 1
                    case "tool_use":
                        let name = b["name"] as? String ?? "tool"
                        stats.toolCalls[name, default: 0] += 1
                        if name.hasPrefix("mcp__"), let server = name.split(separator: "_", omittingEmptySubsequences: true).dropFirst().first, seenServers.insert(String(server)).inserted { stats.mcpServers.append(String(server)) }
                        turns.append(.toolUse(name: name, summary: toolSummary(name: name, input: b["input"] as? [String: Any] ?? [:]), id: b["id"] as? String ?? UUID().uuidString, date))
                        counted = true
                    default: break
                    }
                }
                if counted { stats.assistantMessages += 1 }
            case "cost-state":
                if let c = obj["totalCostUSD"] as? Double { stats.totalCostUSD = c }
            default: break
            }
        }
        return Result(turns: turns, stats: stats)
    }

    static func isInjected(_ t: String) -> Bool {
        t.hasPrefix("<system-reminder>") || t.hasPrefix("<local-command") || t.hasPrefix("<command-name>") || t.hasPrefix("<task-notification>")
    }

    /// One line describing a tool call: the command for Bash, the path for file tools, the first string field otherwise.
    public static func toolSummary(name: String, input: [String: Any]) -> String {
        let s: String?
        switch name {
        case "Bash": s = input["command"] as? String
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": s = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
        case "Grep", "Glob": s = [input["pattern"] as? String, input["path"] as? String].compactMap { $0 }.joined(separator: " in ")
        case "Agent", "Task": s = (input["description"] as? String) ?? (input["prompt"] as? String)
        case "WebFetch", "WebSearch": s = (input["url"] as? String) ?? (input["query"] as? String)
        default: s = input.values.compactMap { $0 as? String }.sorted { $0.count > $1.count }.first
        }
        let one = (s ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return one.count > 160 ? String(one.prefix(160)) + "…" : one
    }

    static func resultSummary(_ content: Any?) -> String {
        var text = ""
        if let s = content as? String { text = s }
        else if let blocks = content as? [[String: Any]] { text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
    }
}

public enum TranscriptError: Error, CustomStringConvertible {
    case tooLarge(Int64)
    public var description: String {
        switch self { case .tooLarge(let n): return "Transcript is \(n / 1_048_576) MB; replay is limited to \(TranscriptTurns.maxFileSize / 1_048_576) MB." }
    }
}
