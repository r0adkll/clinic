import Foundation

/// A session Claude Code is running detached (ADR-061), from `claude agents --json --all`.
public struct BackgroundAgent: Sendable, Hashable, Identifiable {
    public var id: String                 // the id `claude attach/stop/rm` take
    public var sessionId: SessionID?
    public var kind: String               // interactive | background_agent | …
    public var status: String             // busy | idle | running | stopped | …
    public var state: String?             // working | needs_input | idle | completed | failed
    public var waitingFor: String?        // permission | input | sandbox | dialog
    public var cwd: String?
    public var name: String?
    public var pid: Int?
    public var startedAt: Date?

    /// States meaning the agent has finished. The CLI documents `completed` and `failed`; what it
    /// actually reports on success is **`done`**, with `status` still `idle` and the process still
    /// resident and attachable (observed 2.1.266 while probing for ADR-095). Omitting it made every
    /// finished agent read as running forever: the sidebar kept its "running detached" badge, the row
    /// action stayed *Attach* instead of *Open*, *Stop Detached Session* stayed on the menu, upkeep
    /// thought the worktree was in use, and the 15 s poll never backed off to its idle interval.
    public static let terminalStates: Set<String> = ["completed", "failed", "stopped", "done"]
    /// States meaning it is waiting on the user. `needs_input` is documented; `blocked` is not
    /// (observed 2.1.263).
    public static let attentionStates: Set<String> = ["needs_input", "blocked"]
    /// Transitions worth a notification (ADR-061): it wants you, or it is over. A user-initiated
    /// `stopped` is deliberately absent — the user just did it and does not need telling.
    public static let announcedStates: Set<String> =
        attentionStates.union(terminalStates).subtracting(["stopped"])

    public var isBackground: Bool { kind == "background" || kind == "background_agent" }
    public var isRunning: Bool { !Self.terminalStates.contains(state ?? "") && status != "stopped" }
    public var needsAttention: Bool { Self.attentionStates.contains(state ?? "") || waitingFor != nil }

    public init(id: String, sessionId: SessionID?, kind: String, status: String, state: String? = nil, waitingFor: String? = nil, cwd: String? = nil, name: String? = nil, pid: Int? = nil, startedAt: Date? = nil) {
        self.id = id; self.sessionId = sessionId; self.kind = kind; self.status = status; self.state = state; self.waitingFor = waitingFor; self.cwd = cwd; self.name = name; self.pid = pid; self.startedAt = startedAt
    }

    /// Parses the CLI's JSON array. Tolerant of missing fields; entries without an id are skipped.
    public static func parse(_ data: Data) -> [BackgroundAgent] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let id = (o["id"] as? String) ?? (o["sessionId"] as? String) else { return nil }
            let started: Date? = {
                if let ms = o["startedAt"] as? NSNumber { return Date(timeIntervalSince1970: ms.doubleValue / (ms.doubleValue > 1e11 ? 1000 : 1)) }
                if let s = o["startedAt"] as? String { return TranscriptReader.parseDate(s) }
                return nil
            }()
            return BackgroundAgent(id: id, sessionId: (o["sessionId"] as? String).map(SessionID.init), kind: o["kind"] as? String ?? "",
                                   status: o["status"] as? String ?? "", state: o["state"] as? String, waitingFor: o["waitingFor"] as? String,
                                   cwd: o["cwd"] as? String, name: o["name"] as? String, pid: (o["pid"] as? NSNumber)?.intValue, startedAt: started)
        }
    }
}

/// Wraps the `claude agents|stop|rm|logs` subcommands (ADR-061).
public enum BackgroundAgentsCLI {
    public static func list(includeCompleted: Bool = true) async -> [BackgroundAgent] {
        var args = ["claude", "agents", "--json"]
        if includeCompleted { args.append("--all") }
        guard let data = await run(args) else { return [] }
        return BackgroundAgent.parse(data)
    }

    @discardableResult
    public static func stop(_ id: String) async -> Bool { await run(["claude", "stop", id]) != nil }
    @discardableResult
    public static func remove(_ id: String) async -> Bool { await run(["claude", "rm", id]) != nil }

    static func run(_ argv: [String]) async -> Data? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = argv
                var env = ProcessEnvironment.withToolPaths()
                for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" { env[key] = nil }
                p.environment = env
                let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
