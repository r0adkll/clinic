import Foundation

/// The folder a crash leaves its evidence in (ADR-225): an uncaught exception's report with the workspace
/// as it stood, and the crash and hang diagnostics MetricKit delivers on a later launch. Plain files, so
/// the next session can read them without a debugger and without the unified log, which rolls over.
public struct DiagnosticsArchive: Sendable {
    public let directory: URL
    /// The newest files kept; older ones go each time a file is written.
    public let limit: Int

    public init(directory: URL, limit: Int = 30) {
        self.directory = directory
        self.limit = limit
    }

    /// `…/Application Support/Clinic/diagnostics`, or the development flavor's (ADR-176).
    public static var standard: DiagnosticsArchive {
        DiagnosticsArchive(directory: ClinicPaths.directory.appendingPathComponent("diagnostics", isDirectory: true))
    }

    /// `exception-2026-10-17T11-33-30.123Z.json`: sorts by time, and has no colons for the Finder to show as slashes.
    public static func fileName(kind: String, at date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return "\(kind)-\(f.string(from: date).replacingOccurrences(of: ":", with: "-")).json"
    }

    /// Writes one file and prunes to `limit`. Synchronous on purpose: an exception handler gets no second chance.
    @discardableResult
    public func write(_ data: Data, kind: String, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(kind: kind, at: date))
        try data.write(to: url, options: .atomic)
        prune()
        return url
    }

    /// The archive's files, newest first.
    public func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .sorted { Self.timestamp($0) > Self.timestamp($1) }
            .map { directory.appendingPathComponent($0) }
    }

    private func prune() {
        for url in files().dropFirst(limit) { try? FileManager.default.removeItem(at: url) }
    }

    /// The part of a file name after its kind, which sorts by time whatever the kind is.
    private static func timestamp(_ name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return name }
        return String(name[name.index(after: dash)...])
    }
}

/// An uncaught exception and what the window held when it was thrown (ADR-225).
public struct ExceptionReport: Codable, Sendable, Equatable {
    public var name: String
    public var reason: String?
    public var callStack: [String]
    public var date: Date
    public var appVersion: String
    public var osVersion: String
    /// Nil when the exception was off the main thread, or the dump itself failed.
    public var workspace: WorkspaceDump?
    /// What the app did just before (ADR-231). Nil in reports from before it.
    public var breadcrumbs: [Breadcrumb]?
    /// The layout loop running when it was thrown, if the loop witness had tripped (ADR-231).
    public var loop: LoopRecord?

    public init(name: String, reason: String?, callStack: [String], date: Date, appVersion: String, osVersion: String,
                workspace: WorkspaceDump? = nil, breadcrumbs: [Breadcrumb]? = nil, loop: LoopRecord? = nil) {
        self.name = name; self.reason = reason; self.callStack = callStack; self.date = date
        self.appVersion = appVersion; self.osVersion = osVersion; self.workspace = workspace
        self.breadcrumbs = breadcrumbs; self.loop = loop
    }

    public func encoded() throws -> Data { try DiagnosticsArchive.encoder.encode(self) }
}

extension DiagnosticsArchive {
    /// Pretty, sorted JSON with ISO 8601 dates to the millisecond: breadcrumbs a few milliseconds apart must
    /// stay in order when read (ADR-231).
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return e
    }

    /// Reads what `encoder` writes, and the whole-second dates of reports from before ADR-231.
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(text)")
        }
        return d
    }
}

/// The workspace as the window drew it: which session each window shows, every open session's tabs in
/// both areas, and the frames the areas were given. ADR-223 keeps no layout on disk, so without this
/// it dies with the process.
public struct WorkspaceDump: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public var id: String
        public var frame: String
        public var fullScreen: Bool
        public var isKey: Bool
        /// The session tab on screen, or nil for a screen or the composer.
        public var selectedTab: String?
        /// "Tasks", "New session" and so on, when the window shows no session.
        public var showing: String?
        /// The toolbar's per-session controls: "run", "device:android", "open-in".
        public var toolbar: [String]

        public init(id: String, frame: String, fullScreen: Bool, isKey: Bool, selectedTab: String?, showing: String?, toolbar: [String]) {
            self.id = id; self.frame = frame; self.fullScreen = fullScreen; self.isKey = isKey
            self.selectedTab = selectedTab; self.showing = showing; self.toolbar = toolbar
        }
    }

    public struct Area: Codable, Sendable, Equatable {
        /// Pane kinds in strip order, the front one marked with `*`.
        public var panes: [String]
        public var visible: Bool
        public var frame: String

        public init(panes: [String], visible: Bool, frame: String) {
            self.panes = panes; self.visible = visible; self.frame = frame
        }
    }

    public struct Tab: Codable, Sendable, Equatable {
        public var id: String
        public var window: String
        public var session: String?
        public var title: String
        public var project: String
        public var state: String?
        public var replay: Bool
        public var focusedArea: String
        public var main: Area
        public var panel: Area

        public init(id: String, window: String, session: String?, title: String, project: String, state: String?,
                    replay: Bool, focusedArea: String, main: Area, panel: Area) {
            self.id = id; self.window = window; self.session = session; self.title = title; self.project = project
            self.state = state; self.replay = replay; self.focusedArea = focusedArea; self.main = main; self.panel = panel
        }
    }

    public var windows: [Window]
    public var tabs: [Tab]

    public init(windows: [Window], tabs: [Tab]) {
        self.windows = windows; self.tabs = tabs
    }
}
