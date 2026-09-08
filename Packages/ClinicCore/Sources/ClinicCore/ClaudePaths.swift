import Foundation

/// Locations of Claude Code data. Read-only for Clinic (ADR-018).
public struct ClaudePaths: Sendable {
    public let configDirectory: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            configDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        }
    }

    public init(configDirectory: URL) { self.configDirectory = configDirectory }

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
}
