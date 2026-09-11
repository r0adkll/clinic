import Foundation

/// Clinic's own persisted state (ADR-021). Overlays keyed by session id; never written into ~/.claude (ADR-018).
public struct ClinicState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var manualNames: [SessionID: String] = [:]
    public var favorites: Set<SessionID> = []
    public var archived: [SessionID: Date] = [:]
    public var projectOrder: [String] = []
    /// Every project Clinic has seen, and when it first saw it. Sidebar membership and default
    /// order both come from this, so a project outlives its sessions (ADR-077).
    public var projectsAddedAt: [String: Date] = [:]
    public var lastModelByProject: [String: String] = [:]
    public var lastWorktreeByProject: [String: Bool] = [:]
    /// Per-project worktree base, set from the composer (ADR-118). No entry = the Settings default.
    public var worktreeBaseByProject: [String: WorktreeBase] = [:]
    public var selectedSessionId: SessionID?
    public var windowFrame: [Double]?   // x, y, w, h
    public var mutedSessions: Set<SessionID> = []
    /// Sessions Clinic started or imported (ADR-048). The sidebar shows only these.
    public var ownedSessions: [SessionID: OwnedSession] = [:]
    /// Projects the user removed from the sidebar (ADR-050); their sessions stay owned but hidden.
    public var removedProjects: Set<String> = []
    /// Images shown via `show_image` (ADR-056), newest last.
    public var attachments: [SessionID: [Attachment]] = [:]
    /// Folded project groups (ADR-062).
    public var collapsedProjects: Set<String> = []
    /// Scheduled prompts (ADR-095). Definitions only — a handful of small records; their run history
    /// grows without bound and lives in its own file (`AutomationRunStore`) so state stays small.
    public var automations: [Automation] = []
    /// Per-project task source overrides (ADR-113). No entry = Automatic (whatever `gh` resolves in the
    /// folder); a list replaces that; an empty list = None.
    public var taskSources: [String: [WorkItemSource]] = [:]
    /// Sessions started from a task, and the task (ADR-114). Clinic's own record, so it lives here
    /// rather than on the transcript-derived `SessionSummary` a rescan rebuilds.
    public var workItemLinks: [SessionID: [WorkItemRef]] = [:]

    public init() {}

    /// Records a project the user added, started a session in, or imported into. Idempotent: an
    /// existing registration keeps its original date, so the project keeps its place (ADR-077).
    public mutating func registerProject(_ path: String, at date: Date = Date()) {
        guard !path.isEmpty else { return }
        removedProjects.remove(path)
        if projectsAddedAt[path] == nil { projectsAddedAt[path] = date }
    }

    /// Drops the registration without hiding the project's sessions: it disappears from the
    /// sidebar only while nothing visible lives in it (Archive Project, ADR-065).
    public mutating func unregisterProject(_ path: String) { projectsAddedAt[path] = nil }

    public struct Attachment: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var path: String
        public var caption: String?
        public var addedAt: Date
        public init(id: UUID = UUID(), path: String, caption: String? = nil, addedAt: Date = Date()) { self.id = id; self.path = path; self.caption = caption; self.addedAt = addedAt }
    }

    public struct OwnedSession: Codable, Sendable, Equatable {
        public var projectPath: String
        public var addedAt: Date
        public var imported: Bool
        public init(projectPath: String, addedAt: Date = Date(), imported: Bool = false) {
            self.projectPath = projectPath; self.addedAt = addedAt; self.imported = imported
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, manualNames, favorites, archived, projectOrder, projectsAddedAt, lastModelByProject, lastWorktreeByProject, worktreeBaseByProject, selectedSessionId, windowFrame, mutedSessions, ownedSessions, removedProjects, attachments, collapsedProjects, automations, taskSources, workItemLinks
    }

    /// Tolerant decoding so state files written by older builds keep loading when fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        manualNames = try Self.sessionMap(c, .manualNames, legacy: { $0 })
        favorites = try c.decodeIfPresent(Set<SessionID>.self, forKey: .favorites) ?? []
        archived = try Self.sessionMap(c, .archived, legacy: { ISO8601DateFormatter().date(from: $0) })
        projectOrder = try c.decodeIfPresent([String].self, forKey: .projectOrder) ?? []
        projectsAddedAt = try c.decodeIfPresent([String: Date].self, forKey: .projectsAddedAt) ?? [:]
        lastModelByProject = try c.decodeIfPresent([String: String].self, forKey: .lastModelByProject) ?? [:]
        lastWorktreeByProject = try c.decodeIfPresent([String: Bool].self, forKey: .lastWorktreeByProject) ?? [:]
        worktreeBaseByProject = (try? c.decodeIfPresent([String: WorktreeBase].self, forKey: .worktreeBaseByProject)) ?? [:]
        selectedSessionId = try c.decodeIfPresent(SessionID.self, forKey: .selectedSessionId)
        windowFrame = try c.decodeIfPresent([Double].self, forKey: .windowFrame)
        mutedSessions = try c.decodeIfPresent(Set<SessionID>.self, forKey: .mutedSessions) ?? []
        ownedSessions = (try? c.decodeIfPresent([SessionID: OwnedSession].self, forKey: .ownedSessions)) ?? [:]
        removedProjects = try c.decodeIfPresent(Set<String>.self, forKey: .removedProjects) ?? []
        attachments = (try? c.decodeIfPresent([SessionID: [Attachment]].self, forKey: .attachments)) ?? [:]
        collapsedProjects = try c.decodeIfPresent(Set<String>.self, forKey: .collapsedProjects) ?? []
        // Tolerant like the rest: an automation whose cron no longer parses is dropped rather than
        // failing the whole state file and taking the sidebar with it.
        automations = ((try? c.decodeIfPresent([FailableAutomation].self, forKey: .automations)) ?? [])?.compactMap(\.value) ?? []
        taskSources = (try? c.decodeIfPresent([String: [WorkItemSource]].self, forKey: .taskSources)) ?? [:]
        workItemLinks = (try? c.decodeIfPresent([SessionID: [WorkItemRef]].self, forKey: .workItemLinks)) ?? [:]
        if projectsAddedAt.isEmpty { migrateProjectRegistrations(from: decoder) }
    }

    /// Pre-ADR-077 builds derived sidebar membership from the live session list plus an
    /// `addedProjects` array that only the folder picker wrote, so a project vanished with its
    /// last session. Seed registrations from both: picked folders first (their real add dates are
    /// gone, so they keep only their relative order), then the first session Clinic owned in each.
    private mutating func migrateProjectRegistrations(from decoder: Decoder) {
        let legacy = (try? decoder.container(keyedBy: LegacyKeys.self))
            .flatMap { try? $0.decodeIfPresent([String].self, forKey: .addedProjects) } ?? []
        for (i, path) in legacy.enumerated() where !path.isEmpty {
            projectsAddedAt[path] = Date(timeIntervalSince1970: Double(i))
        }
        for owned in ownedSessions.values where !owned.projectPath.isEmpty {
            projectsAddedAt[owned.projectPath] = min(projectsAddedAt[owned.projectPath] ?? .distantFuture, owned.addedAt)
        }
    }

    private enum LegacyKeys: String, CodingKey { case addedProjects }

    /// Decodes one automation, or nothing. Wrapping the element rather than the array is what keeps a
    /// single bad record from emptying the list.
    private struct FailableAutomation: Decodable {
        let value: Automation?
        init(from decoder: Decoder) throws { value = try? Automation(from: decoder) }
    }

    /// Decodes a `[SessionID: T]` written as a JSON object, or the flat `[key, value, key, value]` array that
    /// pre-CodingKeyRepresentable builds wrote (values were strings in both legacy cases).
    private static func sessionMap<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, legacy: (String) -> T?) throws -> [SessionID: T] {
        if let map = try? c.decodeIfPresent([SessionID: T].self, forKey: key) { return map }
        guard let flat = try? c.decodeIfPresent([String].self, forKey: key) else { return [:] }
        var out: [SessionID: T] = [:]
        var i = 0
        while i + 1 < flat.count { if let v = legacy(flat[i + 1]) { out[SessionID(flat[i])] = v }; i += 2 }
        return out
    }
}

/// Atomic, debounced JSON persistence.
public actor StateStore {
    private let url: URL
    private var pendingWrite: Task<Void, Never>?
    private var current: ClinicState
    private let debounce: Duration
    /// State as loaded from disk at init; lets callers seed synchronously before any actor hop.
    public nonisolated let initialState: ClinicState

    public init(url: URL, debounce: Duration = .milliseconds(500)) {
        self.url = url
        self.debounce = debounce
        let loaded = (try? Self.load(from: url)) ?? ClinicState()
        self.current = loaded
        self.initialState = loaded
    }

    public static func defaultURL(appSupport: URL = ClinicPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("Clinic", isDirectory: true).appendingPathComponent("state.json")
    }

    public var state: ClinicState { current }

    public func update(_ mutate: (inout ClinicState) -> Void) {
        mutate(&current)
        schedule()
    }

    public func flush() async {
        pendingWrite?.cancel()
        pendingWrite = nil
        try? Self.write(current, to: url)
    }

    private func schedule() {
        pendingWrite?.cancel()
        pendingWrite = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.flushNow()
        }
    }

    private func flushNow() { try? Self.write(current, to: url) }

    static func load(from url: URL) throws -> ClinicState {
        let data = try Data(contentsOf: url)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ClinicState.self, from: data)
    }

    static func write(_ state: ClinicState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(state).write(to: url, options: .atomic)
    }
}
