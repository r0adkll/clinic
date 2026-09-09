import Foundation

/// A marketplace Claude Code knows about (ADR-084): one entry of `claude plugin marketplace list --json`,
/// enriched from `~/.claude/plugins/known_marketplaces.json`.
public struct MarketplaceRef: Sendable, Hashable, Identifiable {
    public var name: String
    /// `github`, `git`, `url`, `local`… as the CLI reports it.
    public var sourceKind: String
    /// `owner/repo`, a URL, or a path — whichever the source carries.
    public var origin: String
    public var installLocation: String?
    public var lastUpdated: Date?
    public var id: String { name }

    public init(name: String, sourceKind: String, origin: String, installLocation: String? = nil, lastUpdated: Date? = nil) {
        self.name = name; self.sourceKind = sourceKind; self.origin = origin
        self.installLocation = installLocation; self.lastUpdated = lastUpdated
    }

    /// What `claude plugin marketplace add` was, or would have been, given.
    public var addArgument: String { origin.isEmpty ? name : origin }

    public var homepageURL: URL? {
        if origin.hasPrefix("http") { return URL(string: origin) }
        if sourceKind == "github", origin.contains("/") { return URL(string: "https://github.com/\(origin)") }
        return nil
    }
}

/// What a plugin is made of, from `plugin-catalog-cache.json`.
public struct PluginComponents: Sendable, Hashable {
    public var skills: [String] = []
    public var agents: [String] = []
    public var commands: [String] = []
    public var hooks: [String] = []
    public var mcpServers: [String] = []
    public var lspServers: [String] = []

    public init() {}

    public var isEmpty: Bool {
        skills.isEmpty && agents.isEmpty && commands.isEmpty && hooks.isEmpty && mcpServers.isEmpty && lspServers.isEmpty
    }

    /// `[("Skills", [...]), ("Agents", [...])]` — only the kinds this plugin actually has.
    public var groups: [(label: String, names: [String])] {
        [("Skills", skills), ("Agents", agents), ("Commands", commands),
         ("Hooks", hooks), ("MCP servers", mcpServers), ("LSP servers", lspServers)]
            .filter { !$0.1.isEmpty }
            .map { (label: $0.0, names: $0.1) }
    }
}

/// One plugin, whether installed or merely offered by a marketplace.
public struct PluginEntry: Sendable, Hashable, Identifiable {
    /// `name@marketplace` — the id every `claude plugin` subcommand takes.
    public var id: String
    public var name: String
    public var marketplace: String
    public var description: String
    public var author: String?
    public var category: String?
    public var homepage: String?
    /// The git URL or in-repo path the marketplace entry points at.
    public var sourceLabel: String?
    public var installCount: Int?
    public var version: String?
    /// `user`, `project` or `local`; nil when not installed.
    public var scope: String?
    public var isInstalled = false
    public var isEnabled = false
    public var installedAt: Date?
    /// Anthropic's stated reason from `blocklist.json`; a plugin with one gets a warning, not a hidden row.
    public var blockedReason: String?
    public var components: PluginComponents?
    /// Projected tokens added to *every* session, and the model that projection is for.
    public var alwaysOnTokens: Int?
    public var tokenModel: String?

    public init(id: String, name: String, marketplace: String, description: String = "") {
        self.id = id; self.name = name; self.marketplace = marketplace; self.description = description
    }

    public var isBlocked: Bool { blockedReason != nil }

    public var homepageURL: URL? { homepage.flatMap(URL.init(string:)) }

    /// Matches the Discover search field: name, description, author, category and marketplace.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        for term in q.split(separator: " ").map(String.init) {
            let haystack = [name, description, author ?? "", category ?? "", marketplace]
            guard haystack.contains(where: { $0.localizedCaseInsensitiveContains(term) }) else { return false }
        }
        return true
    }

    /// "2,966" → "3.0K", "69,140" → "69.1K". Install counts are the only number in a row, so they stay short.
    public static func shortCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1000
            return k < 10 ? String(format: "%.1fK", k) : "\(Int(k.rounded()))K"
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    /// "~1,622 tok" for the detail card.
    public static func shortTokens(_ n: Int) -> String {
        n < 1000 ? "~\(n) tok" : String(format: "~%.1fk tok", Double(n) / 1000)
    }
}
