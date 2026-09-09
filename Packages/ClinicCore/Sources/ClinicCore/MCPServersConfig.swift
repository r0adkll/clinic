import Foundation

/// The three scopes `claude mcp` writes to, named as the CLI names them (ADR-093).
///
/// Two of the three are "local" in plain English, which is exactly why the labels below spell out
/// the difference rather than trusting the word: `local` is one project and private to you, `project`
/// is one project and committed for your team.
public enum MCPScope: String, Sendable, Hashable, CaseIterable, Codable {
    /// `~/.claude.json` → `mcpServers`. Every project.
    case user
    /// `~/.claude.json` → `projects[path].mcpServers`. One project, only you. **The CLI's default.**
    case local
    /// `.mcp.json` at the project root. One project, committed, shared.
    case project

    public var label: String {
        switch self {
        case .user: "All projects"
        case .local: "This project · private"
        case .project: "This project · shared"
        }
    }

    /// The one-line explanation shown beside the picker, so nobody has to guess which "local" this is.
    public var detail: String {
        switch self {
        case .user: "Available in every project. Stored in ~/.claude.json."
        case .local: "Only this project, and only for you. Stored in ~/.claude.json."
        case .project: "Only this project, committed to .mcp.json and shared with anyone who clones it."
        }
    }

    public var isProjectScoped: Bool { self != .user }
}

/// Whether a `.mcp.json` server has been approved for a project.
///
/// Claude Code asks once, in a session, and records the answer in the project's
/// `enabledMcpjsonServers` / `disabledMcpjsonServers`. There is no CLI command to set it, so Clinic
/// reports it and never pretends to change it (ADR-093).
public enum MCPApproval: String, Sendable, Hashable {
    case approved, disabled, pending

    public var label: String {
        switch self {
        case .approved: "Approved"
        case .disabled: "Disabled"
        case .pending: "Pending approval"
        }
    }
}

/// One configured MCP server, as shown in the UI.
///
/// Deliberately carries **no secret values** — only the *names* of env vars and headers. The values
/// stay in the file; the edit path re-reads them from disk at the moment it needs them
/// (`MCPServersConfig.definition(for:)`) rather than parking them in an observable model.
public struct MCPServerEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var scope: MCPScope
    /// nil for `.user`.
    public var projectPath: String?
    public var transport: String        // stdio | http | sse
    public var command: String?
    public var args: [String]
    public var url: String?
    public var envKeys: [String]
    public var headerKeys: [String]
    /// Only meaningful for `.project`; nil elsewhere.
    public var approval: MCPApproval?

    public var id: String { "\(scope.rawValue)|\(projectPath ?? "")|\(name)" }

    public init(name: String, scope: MCPScope, projectPath: String? = nil, transport: String,
                command: String? = nil, args: [String] = [], url: String? = nil,
                envKeys: [String] = [], headerKeys: [String] = [], approval: MCPApproval? = nil) {
        self.name = name; self.scope = scope; self.projectPath = projectPath; self.transport = transport
        self.command = command; self.args = args; self.url = url
        self.envKeys = envKeys; self.headerKeys = headerKeys; self.approval = approval
    }

    public var summary: String {
        if let url { return Self.redact(url) }
        return Self.redact(([command ?? ""] + args).joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(q) || summary.localizedCaseInsensitiveContains(q)
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

/// A server's full definition, values included. Read on demand, held briefly, never put on screen.
///
/// This is what `claude mcp add-json` consumes and what the edit path snapshots so a failed re-add
/// can be rolled back (ADR-093).
public struct MCPServerDefinition: Sendable, Hashable, Codable {
    public var type: String
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var headers: [String: String]

    public init(type: String, command: String? = nil, args: [String] = [], env: [String: String] = [:],
                url: String? = nil, headers: [String: String] = [:]) {
        self.type = type; self.command = command; self.args = args; self.env = env
        self.url = url; self.headers = headers
    }

    public var isStdio: Bool { type == "stdio" }

    /// Claude Code's own on-disk shape, which is also what `add-json` accepts. Keys are sorted so the
    /// string is stable enough to compare in a test.
    public var json: String {
        var o: [String: Any] = ["type": type]
        if isStdio {
            if let command { o["command"] = command }
            if !args.isEmpty { o["args"] = args }
            if !env.isEmpty { o["env"] = env }
        } else {
            if let url { o["url"] = url }
            if !headers.isEmpty { o["headers"] = headers }
        }
        // `withoutEscapingSlashes` because this string is shown to the user: `https:\/\/…` is valid
        // JSON but reads as a typo in the command preview.
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The same JSON with every value masked — for the command preview (ADR-093).
    public var redactedJSON: String {
        var copy = self
        copy.env = env.mapValues { _ in "••••••" }
        copy.headers = headers.mapValues { _ in "••••••" }
        return copy.json
    }

    static func parse(_ value: Any?) -> MCPServerDefinition? {
        guard let s = value as? [String: Any] else { return nil }
        let url = s["url"] as? String
        let type = (s["type"] as? String)?.lowercased() ?? (url != nil ? "http" : "stdio")
        return MCPServerDefinition(
            type: type,
            command: s["command"] as? String,
            args: (s["args"] as? [Any])?.compactMap { $0 as? String } ?? [],
            env: (s["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:],
            url: url,
            headers: (s["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:])
    }
}

/// A name/definition pair lifted out of a pasted JSON snippet.
public struct MCPSnippet: Sendable, Hashable, Identifiable {
    public var name: String
    public var definition: MCPServerDefinition
    public var id: String { name }
}

public enum MCPServersConfig {
    public static func configFileURL(paths: ClaudePaths = ClaudePaths()) -> URL { paths.configFile }

    public static func projectFileURL(for projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json")
    }

    /// The file a given entry actually lives in — what the detail pane's Reveal button opens.
    public static func fileURL(for entry: MCPServerEntry, paths: ClaudePaths = ClaudePaths()) -> URL {
        if entry.scope == .project, let p = entry.projectPath { return projectFileURL(for: p) }
        return paths.configFile
    }

    // MARK: Reading

    /// Every server Claude Code knows about, across every project. Sorted by scope, then project, then name.
    public static func load(paths: ClaudePaths = ClaudePaths()) -> [MCPServerEntry] {
        guard let data = try? Data(contentsOf: paths.configFile) else { return [] }
        var entries = parse(data)
        for path in projectPathsIn(data).sorted() {
            entries += loadProjectFile(projectPath: path, governance: governance(for: path, in: data))
        }
        return entries
    }

    /// Global + one project's two scopes — what the screen shows before "Show all projects" (ADR-093).
    public static func load(projectPath: String?, paths: ClaudePaths = ClaudePaths()) -> [MCPServerEntry] {
        guard let data = try? Data(contentsOf: paths.configFile) else { return [] }
        var entries = servers(from: root(data)?["mcpServers"], scope: .user, projectPath: nil)
        if let projectPath {
            entries += servers(from: project(projectPath, in: data)?["mcpServers"], scope: .local, projectPath: projectPath)
            entries += loadProjectFile(projectPath: projectPath, governance: governance(for: projectPath, in: data))
        }
        return entries
    }

    /// A single server's full definition, read fresh from disk. The only path that touches secret values.
    public static func definition(name: String, scope: MCPScope, projectPath: String?,
                                  paths: ClaudePaths = ClaudePaths()) -> MCPServerDefinition? {
        switch scope {
        case .user:
            guard let d = try? Data(contentsOf: paths.configFile) else { return nil }
            return MCPServerDefinition.parse((root(d)?["mcpServers"] as? [String: Any])?[name])
        case .local:
            guard let projectPath, let d = try? Data(contentsOf: paths.configFile) else { return nil }
            return MCPServerDefinition.parse((project(projectPath, in: d)?["mcpServers"] as? [String: Any])?[name])
        case .project:
            guard let projectPath, let d = try? Data(contentsOf: projectFileURL(for: projectPath)),
                  let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return MCPServerDefinition.parse((r["mcpServers"] as? [String: Any])?[name])
        }
    }

    /// Parses `~/.claude.json` contents: the global block plus every project's `local` scope.
    public static func parse(_ data: Data) -> [MCPServerEntry] {
        guard let root = root(data) else { return [] }
        var out = servers(from: root["mcpServers"], scope: .user, projectPath: nil)
        for (path, value) in (root["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let project = value as? [String: Any] else { continue }
            out += servers(from: project["mcpServers"], scope: .local, projectPath: path)
        }
        return out
    }

    static func loadProjectFile(projectPath: String, governance g: (enabled: Set<String>, disabled: Set<String>)) -> [MCPServerEntry] {
        guard let d = try? Data(contentsOf: projectFileURL(for: projectPath)),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return servers(from: r["mcpServers"], scope: .project, projectPath: projectPath).map {
            var e = $0
            e.approval = g.enabled.contains(e.name) ? .approved : (g.disabled.contains(e.name) ? .disabled : .pending)
            return e
        }
    }

    static func root(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func project(_ path: String, in data: Data) -> [String: Any]? {
        (root(data)?["projects"] as? [String: Any])?[path] as? [String: Any]
    }

    static func projectPathsIn(_ data: Data) -> Set<String> {
        Set((root(data)?["projects"] as? [String: Any] ?? [:]).keys)
    }

    static func governance(for path: String, in data: Data) -> (enabled: Set<String>, disabled: Set<String>) {
        guard let p = project(path, in: data) else { return ([], []) }
        return (Set(p["enabledMcpjsonServers"] as? [String] ?? []), Set(p["disabledMcpjsonServers"] as? [String] ?? []))
    }

    static func servers(from value: Any?, scope: MCPScope, projectPath: String?) -> [MCPServerEntry] {
        guard let dict = value as? [String: Any] else { return [] }
        return dict.keys.sorted().compactMap { name in
            guard let d = MCPServerDefinition.parse(dict[name]) else { return nil }
            return MCPServerEntry(name: name, scope: scope, projectPath: projectPath, transport: d.type,
                                  command: d.command, args: d.args, url: d.url,
                                  envKeys: d.env.keys.sorted(), headerKeys: d.headers.keys.sorted())
        }
    }

    // MARK: Pasted snippets

    /// Lifts servers out of whatever an MCP server's README told you to paste (ADR-093).
    ///
    /// Three shapes are accepted, because all three appear in the wild:
    /// - the documented wrapper, `{"mcpServers": {"name": {…}}}`
    /// - a name→definition map with no wrapper, `{"name": {"command": …}}`
    /// - a bare definition, `{"command": …, "args": […]}`, which has no name to lift and yields `""`
    ///
    /// Returns an empty array for anything that is not JSON or holds no recognisable server.
    public static func parseSnippet(_ text: String) -> [MCPSnippet] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        if let wrapped = root["mcpServers"] as? [String: Any] { return snippets(from: wrapped) }
        // A bare definition is recognisable by its own keys; check that before treating the object
        // as a name→definition map, or `{"command": {…}}` would be read as a server named "command".
        if root["command"] != nil || root["url"] != nil {
            guard let d = MCPServerDefinition.parse(root) else { return [] }
            return [MCPSnippet(name: "", definition: d)]
        }
        return snippets(from: root)
    }

    private static func snippets(from dict: [String: Any]) -> [MCPSnippet] {
        dict.keys.sorted().compactMap { name in
            guard let body = dict[name] as? [String: Any], body["command"] != nil || body["url"] != nil,
                  let d = MCPServerDefinition.parse(body) else { return nil }
            return MCPSnippet(name: name, definition: d)
        }
    }

    /// Claude Code rejects names with whitespace and treats them as argv, so they are checked up front.
    public static func isValidName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= 64, !n.hasPrefix("-") else { return false }
        return n.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }
}
