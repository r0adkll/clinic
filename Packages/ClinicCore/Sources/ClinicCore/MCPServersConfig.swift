import Foundation

/// Read-only view of MCP servers Claude Code knows about (ADR-060): `~/.claude.json` global + per-project, and project `.mcp.json` files.
public struct MCPServerEntry: Sendable, Hashable, Identifiable {
    public enum Scope: Sendable, Hashable { case global, project(String), projectFile(String) }
    public var name: String
    public var scope: Scope
    public var transport: String        // stdio | http | sse | unknown
    public var command: String?
    public var args: [String]
    public var url: String?
    public var envKeys: [String]
    public var enabled: Bool?           // from enabled/disabledMcpjsonServers for .mcp.json entries; nil when not governed
    public var id: String { "\(scope)|\(name)" }

    public init(name: String, scope: Scope, transport: String, command: String? = nil, args: [String] = [], url: String? = nil, envKeys: [String] = [], enabled: Bool? = nil) {
        self.name = name; self.scope = scope; self.transport = transport; self.command = command; self.args = args; self.url = url; self.envKeys = envKeys; self.enabled = enabled
    }

    public var summary: String {
        if let url { return Self.redact(url) }
        return Self.redact(([command ?? ""] + args).joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    /// Masks bearer tokens, `key=value` secrets and `sk-…`-style keys so a config with credentials is safe to display.
    public static func redact(_ text: String) -> String {
        var out = text
        let patterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9._\-]{8,}"#,
            #"(?i)((?:token|key|secret|password|api[_-]?key)=)[^\s]+"#,
            #"\b(sk-[A-Za-z0-9_\-]{4})[A-Za-z0-9_\-]{8,}"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1••••••")
        }
        return out
    }
}

public enum MCPServersConfig {
    public static func configFileURL(paths: ClaudePaths = ClaudePaths()) -> URL {
        // ~/.claude.json sits beside the config directory, not inside it.
        paths.configDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json")
    }

    public static func load(paths: ClaudePaths = ClaudePaths(), fileManager: FileManager = .default) -> [MCPServerEntry] {
        guard let data = try? Data(contentsOf: configFileURL(paths: paths)) else { return [] }
        var entries = parse(data)
        let projectPaths = Set(entries.compactMap { e -> String? in if case .project(let p) = e.scope { return p } else { return nil } })
        for path in projectPaths.union(projectPathsIn(data)) {
            let url = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
            guard let d = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let governed = governance(for: path, in: data)
            for e in servers(from: root["mcpServers"], scope: .projectFile(path)) {
                var e = e
                if governed.enabled.contains(e.name) { e.enabled = true } else if governed.disabled.contains(e.name) { e.enabled = false }
                entries.append(e)
            }
        }
        return entries
    }

    /// Parses `~/.claude.json` contents.
    public static func parse(_ data: Data) -> [MCPServerEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out = servers(from: root["mcpServers"], scope: .global)
        for (path, value) in (root["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let project = value as? [String: Any] else { continue }
            out += servers(from: project["mcpServers"], scope: .project(path))
        }
        return out
    }

    static func projectPathsIn(_ data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let projects = root["projects"] as? [String: Any] else { return [] }
        return Set(projects.keys)
    }

    static func governance(for path: String, in data: Data) -> (enabled: Set<String>, disabled: Set<String>) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = (root["projects"] as? [String: Any])?[path] as? [String: Any] else { return ([], []) }
        return (Set(project["enabledMcpjsonServers"] as? [String] ?? []), Set(project["disabledMcpjsonServers"] as? [String] ?? []))
    }

    static func servers(from value: Any?, scope: MCPServerEntry.Scope) -> [MCPServerEntry] {
        guard let dict = value as? [String: Any] else { return [] }
        return dict.keys.sorted().compactMap { name in
            guard let s = dict[name] as? [String: Any] else { return nil }
            let url = s["url"] as? String
            let type = (s["type"] as? String)?.lowercased()
            let transport = type ?? (url != nil ? "http" : "stdio")
            return MCPServerEntry(name: name, scope: scope, transport: transport, command: s["command"] as? String, args: s["args"] as? [String] ?? [],
                                  url: url, envKeys: (s["env"] as? [String: Any]).map { $0.keys.sorted() } ?? [])
        }
    }
}
