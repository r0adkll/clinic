import Foundation

/// One thing the app did, for the trail a crash or layout-loop report carries (ADR-231).
public struct Breadcrumb: Codable, Sendable, Equatable {
    /// When it last happened.
    public var date: Date
    /// "hook", "state", "terminal", "window", "focus", "select", "sessions", "loop".
    public var category: String
    public var message: String
    /// How many times it happened in a row with the same key; the message is the latest one's.
    public var repeats: Int
    /// When the first of those repeats happened; nil for a crumb that happened once.
    public var since: Date?

    public init(date: Date, category: String, message: String, repeats: Int = 1, since: Date? = nil) {
        self.date = date; self.category = category; self.message = message; self.repeats = repeats; self.since = since
    }
}

/// The newest `capacity` breadcrumbs, oldest first (ADR-231).
///
/// A crumb with a key folds into an earlier one with the same key among the last `foldWindow`, which moves to
/// the end and counts a repeat. A terminal title that changes ten times a second while a session works then
/// takes one slot rather than the whole trail, even when its progress reports land in between.
public struct BreadcrumbTrail: Sendable {
    public let capacity: Int
    public let foldWindow: Int
    private var crumbs: [Breadcrumb] = []
    private var keys: [String?] = []

    public init(capacity: Int = 300, foldWindow: Int = 8) {
        self.capacity = capacity; self.foldWindow = foldWindow
    }

    public var entries: [Breadcrumb] { crumbs }

    public mutating func add(_ category: String, _ message: String, key: String? = nil, at date: Date = Date()) {
        let fullKey = key.map { category + "\u{1F}" + $0 }
        if let fullKey, let i = keys.indices.suffix(foldWindow).last(where: { keys[$0] == fullKey }) {
            var folded = crumbs.remove(at: i)
            keys.remove(at: i)
            folded.since = folded.since ?? folded.date
            folded.date = date
            folded.message = message
            folded.repeats += 1
            crumbs.append(folded)
            keys.append(fullKey)
            return
        }
        if crumbs.count == capacity {
            crumbs.removeFirst()
            keys.removeFirst()
        }
        crumbs.append(Breadcrumb(date: date, category: category, message: message))
        keys.append(fullKey)
    }
}

/// A layout loop as the loop witness saw it (ADR-231): one window laid out pass after pass inside a single turn
/// of the main run loop. A display cycle that settles takes up to about 25 passes in one turn; the loop that ended
/// the app on 2026-10-24 ran about 550.
public struct LoopRecord: Codable, Sendable, Equatable {
    public struct Pass: Codable, Sendable, Equatable {
        /// The pass's number within the turn; the first recorded one comes just after the trip.
        public var index: Int
        /// Milliseconds since the trip.
        public var millis: Int
        /// The observed values written since the previous pass, by probe name ("tab.pwd").
        public var changed: [String]
        /// The Clinic views whose body or update ran since the previous pass, "RootToolbar×2".
        public var rendered: [String]
        public var firstResponder: String
        /// Each toolbar item, "identifier width", or "identifier hidden" when it went into the » menu.
        public var toolbar: [String]
        public var frame: String

        public init(index: Int, millis: Int, changed: [String], rendered: [String], firstResponder: String,
                    toolbar: [String], frame: String) {
            self.index = index; self.millis = millis; self.changed = changed; self.rendered = rendered
            self.firstResponder = firstResponder; self.toolbar = toolbar; self.frame = frame
        }
    }

    /// "main 4CA3E817" for a session window, else its class and title.
    public var window: String
    public var trippedAt: Date
    /// Passes in one turn that trip the witness.
    public var tripPasses: Int
    /// The most passes any window took in one turn this launch without tripping: what normal looks like.
    public var quietMax: Int
    /// Passes counted so far in the looping turn.
    public var passes: Int
    public var seconds: Double
    /// False while the loop runs; true once the run loop turned over, or with `survived` false when an
    /// exception was thrown during it.
    public var ended: Bool
    public var survived: Bool?
    /// How many passes each probe was written in, over the whole loop since the trip.
    public var changedTotals: [String: Int]
    /// How many times each Clinic view ran, over the whole loop since the trip.
    public var renderedTotals: [String: Int]
    /// The probes armed at the trip.
    public var probes: [String]
    /// The first passes after the trip, in full.
    public var recorded: [Pass]

    public init(window: String, trippedAt: Date, tripPasses: Int, quietMax: Int, probes: [String]) {
        self.window = window; self.trippedAt = trippedAt; self.tripPasses = tripPasses; self.quietMax = quietMax
        self.passes = tripPasses; self.seconds = 0; self.ended = false; self.survived = nil
        self.changedTotals = [:]; self.renderedTotals = [:]; self.probes = probes; self.recorded = []
    }
}

/// A layout loop's file in `diagnostics/` (ADR-231), written whether or not the app lived through it.
public struct LoopReport: Codable, Sendable, Equatable {
    public var date: Date
    public var appVersion: String
    public var osVersion: String
    public var loop: LoopRecord
    public var breadcrumbs: [Breadcrumb]
    public var workspace: WorkspaceDump?

    public init(date: Date, appVersion: String, osVersion: String, loop: LoopRecord, breadcrumbs: [Breadcrumb],
                workspace: WorkspaceDump? = nil) {
        self.date = date; self.appVersion = appVersion; self.osVersion = osVersion; self.loop = loop
        self.breadcrumbs = breadcrumbs; self.workspace = workspace
    }

    public func encoded() throws -> Data { try DiagnosticsArchive.encoder.encode(self) }
}
