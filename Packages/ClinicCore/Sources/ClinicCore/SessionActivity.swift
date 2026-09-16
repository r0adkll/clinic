import Foundation

/// What a live session is doing now and what it has set running, folded from its transcript (ADR-156).
///
/// The shapes are the CLI's (2.1.273), read off real transcripts rather than documented:
/// - an `Agent` (or older `Task`) tool use starts a subagent. Every agent now launches async — its
///   result is `toolUseResult.status == "async_launched"` with an `agentId` — and ends with a
///   `<task-notification>`. An older synchronous agent's result carries `status: "completed"`.
/// - `Bash` with `run_in_background` starts a shell; its result has `backgroundTaskId`.
/// - `Monitor` starts a watch; its result has `taskId`, and it too ends with a notification.
/// - `<task-notification>` (`<tool-use-id>`, `<task-id>`, `<status>`) arrives in a `queue-operation`
///   record, a `queued_command` attachment, or a user record whose `origin.kind` is `task-notification`,
///   often more than one of those for one event. Applying it is idempotent.
/// - a `system` record with subtype `away_summary` is the CLI's recap of the session.
///
/// Everything is optional and unknown records are ignored, like `TranscriptReader`.
public struct SessionActivity: Sendable, Hashable {
    public struct Child: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case agent, shell, monitor }
        public enum Outcome: String, Sendable { case running, completed, failed, stopped }

        /// The tool use that started it.
        public var id: String
        public var kind: Kind
        /// The tool's `description`, or the command when a shell has none.
        public var label: String
        /// A subagent's type (`Explore`, `general-purpose`).
        public var detail: String?
        public var startedAt: Date?
        public var endedAt: Date?
        public var outcome: Outcome = .running
        /// `agentId` for an agent, the task id for a shell or monitor.
        public var taskId: String?
        /// Where the CLI writes a shell's or monitor's output.
        public var outputFile: String?

        public var isRunning: Bool { outcome == .running }

        public init(id: String, kind: Kind, label: String, detail: String? = nil, startedAt: Date? = nil) {
            self.id = id; self.kind = kind; self.label = label; self.detail = detail; self.startedAt = startedAt
        }
    }

    /// The tool the main agent called last and has no result for yet.
    public struct Tool: Sendable, Hashable {
        public var id: String
        public var name: String
        /// `TranscriptTurns.toolSummary`: the command, the path, the pattern.
        public var summary: String
    }

    /// In start order. Running children stay until they end; finished ones until the next prompt.
    public private(set) var children: [Child] = []
    public private(set) var currentTool: Tool?
    /// The latest `away_summary`, cleared by the next prompt it no longer describes.
    public private(set) var recap: String?
    /// Input plus cache tokens of the last main-chain assistant message: what the context holds.
    public private(set) var contextTokens: Int?
    /// The raw model id of the last assistant message.
    public private(set) var model: String?
    /// Marketing names from the CLI's `model` attachments, by model id.
    private var modelNames: [String: String] = [:]
    private var lastAnnouncedModel: String?

    /// "Opus 5", when the CLI has named the model the session is using.
    public var modelName: String? {
        guard let id = model ?? lastAnnouncedModel else { return nil }
        return modelNames[id] ?? modelNames[id.components(separatedBy: "[").first ?? id]
    }

    public init() {}

    public var running: [Child] { children.filter(\.isRunning) }
    public var finished: [Child] { children.filter { !$0.isRunning } }

    // MARK: Folding

    public mutating func apply(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        apply(record: obj)
    }

    public mutating func apply(record obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }
        // Older CLIs wrote a subagent's own turns inline, marked as a sidechain. They are not the session's.
        if (obj["isSidechain"] as? Bool) == true { return }
        let date = (obj["timestamp"] as? String).flatMap(TranscriptReader.parseDate)
        switch type {
        case "assistant": applyAssistant(obj, date: date)
        case "user": applyUser(obj, date: date)
        case "queue-operation":
            if let content = obj["content"] as? String { applyNotifications(in: content, date: date) }
        case "attachment":
            guard let attachment = obj["attachment"] as? [String: Any] else { return }
            switch attachment["type"] as? String {
            case "queued_command":
                if let prompt = attachment["prompt"] as? String { applyNotifications(in: prompt, date: date) }
            case "model":
                if let identity = attachment["identity"] as? [String: Any], let id = identity["modelId"] as? String,
                   let name = identity["marketingName"] as? String, !name.isEmpty {
                    modelNames[id] = name
                    lastAnnouncedModel = id
                }
            default: break
            }
        case "system":
            switch obj["subtype"] as? String {
            case "away_summary":
                if let content = obj["content"] as? String { recap = Self.cleanRecap(content) }
            case "turn_duration":
                currentTool = nil
            default: break
            }
        default:
            break
        }
    }

    private mutating func applyAssistant(_ obj: [String: Any], date: Date?) {
        guard let message = obj["message"] as? [String: Any] else { return }
        if let m = message["model"] as? String, !m.isEmpty, m != "<synthetic>" { model = m }
        if let usage = message["usage"] as? [String: Any] {
            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            if tokens > 0 { contextTokens = tokens }
        }
        for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            currentTool = Tool(id: id, name: name, summary: TranscriptTurns.toolSummary(name: name, input: input))
            let description = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch name {
            case "Agent", "Task":
                add(Child(id: id, kind: .agent, label: description ?? "Subagent",
                          detail: input["subagent_type"] as? String, startedAt: date))
            case "Bash" where (input["run_in_background"] as? Bool) == true:
                let command = (input["command"] as? String)?.split(whereSeparator: \.isNewline).first.map(String.init)
                add(Child(id: id, kind: .shell, label: description ?? command ?? "Background shell", startedAt: date))
            case "Monitor":
                add(Child(id: id, kind: .monitor, label: description ?? "Monitor", startedAt: date))
            default:
                break
            }
        }
    }

    private mutating func applyUser(_ obj: [String: Any], date: Date?) {
        let message = obj["message"] as? [String: Any]
        let content = message?["content"]
        let result = obj["toolUseResult"]

        if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let toolUseId = block["tool_use_id"] as? String else { continue }
                applyResult(toolUseId: toolUseId, isError: (block["is_error"] as? Bool) == true,
                            text: TranscriptTurns.resultSummary(block["content"]), result: result as? [String: Any], date: date)
            }
            return
        }

        let text: String? = (content as? String) ?? (content as? [[String: Any]])?
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        guard let text else { return }
        let origin = (obj["origin"] as? [String: Any])?["kind"] as? String
        if origin == "task-notification" || text.contains("<task-notification>") {
            applyNotifications(in: text, date: date)
            return
        }
        guard (obj["isMeta"] as? Bool) != true, origin == nil || origin == "human" else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !TranscriptTurns.isInjected(trimmed) else { return }
        // A real prompt: what finished last turn has been seen, and the recap describes the past.
        children.removeAll { !$0.isRunning }
        currentTool = nil
        recap = nil
    }

    private mutating func applyResult(toolUseId: String, isError: Bool, text: String, result: [String: Any]?, date: Date?) {
        if currentTool?.id == toolUseId { currentTool = nil }
        // `TaskStop` names the task it stopped; the notification that follows may never be written.
        if let taskId = result?["task_id"] as? String, (result?["message"] as? String)?.hasPrefix("Successfully stopped") == true {
            end(where: { $0.taskId == taskId }, outcome: .stopped, date: date)
        }
        guard let i = children.firstIndex(where: { $0.id == toolUseId }) else { return }
        if isError {
            // Denied, or refused before it started: it never ran, so it is not a child.
            children.remove(at: i)
            return
        }
        let taskId = (result?["backgroundTaskId"] as? String) ?? (result?["agentId"] as? String) ?? (result?["taskId"] as? String)
        if let taskId { children[i].taskId = taskId }
        if let file = result?["outputFile"] as? String, file.hasPrefix("/") { children[i].outputFile = file }
        else if let file = Self.outputFile(in: text) { children[i].outputFile = file }

        // The text is checked as well as `toolUseResult`, which not every record carries.
        let backgrounded: Bool = switch children[i].kind {
        case .agent: result?["status"] as? String == "async_launched" || result?["isAsync"] as? Bool == true
            || text.hasPrefix("Async agent launched")
        case .shell: taskId != nil || text.hasPrefix("Command running in background")
        case .monitor: taskId != nil || text.hasPrefix("Monitor started")
        }
        if !backgrounded {
            // A synchronous agent's result is its end; a shell or monitor ran in the foreground after all.
            finish(at: i, outcome: result?["status"] as? String == "failed" ? .failed : .completed, date: date)
        }
    }

    private mutating func applyNotifications(in text: String, date: Date?) {
        for note in Self.notifications(in: text) {
            let outcome: Child.Outcome = switch note.status {
            case "completed": .completed
            case "stopped": .stopped
            case "failed", "killed", "error": .failed
            default: .running
            }
            guard outcome != .running else { continue }
            end(where: { child in
                (note.toolUseId != nil && child.id == note.toolUseId) || (note.taskId != nil && child.taskId == note.taskId)
            }, outcome: outcome, date: date)
            if let file = note.outputFile, let i = children.firstIndex(where: { $0.id == note.toolUseId }), children[i].outputFile == nil {
                children[i].outputFile = file
            }
        }
    }

    private mutating func add(_ child: Child) {
        guard !children.contains(where: { $0.id == child.id }) else { return }
        children.append(child)
    }

    private mutating func end(where match: (Child) -> Bool, outcome: Child.Outcome, date: Date?) {
        guard let i = children.firstIndex(where: match), children[i].isRunning else { return }
        finish(at: i, outcome: outcome, date: date)
    }

    private mutating func finish(at i: Int, outcome: Child.Outcome, date: Date?) {
        children[i].outcome = outcome
        children[i].endedAt = date ?? children[i].startedAt
    }

    // MARK: Parsing helpers

    struct Notification: Equatable {
        var taskId: String?
        var toolUseId: String?
        var status: String?
        var outputFile: String?
    }

    static func notifications(in text: String) -> [Notification] {
        text.components(separatedBy: "<task-notification>").dropFirst().map { chunk in
            let body = chunk.components(separatedBy: "</task-notification>").first ?? chunk
            return Notification(taskId: tag("task-id", in: body), toolUseId: tag("tool-use-id", in: body),
                                status: tag("status", in: body), outputFile: tag("output-file", in: body))
        }
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// "Command running in background with ID: b1. Output is being written to: /private/tmp/…/b1.output. You will…"
    static func outputFile(in text: String) -> String? {
        guard let marker = text.range(of: "Output is being written to: ") else { return nil }
        let rest = text[marker.upperBound...]
        let path = rest.prefix { !$0.isWhitespace }
        let trimmed = path.hasSuffix(".") ? String(path.dropLast()) : String(path)
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    /// The CLI appends a hint about switching recaps off; the card has no use for it.
    static func cleanRecap(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hint = t.range(of: "(disable recaps in /config)", options: .backwards) {
            t = t[..<hint.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t.isEmpty ? nil : t
    }
}

/// Reads a transcript as it grows, folding only the bytes appended since the last look (ADR-156).
///
/// `TranscriptReader` reads a bounded head and tail, which is right for a sidebar row and wrong for
/// following a turn: a tool use and its result can sit megabytes apart. This keeps a byte offset and a
/// partial last line, so each poll costs what was written since the previous one. The first poll
/// starts `initialWindow` bytes from the end rather than at zero, bounding the cost of opening a very
/// long session; a child started before that window is not seen.
public actor TranscriptFollower {
    public nonisolated let path: String
    private let initialWindow: Int64
    private var offset: Int64?
    private var partial = Data()
    private var activity = SessionActivity()

    public init(path: String, initialWindow: Int64 = 8 * 1024 * 1024) {
        self.path = path; self.initialWindow = initialWindow
    }

    /// Reads what is new. Returns the activity when anything was folded, nil when nothing changed.
    public func poll() -> SessionActivity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        var dropLeading = false
        if offset == nil || size < offset! {
            // First look, or the file was replaced: start over.
            activity = SessionActivity()
            partial = Data()
            offset = max(0, size - initialWindow)
            dropLeading = offset! > 0
        }
        guard size > offset!, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset!)) } catch { return nil }
        guard let data = try? handle.read(upToCount: Int(size - offset!)), !data.isEmpty else { return nil }
        offset! += Int64(data.count)

        var buffer = partial + data
        if dropLeading, let newline = buffer.firstIndex(of: 0x0A) {
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if let last = buffer.lastIndex(of: 0x0A) {
            partial = Data(buffer[buffer.index(after: last)...])
            buffer = Data(buffer[...last])
        } else {
            partial = buffer
            return nil
        }
        for line in TranscriptReader.lines(in: buffer) { activity.apply(line: line) }
        return activity
    }
}

/// Display names for model ids (ADR-156): `claude-opus-5` → "Opus 5", `claude-sonnet-4-5-20250929[1m]` → "Sonnet 4.5".
public enum ModelName {
    public static func display(_ id: String) -> String {
        var s = id
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }
        if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
        var parts = s.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, family.first?.isLetter == true else { return id }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }
        return ([family.capitalized] + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }
}
