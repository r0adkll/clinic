import Darwin
import Foundation

/// peon-ping, OpenPeon's reference player (ADR-203). It installs its hooks into `~/.claude/settings.json`,
/// so where it is installed it plays in Clinic's sessions as well, and every moment is heard twice. Clinic
/// cannot edit that file (ADR-018); it can notice, import peon-ping's settings, and, when asked, give its
/// own sessions a paused peon-ping (`CLAUDE_PEON_DIR`) so peon-ping keeps working everywhere else.
public enum PeonPing {
    /// Whether a Claude Code settings file registers peon-ping's hooks: any hook command naming it.
    public static func hooksInstalled(settingsJSON: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: settingsJSON) as? [String: Any],
              let hooks = object["hooks"] else { return false }
        func strings(_ value: Any) -> [String] {
            switch value {
            case let s as String: [s]
            case let a as [Any]: a.flatMap(strings)
            case let d as [String: Any]: d.values.flatMap(strings)
            default: []
            }
        }
        return strings(hooks).contains { $0.contains("peon-ping") || $0.contains("peon.sh") }
    }

    /// The parts of peon-ping's `config.json` Clinic has a place for.
    public struct Config: Sendable, Equatable {
        public struct Rule: Sendable, Equatable {
            public var pattern: String
            public var pack: String
        }

        public var enabled: Bool?
        public var volume: Double?
        public var defaultPack: String?
        public var categories: [String: Bool] = [:]
        public var pathRules: [Rule] = []
        public var rotation: [String] = []
        public var rotationMode: String?

        public init(json: Data) throws {
            guard let o = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            enabled = o["enabled"] as? Bool
            volume = (o["volume"] as? NSNumber)?.doubleValue
            // `active_pack` is what configs said before `default_pack`.
            defaultPack = (o["default_pack"] as? String) ?? (o["active_pack"] as? String)
            categories = (o["categories"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
            pathRules = (o["path_rules"] as? [[String: Any]] ?? []).compactMap { rule in
                guard let pattern = rule["pattern"] as? String, let pack = rule["pack"] as? String else { return nil }
                return Rule(pattern: pattern, pack: pack)
            }
            rotation = o["pack_rotation"] as? [String] ?? []
            rotationMode = o["pack_rotation_mode"] as? String
        }
    }

    /// What importing a config would change, worked out before anything is.
    public struct Import: Sendable, Equatable {
        public var defaultPack: String?
        public var volume: Double?
        public var disabledCategories: Set<CESPCategory> = []
        public var rotation: [String] = []
        /// Project path → pack, from path rules that matched a project Clinic knows.
        public var projectPacks: [String: String] = [:]
        /// Packs the config names that are not installed where Clinic can play them.
        public var missingPacks: [String] = []
        /// Path rules that matched no project.
        public var unmatchedRules: [String] = []

        public var isEmpty: Bool {
            defaultPack == nil && volume == nil && disabledCategories.isEmpty && rotation.isEmpty && projectPacks.isEmpty
        }
    }

    /// - Parameters:
    ///   - projects: the projects Clinic knows, by path.
    ///   - installed: packs Clinic can play, its own and those it found (peon-ping's own included).
    ///   - home: what `~` in a path rule means.
    public static func plan(_ config: Config, projects: [String], installed: Set<String>, home: String = NSHomeDirectory()) -> Import {
        var out = Import()
        var missing: [String] = []
        func usable(_ pack: String) -> Bool {
            if installed.contains(pack) { return true }
            if !missing.contains(pack) { missing.append(pack) }
            return false
        }
        if let pack = config.defaultPack, usable(pack) { out.defaultPack = pack }
        if let volume = config.volume { out.volume = min(1, max(0, volume)) }
        out.disabledCategories = Set(config.categories.filter { !$0.value }.compactMap { CESPCategory(rawValue: $0.key) })
        // `session_override` is peon-ping's per-session slash command, not a rotation.
        if config.rotationMode != "session_override" { out.rotation = config.rotation.filter(usable) }
        for rule in config.pathRules {
            let pattern = rule.pattern.hasPrefix("~") ? home + rule.pattern.dropFirst() : rule.pattern
            let matched = projects.filter { matches(pattern, $0) }
            if matched.isEmpty { out.unmatchedRules.append(rule.pattern); continue }
            guard usable(rule.pack) else { continue }
            // The first rule to match a project wins, as it does in peon-ping.
            for project in matched where out.projectPacks[project] == nil { out.projectPacks[project] = rule.pack }
        }
        out.missingPacks = missing
        return out
    }

    /// peon-ping's glob: `*` and `?`, where `*` crosses `/` as Python's `fnmatch` does.
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        fnmatch(pattern, path, 0) == 0
    }

    /// Where peon-ping keeps `config.json`, in the order it looks (`peon.sh`): its hooks folder, then
    /// the folder CESP players share.
    public static func configCandidates(claudeDirectory: URL, home: URL) -> [URL] {
        [claudeDirectory.appendingPathComponent("hooks/peon-ping/config.json"),
         home.appendingPathComponent(".openpeon/config.json")]
    }

    /// A folder peon-ping takes for its own when `CLAUDE_PEON_DIR` names it: a `packs` folder so it does
    /// not look elsewhere, `.paused` so it plays nothing, and a config that says so twice. Read from
    /// `peon.sh`; written once and left alone.
    public static func prepareQuietDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("packs", isDirectory: true), withIntermediateDirectories: true)
        let paused = directory.appendingPathComponent(".paused")
        if !fm.fileExists(atPath: paused.path) { try Data().write(to: paused) }
        let config = directory.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: config.path) {
            try Data(#"{"enabled": false, "desktop_notifications": false}"#.utf8).write(to: config)
        }
    }
}
