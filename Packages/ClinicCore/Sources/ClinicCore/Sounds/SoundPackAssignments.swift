import Foundation

/// Which sound pack each project and session speaks with (ADR-201), kept in `state.json` beside the
/// other per-project choices. The rotation and the default are preferences (`SoundSettings`).
public struct SoundPackAssignments: Codable, Sendable, Equatable {
    /// A project's own voice, by project path.
    public var byProject: [String: String] = [:]
    /// A pack the user chose for one session. It outranks everything, and a child inherits it.
    public var bySession: [SessionID: String] = [:]
    /// The pack a session drew from the rotation, kept for its life, resumes included.
    public var drawn: [SessionID: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        byProject = (try? c.decodeIfPresent([String: String].self, forKey: .byProject)) ?? [:]
        bySession = (try? c.decodeIfPresent([SessionID: String].self, forKey: .bySession)) ?? [:]
        drawn = (try? c.decodeIfPresent([SessionID: String].self, forKey: .drawn)) ?? [:]
    }

    /// Where a session's pack came from, for saying so in menus and on the pack's page.
    public enum Source: Sendable, Equatable {
        case session
        case parent(SessionID)
        case project(String)
        case rotation
        case defaultPack
    }

    public struct Choice: Sendable, Equatable {
        public var pack: String
        public var source: Source
    }

    public enum Resolution: Sendable, Equatable {
        case choice(Choice)
        /// The rotation applies, but this session (or the ancestor it inherits from) has not drawn
        /// from it yet, or its draw has left the rotation. The caller draws and records it.
        case draw(for: SessionID)
        case none
    }

    /// The pack a session speaks with: its own, then its parent's (however far up), then its
    /// project's, then the one it drew from the rotation, then the default (ADR-199, ADR-201).
    /// Only installed packs count: one that has been removed falls through to the next.
    public func resolve(_ session: SessionID?, project: String?, parent: (SessionID) -> SessionID?,
                        projectOf: (SessionID) -> String?, rotation: [String], defaultPack: String?,
                        installed: Set<String>) -> Resolution {
        if let session {
            if let own = bySession[session], installed.contains(own) { return .choice(Choice(pack: own, source: .session)) }
            // The nearest ancestor's own choice, else whatever the root of the family speaks with.
            // The depth bound guards a cycle.
            var ancestor = session
            for _ in 0..<32 {
                guard let up = parent(ancestor), up != ancestor else { break }
                ancestor = up
                if let own = bySession[ancestor], installed.contains(own) {
                    return .choice(Choice(pack: own, source: .parent(ancestor)))
                }
            }
            if ancestor != session {
                switch resolve(ancestor, project: projectOf(ancestor), parent: { _ in nil }, projectOf: projectOf,
                               rotation: rotation, defaultPack: defaultPack, installed: installed) {
                case .choice(let c): return .choice(Choice(pack: c.pack, source: .parent(ancestor)))
                case .draw(let who): return .draw(for: who)
                case .none: return .none
                }
            }
        }
        if let project, let own = byProject[project], installed.contains(own) {
            return .choice(Choice(pack: own, source: .project(project)))
        }
        let playable = rotation.filter(installed.contains)
        if !playable.isEmpty, let session {
            if let pick = drawn[session], playable.contains(pick) { return .choice(Choice(pack: pick, source: .rotation)) }
            return .draw(for: session)
        }
        if let defaultPack, installed.contains(defaultPack) { return .choice(Choice(pack: defaultPack, source: .defaultPack)) }
        return .none
    }

    /// The rotation pack the fewest live sessions are already speaking with, so sessions running side by
    /// side sound different; a tie is broken at random.
    public static func draw<R: RandomNumberGenerator>(rotation: [String], installed: Set<String>, inUse: [String],
                                                      using random: inout R) -> String? {
        let playable = rotation.filter(installed.contains)
        guard !playable.isEmpty else { return nil }
        let uses = Dictionary(inUse.map { ($0, 1) }, uniquingKeysWith: +)
        let fewest = playable.map { uses[$0, default: 0] }.min() ?? 0
        return playable.filter { uses[$0, default: 0] == fewest }.randomElement(using: &random)
    }

    public static func draw(rotation: [String], installed: Set<String>, inUse: [String]) -> String? {
        var random = SystemRandomNumberGenerator()
        return draw(rotation: rotation, installed: installed, inUse: inUse, using: &random)
    }

    /// Forgets draws for sessions that no longer exist, once there are enough to be worth it.
    public mutating func pruneDraws(keeping live: Set<SessionID>, above limit: Int = 400) {
        guard drawn.count > limit else { return }
        drawn = drawn.filter { live.contains($0.key) }
    }
}
