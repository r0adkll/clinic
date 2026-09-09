import Foundation

/// Locations of Claude Code data. Read-only for Clinic (ADR-018).
public struct ClaudePaths: Sendable {
    public let configDirectory: URL

    /// `.claude.json` — the file holding `mcpServers`, `projects` and the rest of Claude Code's
    /// non-settings state.
    ///
    /// It does **not** sit in a fixed place relative to `configDirectory`. By default it is the
    /// *sibling* of `~/.claude` (`~/.claude.json`), but when `CLAUDE_CONFIG_DIR` is set the CLI
    /// writes it *inside* that directory — verified by watching `claude mcp add` report
    /// `File modified: $CLAUDE_CONFIG_DIR/.claude.json` (ADR-093). ADR-060 assumed the sibling
    /// form in both cases, so every smoke instance was reading the real `~/.claude.json`.
    public let configFile: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            configDirectory = URL(fileURLWithPath: dir, isDirectory: true)
            configFile = configDirectory.appendingPathComponent(".claude.json")
        } else {
            configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
            configFile = home.appendingPathComponent(".claude.json")
        }
    }

    /// An explicit directory is treated as `CLAUDE_CONFIG_DIR` would be: the JSON lives inside it.
    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
        self.configFile = configDirectory.appendingPathComponent(".claude.json")
    }

    public var projectsDirectory: URL { configDirectory.appendingPathComponent("projects", isDirectory: true) }

    /// Claude Code's cwd encoding: every non-alphanumeric character becomes "-".
    public static func encodedProjectDirectoryName(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
}

/// Where Clinic keeps its own files (state, sockets, chats). `CLINIC_APP_SUPPORT` overrides the location so a
/// second instance (smoke tests, ADR-038) never binds the sockets of the one already running.
public enum ClinicPaths {
    public static var appSupport: URL {
        if let o = ProcessInfo.processInfo.environment["CLINIC_APP_SUPPORT"], !o.isEmpty { return URL(fileURLWithPath: o, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    /// `…/Application Support/Clinic`
    public static var directory: URL { appSupport.appendingPathComponent("Clinic", isDirectory: true) }

    /// True when this process is a **smoke instance** — one launched with `CLINIC_APP_SUPPORT` so it
    /// keeps its own state, sockets and chats away from the app the user is really using (ADR-038).
    ///
    /// Worth knowing what that variable does *not* isolate: `UserDefaults` is keyed by bundle id, so
    /// every preference — shortcut overrides, panel visibility, quit behaviour, the usage consent —
    /// is shared with the live app. A smoke run therefore inherits real consent it cannot honour and
    /// can write preferences the real app will obey. Anything that reaches outside Clinic's own
    /// container on the strength of a stored preference must check this first.
    public static var isSmokeInstance: Bool {
        !(ProcessInfo.processInfo.environment["CLINIC_APP_SUPPORT"] ?? "").isEmpty
    }
}
