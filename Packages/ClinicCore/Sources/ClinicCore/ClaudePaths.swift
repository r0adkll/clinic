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
