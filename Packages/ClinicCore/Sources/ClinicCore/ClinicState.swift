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

    public init() {}
}

/// Atomic, debounced JSON persistence.
public actor StateStore {
    private let url: URL
    private var pendingWrite: Task<Void, Never>?
    private var current: ClinicState
    private let debounce: Duration

    public init(url: URL, debounce: Duration = .milliseconds(500)) {
        self.url = url
        self.debounce = debounce
        self.current = (try? Self.load(from: url)) ?? ClinicState()
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
