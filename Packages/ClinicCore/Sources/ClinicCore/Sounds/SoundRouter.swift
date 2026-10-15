import Foundation

/// Something Clinic saw that a pack can voice (ADR-199). Each maps onto one CESP category, and each
/// can be switched off on its own in the Sounds screen's Events table.
public enum SoundWitness: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    // Claude Code's hooks
    case sessionStarted, promptSubmitted, rapidPrompts, turnFinished, turnFailed, rateLimited, permissionNeeded, inputNeeded, sessionEnded
    // Clinic's own
    case runSucceeded, runFailed, checksPassed, checksFailed, childReported, agentAsked
    // Clinic's scheduled sessions (ADR-204)
    case automationFinished, automationFailed
    // Clinic's own, read off the status line and the clock (ADR-203)
    case contextFilling, planNearlySpent, turnLong

    public var id: String { rawValue }

    public var category: CESPCategory {
        switch self {
        case .sessionStarted: .sessionStart
        case .promptSubmitted: .taskAcknowledge
        case .rapidPrompts: .userSpam
        case .turnFinished, .runSucceeded, .checksPassed, .childReported, .automationFinished: .taskComplete
        case .turnFailed, .runFailed, .checksFailed, .automationFailed: .taskError
        case .permissionNeeded, .inputNeeded, .agentAsked: .inputRequired
        case .sessionEnded: .sessionEnd
        case .rateLimited, .contextFilling, .planNearlySpent: .resourceLimit
        case .turnLong: .taskProgress
        }
    }

    /// Off until the user turns it on (ADR-203): a line every ten minutes of a long turn is more than
    /// most people want, and the setting has to stay off for settings saved before it existed.
    public var isOptIn: Bool { self == .turnLong }

    /// True for a witness Claude Code's hooks report; false for one only Clinic sees.
    public var isHook: Bool {
        switch self {
        case .sessionStarted, .promptSubmitted, .rapidPrompts, .turnFinished, .turnFailed, .rateLimited, .permissionNeeded, .inputNeeded, .sessionEnded: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .sessionStarted: "A session starts or resumes"
        case .promptSubmitted: "You send a prompt"
        case .rapidPrompts: "Three prompts in ten seconds"
        case .turnFinished: "A turn finishes"
        case .turnFailed: "A turn ends with an API error"
        case .rateLimited: "A turn is stopped by a rate or usage limit"
        case .permissionNeeded: "A tool needs permission"
        case .inputNeeded: "Claude is waiting for you"
        case .sessionEnded: "A session ends"
        case .runSucceeded: "A run finishes"
        case .runFailed: "A run fails"
        case .checksPassed: "A watched pull request's checks pass"
        case .checksFailed: "A watched pull request's checks fail"
        case .childReported: "A child session reports back"
        case .agentAsked: "An agent asks for you or posts a Grill round"
        case .automationFinished: "A scheduled automation finishes"
        case .automationFailed: "A scheduled automation fails, or gives up waiting"
        case .contextFilling: "A session's context passes 90%"
        case .planNearlySpent: "The plan's five-hour window passes 90%"
        case .turnLong: "A turn is still running after ten minutes"
        }
    }
}

/// What the user chose on the Sounds screen. Stored as one JSON value in `UserDefaults`.
public struct SoundSettings: Codable, Sendable, Hashable {
    public static let defaultsKey = "ClinicSoundPacks"

    /// The master switch. Off, every moment falls back to ADR-097's notification sound.
    public var enabled = true
    /// Pack lines are paused until then, from the toolbar (ADR-208). Like the switch being off, every
    /// moment makes ADR-097's notification sound meanwhile. Kept across launches; a date gone by means
    /// nothing.
    public var pausedUntil: Date?
    /// CESP's master volume, 0–1.
    public var volume = 0.5
    /// The pack every session uses until a project or session names another.
    public var defaultPack: String?
    /// Packs a session with no pack of its own or its project's draws one from, and keeps (ADR-201).
    /// Empty: every such session speaks with the default.
    public var rotation: [String] = []
    public var disabledCategories: Set<CESPCategory> = []
    public var disabledWitnesses: Set<SoundWitness> = []
    /// Opt-in witnesses the user has turned on (ADR-203). Everything else is on unless disabled.
    public var enabledOptIns: Set<SoundWitness> = []
    /// Stay quiet for the tab the user is looking at.
    public var quietOnScreen = false
    /// Give Clinic's sessions a paused peon-ping of their own, so it does not play over Clinic (ADR-203).
    public var quietPeonPing = false

    public init() {}

    /// Whether pack lines are paused at `now`.
    public func isPaused(at now: Date = Date()) -> Bool {
        pausedUntil.map { now < $0 } ?? false
    }

    /// Whether packs speak at all at `now`: switched on and not paused.
    public func speaks(at now: Date = Date()) -> Bool { enabled && !isPaused(at: now) }

    public func isOn(_ witness: SoundWitness, at now: Date = Date()) -> Bool {
        guard speaks(at: now), !disabledCategories.contains(witness.category) else { return false }
        return witness.isOptIn ? enabledOptIns.contains(witness) : !disabledWitnesses.contains(witness)
    }

    /// The switch in the Events table, whichever way a witness defaults.
    public mutating func set(_ witness: SoundWitness, on: Bool) {
        if witness.isOptIn {
            if on { enabledOptIns.insert(witness) } else { enabledOptIns.remove(witness) }
        } else {
            if on { disabledWitnesses.remove(witness) } else { disabledWitnesses.insert(witness) }
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, pausedUntil, volume, defaultPack, rotation, disabledCategories, disabledWitnesses, enabledOptIns, quietOnScreen, quietPeonPing
    }

    /// Unknown categories or witnesses (from a newer build) are dropped, not fatal.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        pausedUntil = try? c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        volume = min(1, max(0, (try? c.decode(Double.self, forKey: .volume)) ?? 0.5))
        defaultPack = try? c.decodeIfPresent(String.self, forKey: .defaultPack)
        rotation = (try? c.decodeIfPresent([String].self, forKey: .rotation)) ?? []
        disabledCategories = Set(((try? c.decode([String].self, forKey: .disabledCategories)) ?? []).compactMap(CESPCategory.init(rawValue:)))
        disabledWitnesses = Set(((try? c.decode([String].self, forKey: .disabledWitnesses)) ?? []).compactMap(SoundWitness.init(rawValue:)))
        enabledOptIns = Set(((try? c.decode([String].self, forKey: .enabledOptIns)) ?? []).compactMap(SoundWitness.init(rawValue:)))
        quietOnScreen = (try? c.decode(Bool.self, forKey: .quietOnScreen)) ?? false
        quietPeonPing = (try? c.decode(Bool.self, forKey: .quietPeonPing)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(pausedUntil, forKey: .pausedUntil)
        try c.encode(volume, forKey: .volume)
        try c.encodeIfPresent(defaultPack, forKey: .defaultPack)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(disabledCategories.map(\.rawValue).sorted(), forKey: .disabledCategories)
        try c.encode(disabledWitnesses.map(\.rawValue).sorted(), forKey: .disabledWitnesses)
        try c.encode(enabledOptIns.map(\.rawValue).sorted(), forKey: .enabledOptIns)
        try c.encode(quietOnScreen, forKey: .quietOnScreen)
        try c.encode(quietPeonPing, forKey: .quietPeonPing)
    }

    public init(json: Data?) {
        guard let json, let decoded = try? JSONDecoder().decode(SoundSettings.self, from: json) else { self.init(); return }
        self = decoded
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// How long the toolbar's pause lasts (ADR-208).
public enum SoundPause: String, CaseIterable, Sendable {
    case thirtyMinutes, oneHour, untilMorning

    public var title: String {
        switch self {
        case .thirtyMinutes: "Pause for 30 Minutes"
        case .oneHour: "Pause for 1 Hour"
        case .untilMorning: "Pause Until Morning"
        }
    }

    /// When a pause chosen at `now` ends. Morning is the next 8:00, so a pause chosen at 2 a.m. ends
    /// that same morning rather than the one after.
    public func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .untilMorning:
            return calendar.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, second: 0), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(12 * 60 * 60)
        }
    }
}

/// Decides whether a witness makes a sound, and which line (ADR-199).
///
/// Everything here is time and memory, no speaker, so the spec's rules — random line without an
/// immediate repeat, 500 ms per category — and Clinic's own — the spam count, the launch cooldown and
/// one line at a time — are unit-tested directly.
public struct SoundRouter: Sendable {
    public static let categoryDebounce: TimeInterval = 0.5
    public static let sessionStartCooldown: TimeInterval = 30
    public static let spamCount = 3
    public static let spamWindow: TimeInterval = 10

    /// What a moment should sound like.
    public enum Decision: Sendable, Hashable {
        /// Play this line. `interrupting` says a lower-ranked line is playing and should stop for it.
        case play(Cue)
        /// A pack voice already covers this moment (or is meant to stay quiet for it): make no other noise.
        case hold
        /// The pack has nothing to say: whatever sounded before packs existed should sound now.
        case pass
    }

    public struct Cue: Sendable, Hashable {
        public var category: CESPCategory
        public var line: CESPManifest.Line
        public var interrupting: Bool
    }

    private var lastPlayed: [CESPCategory: Date] = [:]
    private var lastLine: [String: String] = [:]
    private var prompts: [String: [Date]] = [:]
    private var lastSessionStart: Date?

    public init() {}

    /// - Parameters:
    ///   - session: who it is about, for counting rapid prompts. Nil for a moment that belongs to no session.
    ///   - manifest: the pack this session speaks with, or nil when it has none.
    ///   - onScreen: the moment belongs to the tab the user is looking at.
    ///   - playing: the category of the line still playing, if any.
    public mutating func decide<R: RandomNumberGenerator>(
        _ witness: SoundWitness, session: String?, manifest: CESPManifest?, settings: SoundSettings,
        onScreen: Bool = false, playing: CESPCategory? = nil, now: Date = Date(), using random: inout R
    ) -> Decision {
        var witness = witness
        if witness == .promptSubmitted, let session {
            let recent = (prompts[session] ?? []).filter { now.timeIntervalSince($0) < Self.spamWindow } + [now]
            prompts[session] = recent
            if recent.count >= Self.spamCount, settings.isOn(.rapidPrompts, at: now),
               manifest.map({ !$0.lines(for: .userSpam).isEmpty }) == true {
                witness = .rapidPrompts
                prompts[session] = []
            }
        }
        guard settings.isOn(witness, at: now), let manifest else { return .pass }
        let category = witness.category
        let lines = manifest.lines(for: category)
        guard !lines.isEmpty else { return .pass }
        if settings.quietOnScreen && onScreen { return .hold }
        if let last = lastPlayed[category], now.timeIntervalSince(last) < Self.categoryDebounce { return .hold }
        if category == .sessionStart, let last = lastSessionStart, now.timeIntervalSince(last) < Self.sessionStartCooldown { return .hold }
        var interrupting = false
        if let playing {
            guard category.rank < playing.rank else { return .hold }
            interrupting = true
        }

        let key = manifest.name + "/" + category.rawValue
        let candidates = lines.count > 1 ? lines.filter { $0.path != lastLine[key] } : lines
        let line = candidates.randomElement(using: &random) ?? lines[0]
        lastLine[key] = line.path
        lastPlayed[category] = now
        if category == .sessionStart { lastSessionStart = now }
        return .play(Cue(category: category, line: line, interrupting: interrupting))
    }

    public mutating func decide(_ witness: SoundWitness, session: String?, manifest: CESPManifest?, settings: SoundSettings,
                                onScreen: Bool = false, playing: CESPCategory? = nil, now: Date = Date()) -> Decision {
        var random = SystemRandomNumberGenerator()
        return decide(witness, session: session, manifest: manifest, settings: settings, onScreen: onScreen,
                      playing: playing, now: now, using: &random)
    }

    /// A session that has gone is forgotten, so its prompt count cannot leak into a later one.
    public mutating func forget(session: String) { prompts[session] = nil }
}
