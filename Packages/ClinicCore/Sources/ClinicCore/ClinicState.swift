import Foundation

/// Clinic's own persisted state (ADR-021). Overlays keyed by session id; never written into ~/.claude (ADR-018).
public struct ClinicState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var manualNames: [SessionID: String] = [:]
    public var favorites: Set<SessionID> = []
    public var archived: [SessionID: Date] = [:]
    public var projectOrder: [String] = []
    public var addedProjects: [String] = []
    public var lastModelByProject: [String: String] = [:]
    public var lastWorktreeByProject: [String: Bool] = [:]
    public var selectedSessionId: SessionID?
    public var windowFrame: [Double]?   // x, y, w, h
    public var mutedSessions: Set<SessionID> = []
    /// Sessions Clinic started or imported (ADR-048). The sidebar shows only these.
    public var ownedSessions: [SessionID: OwnedSession] = [:]
    /// Projects the user removed from the sidebar (ADR-050); their sessions stay owned but hidden.
    public var removedProjects: Set<String> = []

    public init() {}

    public struct OwnedSession: Codable, Sendable, Equatable {
        public var projectPath: String
        public var addedAt: Date
        public var imported: Bool
        public init(projectPath: String, addedAt: Date = Date(), imported: Bool = false) {
            self.projectPath = projectPath; self.addedAt = addedAt; self.imported = imported
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, manualNames, favorites, archived, projectOrder, addedProjects, lastModelByProject, lastWorktreeByProject, selectedSessionId, windowFrame, mutedSessions, ownedSessions, removedProjects
    }

    /// Tolerant decoding so state files written by older builds keep loading when fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        manualNames = try Self.sessionMap(c, .manualNames, legacy: { $0 })
        favorites = try c.decodeIfPresent(Set<SessionID>.self, forKey: .favorites) ?? []
        archived = try Self.sessionMap(c, .archived, legacy: { ISO8601DateFormatter().date(from: $0) })
        projectOrder = try c.decodeIfPresent([String].self, forKey: .projectOrder) ?? []
        addedProjects = try c.decodeIfPresent([String].self, forKey: .addedProjects) ?? []
        lastModelByProject = try c.decodeIfPresent([String: String].self, forKey: .lastModelByProject) ?? [:]
        lastWorktreeByProject = try c.decodeIfPresent([String: Bool].self, forKey: .lastWorktreeByProject) ?? [:]
        selectedSessionId = try c.decodeIfPresent(SessionID.self, forKey: .selectedSessionId)
        windowFrame = try c.decodeIfPresent([Double].self, forKey: .windowFrame)
        mutedSessions = try c.decodeIfPresent(Set<SessionID>.self, forKey: .mutedSessions) ?? []
        ownedSessions = (try? c.decodeIfPresent([SessionID: OwnedSession].self, forKey: .ownedSessions)) ?? [:]
        removedProjects = try c.decodeIfPresent(Set<String>.self, forKey: .removedProjects) ?? []
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

    public static func defaultURL(appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
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
