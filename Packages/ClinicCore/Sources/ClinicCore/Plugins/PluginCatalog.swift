import Foundation

/// Reads Claude Code's plugin state (ADR-084). Every function here is a pure parse over bytes, so the
/// whole catalogue is fixture-testable without a `claude` on PATH or a `~/.claude` on disk.
///
/// Install state comes from the CLI's own `--json`, which is the contract; the on-disk manifests only
/// *enrich* it, so a cache Claude Code has not written yet costs detail, never correctness. Unknown
/// keys are ignored throughout ([[ADR-060]]).
public enum PluginCatalog {

    // MARK: Paths

    public static func pluginsDirectory(paths: ClaudePaths = ClaudePaths()) -> URL {
        paths.configDirectory.appendingPathComponent("plugins", isDirectory: true)
    }

    /// A marketplace repo declares itself in `.claude-plugin/marketplace.json`; older ones put it at the root.
    public static func manifestURL(inMarketplaceAt root: URL, fileManager: FileManager = .default) -> URL? {
        let candidates = [root.appendingPathComponent(".claude-plugin/marketplace.json"),
                          root.appendingPathComponent("marketplace.json")]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    // MARK: `claude plugin list --json [--available]`

    public struct InstalledRecord: Sendable, Hashable {
        public var id: String
        public var version: String?
        public var scope: String?
        public var enabled: Bool
        public var installedAt: Date?
    }

    public struct AvailableRecord: Sendable, Hashable {
        public var id: String
        public var name: String
        public var marketplace: String
        public var description: String
        public var sourceLabel: String?
        public var installCount: Int?
    }

    public struct ListResult: Sendable, Hashable {
        public var installed: [InstalledRecord] = []
        public var available: [AvailableRecord] = []
    }

    /// Accepts both shapes the CLI emits: a bare array (`list --json`) and `{installed, available}` (`--available`).
    public static func parseList(_ data: Data) -> ListResult {
        var result = ListResult()
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return result }
        if let array = root as? [[String: Any]] {
            result.installed = array.compactMap(installedRecord)
        } else if let object = root as? [String: Any] {
            result.installed = (object["installed"] as? [[String: Any]] ?? []).compactMap(installedRecord)
            result.available = (object["available"] as? [[String: Any]] ?? []).compactMap(availableRecord)
        }
        return result
    }

    private static func installedRecord(_ o: [String: Any]) -> InstalledRecord? {
        guard let id = o["id"] as? String ?? o["pluginId"] as? String, !id.isEmpty else { return nil }
        return InstalledRecord(id: id,
                               version: o["version"] as? String,
                               scope: o["scope"] as? String,
                               // A record with no `enabled` key is one the CLI listed as installed: treat it as on.
                               enabled: o["enabled"] as? Bool ?? true,
                               installedAt: date(o["installedAt"]))
    }

    private static func availableRecord(_ o: [String: Any]) -> AvailableRecord? {
        guard let id = o["pluginId"] as? String ?? o["id"] as? String, !id.isEmpty else { return nil }
        let marketplace = o["marketplaceName"] as? String ?? String(id.split(separator: "@").last ?? "")
        let name = o["name"] as? String ?? String(id.split(separator: "@").first ?? "")
        return AvailableRecord(id: id, name: name, marketplace: marketplace,
                               description: o["description"] as? String ?? "",
                               sourceLabel: sourceLabel(o["source"]),
                               installCount: o["installCount"] as? Int)
    }

    // MARK: `claude plugin marketplace list --json` and `known_marketplaces.json`

    public static func parseMarketplaces(_ data: Data) -> [MarketplaceRef] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let array = root as? [[String: Any]] {
            return array.compactMap { o in
                guard let name = o["name"] as? String else { return nil }
                return MarketplaceRef(name: name,
                                      sourceKind: o["source"] as? String ?? "unknown",
                                      origin: origin(of: o),
                                      installLocation: o["installLocation"] as? String)
            }
        }
        // `known_marketplaces.json`: name → {source: {source, repo|url|path}, installLocation, lastUpdated}
        guard let object = root as? [String: Any] else { return [] }
        return object.compactMap { name, value in
            guard let o = value as? [String: Any] else { return nil }
            let source = o["source"] as? [String: Any] ?? [:]
            return MarketplaceRef(name: name,
                                  sourceKind: source["source"] as? String ?? "unknown",
                                  origin: origin(of: source),
                                  installLocation: o["installLocation"] as? String,
                                  lastUpdated: date(o["lastUpdated"]))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Folds `lastUpdated` (only `known_marketplaces.json` has it) into the CLI's list.
    public static func merge(marketplaces cli: [MarketplaceRef], known: [MarketplaceRef]) -> [MarketplaceRef] {
        let byName = Dictionary(known.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let merged = cli.map { ref -> MarketplaceRef in
            var ref = ref
            if let k = byName[ref.name] {
                ref.lastUpdated = k.lastUpdated
                if ref.origin.isEmpty { ref.origin = k.origin }
                if ref.installLocation == nil { ref.installLocation = k.installLocation }
            }
            return ref
        }
        let seen = Set(merged.map(\.name))
        return (merged + known.filter { !seen.contains($0.name) })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: `<marketplace>/marketplace.json`

    public struct ManifestEntry: Sendable, Hashable {
        public var name: String
        public var description: String
        public var author: String?
        public var category: String?
        public var homepage: String?
        public var sourceLabel: String?
        public var version: String?
    }

    /// Keyed by `name@marketplace`. The manifest's own `name` field wins over the directory name when both exist.
    public static func parseManifest(_ data: Data, marketplace fallbackName: String) -> [String: ManifestEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let marketplace = root["name"] as? String ?? fallbackName
        let plugins = root["plugins"] as? [[String: Any]] ?? []
        var out: [String: ManifestEntry] = [:]
        for o in plugins {
            guard let name = o["name"] as? String else { continue }
            out["\(name)@\(marketplace)"] = ManifestEntry(
                name: name,
                description: o["description"] as? String ?? "",
                author: authorName(o["author"]),
                category: o["category"] as? String,
                homepage: o["homepage"] as? String,
                sourceLabel: sourceLabel(o["source"]),
                version: o["version"] as? String)
        }
        return out
    }

    // MARK: `plugin-catalog-cache.json`

    public struct CatalogInfo: Sendable, Hashable {
        public var installCount: Int?
        public var components: PluginComponents?
        /// model → always-on tokens.
        public var alwaysOnTokens: [String: Int] = [:]
        public var entry: ManifestEntry?

        /// The costliest projection across models — the honest number to show when the session's model is unknown.
        public var worstAlwaysOn: (model: String, tokens: Int)? {
            alwaysOnTokens.max { $0.value < $1.value }.map { (model: $0.key, tokens: $0.value) }
        }
    }

    public static func parseCatalogCache(_ data: Data) -> [String: CatalogInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = root["catalog"] as? [String: Any],
              let plugins = catalog["plugins"] as? [String: Any] else { return [:] }
        var out: [String: CatalogInfo] = [:]
        for (id, value) in plugins {
            guard let o = value as? [String: Any] else { continue }
            var info = CatalogInfo()
            info.installCount = o["unique_installs"] as? Int
            if let c = o["components"] as? [String: Any] { info.components = components(c) }
            for (model, cost) in (o["tokens"] as? [String: Any] ?? [:]) {
                if let cost = cost as? [String: Any], let always = cost["always_on"] as? Int { info.alwaysOnTokens[model] = always }
            }
            if let entry = o["marketplace_entry"] as? [String: Any], let name = entry["name"] as? String {
                info.entry = ManifestEntry(name: name,
                                           description: entry["description"] as? String ?? "",
                                           author: authorName(entry["author"]),
                                           category: entry["category"] as? String,
                                           homepage: entry["homepage"] as? String,
                                           sourceLabel: sourceLabel(entry["source"]),
                                           version: entry["version"] as? String)
            }
            out[id] = info
        }
        return out
    }

    private static func components(_ o: [String: Any]) -> PluginComponents {
        var c = PluginComponents()
        c.skills = names(o["skills"]); c.agents = names(o["agents"]); c.commands = names(o["commands"])
        c.hooks = names(o["hooks"]); c.mcpServers = names(o["mcpServers"]); c.lspServers = names(o["lspServers"])
        return c
    }

    /// Component lists hold either bare names or `{name, chars}` objects.
    private static func names(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? String ?? ($0 as? [String: Any])?["name"] as? String }
    }

    // MARK: `blocklist.json`

    /// Plugin id → the reason Anthropic gave, preferring the human-readable `text`.
    public static func parseBlocklist(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for o in plugins {
            guard let id = o["plugin"] as? String else { continue }
            let text = (o["text"] as? String) ?? (o["reason"] as? String) ?? "Flagged by Anthropic."
            out[id] = text
        }
        return out
    }

    // MARK: Merge

    /// The catalogue the screen renders: every available plugin, plus any installed one its marketplace
    /// no longer offers (removed upstream, or installed from a marketplace since deleted).
    public static func merge(list: ListResult,
                             manifests: [String: ManifestEntry] = [:],
                             cache: [String: CatalogInfo] = [:],
                             blocklist: [String: String] = [:]) -> [PluginEntry] {
        let installedById = Dictionary(list.installed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [String: PluginEntry] = [:]

        for record in list.available {
            var e = PluginEntry(id: record.id, name: record.name, marketplace: record.marketplace, description: record.description)
            e.sourceLabel = record.sourceLabel
            e.installCount = record.installCount
            entries[record.id] = e
        }
        for record in list.installed where entries[record.id] == nil {
            let parts = record.id.split(separator: "@", maxSplits: 1).map(String.init)
            entries[record.id] = PluginEntry(id: record.id, name: parts.first ?? record.id,
                                             marketplace: parts.count > 1 ? parts[1] : "")
        }

        for (id, var e) in entries {
            if let m = manifests[id] ?? cache[id]?.entry {
                if e.description.isEmpty { e.description = m.description }
                e.author = m.author; e.category = m.category; e.homepage = m.homepage
                e.sourceLabel = e.sourceLabel ?? m.sourceLabel
                e.version = e.version ?? m.version
            }
            if let c = cache[id] {
                e.installCount = e.installCount ?? c.installCount
                e.components = c.components
                if let worst = c.worstAlwaysOn { e.alwaysOnTokens = worst.tokens; e.tokenModel = worst.model }
            }
            if let installed = installedById[id] {
                e.isInstalled = true
                e.isEnabled = installed.enabled
                e.version = installed.version ?? e.version
                e.scope = installed.scope
                e.installedAt = installed.installedAt
            }
            e.blockedReason = blocklist[id]
            entries[id] = e
        }

        return entries.values.sorted { a, b in
            if a.name.lowercased() != b.name.lowercased() { return a.name.lowercased() < b.name.lowercased() }
            return a.marketplace < b.marketplace
        }
    }

    /// Reads the on-disk enrichment for a set of marketplaces: manifests, the catalogue cache, the blocklist.
    public static func loadLocalMetadata(marketplaces: [MarketplaceRef],
                                         paths: ClaudePaths = ClaudePaths(),
                                         fileManager: FileManager = .default)
        -> (manifests: [String: ManifestEntry], cache: [String: CatalogInfo], blocklist: [String: String]) {
        var manifests: [String: ManifestEntry] = [:]
        for ref in marketplaces {
            guard let location = ref.installLocation else { continue }
            let root = URL(fileURLWithPath: location, isDirectory: true)
            guard let url = manifestURL(inMarketplaceAt: root, fileManager: fileManager),
                  let data = try? Data(contentsOf: url) else { continue }
            manifests.merge(parseManifest(data, marketplace: ref.name)) { a, _ in a }
        }
        let dir = pluginsDirectory(paths: paths)
        let cache = (try? Data(contentsOf: dir.appendingPathComponent("plugin-catalog-cache.json")))
            .map(parseCatalogCache) ?? [:]
        let blocklist = (try? Data(contentsOf: dir.appendingPathComponent("blocklist.json")))
            .map(parseBlocklist) ?? [:]
        return (manifests, cache, blocklist)
    }

    /// `known_marketplaces.json`, for the `lastUpdated` the CLI does not report.
    public static func loadKnownMarketplaces(paths: ClaudePaths = ClaudePaths()) -> [MarketplaceRef] {
        guard let data = try? Data(contentsOf: pluginsDirectory(paths: paths).appendingPathComponent("known_marketplaces.json"))
        else { return [] }
        return parseMarketplaces(data)
    }

    // MARK: Shared decoding

    /// `author` is either a string or `{name, email}`.
    private static func authorName(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let o = value as? [String: Any], let name = o["name"] as? String { return name.isEmpty ? nil : name }
        return nil
    }

    /// `source` is either `"./plugins/x"` or `{source, url, path, ref}`; both reduce to one line of display text.
    private static func sourceLabel(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        guard let o = value as? [String: Any] else { return nil }
        let base = (o["url"] as? String) ?? (o["repo"] as? String) ?? (o["path"] as? String)
        guard let base, !base.isEmpty else { return o["source"] as? String }
        if let path = o["path"] as? String, o["url"] != nil, !path.isEmpty { return "\(base) · \(path)" }
        return base
    }

    private static func origin(of o: [String: Any]) -> String {
        (o["repo"] as? String) ?? (o["url"] as? String) ?? (o["path"] as? String) ?? ""
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }
}
