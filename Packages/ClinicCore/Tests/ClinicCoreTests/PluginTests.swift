import Foundation
import Testing
@testable import ClinicCore

/// Fixtures are trimmed copies of the real shapes (ADR-044): `claude plugin list --json --available`,
/// a marketplace manifest, `plugin-catalog-cache.json`, `blocklist.json`.
@Suite struct PluginCatalogTests {

    let listJSON = #"""
    {"installed":[{"id":"tdd@matt","version":"1.2.3","scope":"user","enabled":true,
                   "installPath":"/c/tdd/1.2.3","installedAt":"2026-08-13T00:49:43.971Z"},
                  {"id":"gone@removed-market","version":"0.1.0","scope":"user","enabled":false}],
     "available":[{"pluginId":"tdd@matt","name":"tdd","description":"Test-driven development",
                   "marketplaceName":"matt","source":{"source":"git-subdir","url":"https://github.com/m/s.git","path":"plugins/tdd"},
                   "installCount":41200},
                  {"pluginId":"aikido@matt","name":"aikido","description":"Security scanning",
                   "marketplaceName":"matt","source":"./plugins/aikido","installCount":8784}]}
    """#

    let manifestJSON = #"""
    {"name":"matt","description":"A marketplace","owner":{"name":"Matt"},
     "plugins":[{"name":"tdd","description":"Test-driven development","author":{"name":"Matt Pocock"},
                 "category":"productivity","homepage":"https://example.com/tdd",
                 "source":{"source":"git-subdir","url":"https://github.com/m/s.git","path":"plugins/tdd"}},
                {"name":"aikido","description":"Security scanning","author":"Aikido","category":"security"}]}
    """#

    let cacheJSON = #"""
    {"version":1,"fetchedAt":"2026-09-09T02:17:07.308Z","catalog":{"plugins":{
      "tdd@matt":{"plugin":"tdd",
        "tokens":{"claude-opus-4-7":{"always_on":1622,"on_invoke":25462},"claude-sonnet-4-6":{"always_on":796,"on_invoke":19014}},
        "components":{"commands":[],"agents":[],"skills":[{"name":"tdd","chars":{"always_on":60}},{"name":"grilling"}],
                      "hooks":[],"mcpServers":["notion"],"lspServers":[]},
        "unique_installs":41200,
        "marketplace_entry":{"name":"tdd","description":"From the cache","author":{"name":"Cache Author"},"category":"testing"}}}}}
    """#

    @Test func parsesListInBothShapes() {
        let both = PluginCatalog.parseList(Data(listJSON.utf8))
        #expect(both.installed.map(\.id) == ["tdd@matt", "gone@removed-market"])
        #expect(both.installed[0].version == "1.2.3" && both.installed[0].scope == "user" && both.installed[0].enabled)
        #expect(both.installed[0].installedAt != nil)
        #expect(both.installed[1].enabled == false)
        #expect(both.available.map(\.id) == ["tdd@matt", "aikido@matt"])
        #expect(both.available[0].sourceLabel == "https://github.com/m/s.git · plugins/tdd")
        #expect(both.available[1].sourceLabel == "./plugins/aikido")
        #expect(both.available[0].installCount == 41200)

        // `claude plugin list --json` without --available is a bare array, and carries no `available`.
        let bare = PluginCatalog.parseList(Data(#"[{"id":"tdd@matt","version":"1.2.3"}]"#.utf8))
        #expect(bare.installed.map(\.id) == ["tdd@matt"] && bare.available.isEmpty)
        // No `enabled` key means the CLI listed it as installed: on.
        #expect(bare.installed[0].enabled)

        #expect(PluginCatalog.parseList(Data("not json".utf8)).installed.isEmpty)
    }

    @Test func parsesManifestAndCache() {
        let manifest = PluginCatalog.parseManifest(Data(manifestJSON.utf8), marketplace: "ignored-when-named")
        #expect(Set(manifest.keys) == ["tdd@matt", "aikido@matt"])
        #expect(manifest["tdd@matt"]?.author == "Matt Pocock")
        #expect(manifest["aikido@matt"]?.author == "Aikido")   // author as a bare string
        #expect(manifest["tdd@matt"]?.homepage == "https://example.com/tdd")

        let cache = PluginCatalog.parseCatalogCache(Data(cacheJSON.utf8))
        let info = try! #require(cache["tdd@matt"])
        #expect(info.installCount == 41200)
        #expect(info.components?.skills == ["tdd", "grilling"])   // objects and bare strings both name a component
        #expect(info.components?.mcpServers == ["notion"])
        #expect(info.components?.agents.isEmpty == true)
        // The costliest model is the honest projection when the session's model is unknown.
        #expect(info.worstAlwaysOn?.tokens == 1622 && info.worstAlwaysOn?.model == "claude-opus-4-7")

        #expect(PluginCatalog.parseCatalogCache(Data("{}".utf8)).isEmpty)
        #expect(PluginCatalog.parseManifest(Data("[]".utf8), marketplace: "m").isEmpty)
    }

    @Test func parsesMarketplacesInBothShapes() {
        let cli = PluginCatalog.parseMarketplaces(Data(#"""
        [{"name":"matt","source":"github","repo":"m/s","installLocation":"/loc/matt"}]
        """#.utf8))
        #expect(cli.map(\.name) == ["matt"])
        #expect(cli[0].origin == "m/s" && cli[0].homepageURL?.absoluteString == "https://github.com/m/s")

        let known = PluginCatalog.parseMarketplaces(Data(#"""
        {"matt":{"source":{"source":"github","repo":"m/s"},"installLocation":"/loc/matt","lastUpdated":"2026-09-09T01:59:21.090Z"},
         "local":{"source":{"source":"local","path":"/tmp/mk"},"installLocation":"/tmp/mk"}}
        """#.utf8))
        #expect(known.map(\.name) == ["local", "matt"])   // sorted
        #expect(known.first { $0.name == "local" }?.origin == "/tmp/mk")

        let merged = PluginCatalog.merge(marketplaces: cli, known: known)
        #expect(merged.map(\.name) == ["local", "matt"])  // a marketplace only on disk still shows
        #expect(merged.first { $0.name == "matt" }?.lastUpdated != nil)
        #expect(PluginCatalog.parseMarketplaces(Data("nope".utf8)).isEmpty)
    }

    @Test func parsesBlocklist() {
        let blocked = PluginCatalog.parseBlocklist(Data(#"""
        {"fetchedAt":"2026-04-04T14:21:08.500Z",
         "plugins":[{"plugin":"bad@matt","reason":"just-a-test","text":"This one is unsafe"},
                    {"plugin":"terse@matt"}]}
        """#.utf8))
        #expect(blocked["bad@matt"] == "This one is unsafe")     // `text` beats `reason`
        #expect(blocked["terse@matt"] == "Flagged by Anthropic.")
        #expect(PluginCatalog.parseBlocklist(Data("{}".utf8)).isEmpty)
    }

    @Test func mergeCombinesEverySource() {
        let entries = PluginCatalog.merge(
            list: PluginCatalog.parseList(Data(listJSON.utf8)),
            manifests: PluginCatalog.parseManifest(Data(manifestJSON.utf8), marketplace: "matt"),
            cache: PluginCatalog.parseCatalogCache(Data(cacheJSON.utf8)),
            blocklist: ["aikido@matt": "Unsafe"])

        #expect(entries.map(\.id) == ["aikido@matt", "gone@removed-market", "tdd@matt"])

        let tdd = try! #require(entries.first { $0.id == "tdd@matt" })
        #expect(tdd.isInstalled && tdd.isEnabled && tdd.version == "1.2.3" && tdd.scope == "user")
        #expect(tdd.author == "Matt Pocock")                    // the manifest wins over the cache's copy
        #expect(tdd.description == "Test-driven development")
        #expect(tdd.installCount == 41200 && tdd.alwaysOnTokens == 1622)
        #expect(tdd.components?.skills == ["tdd", "grilling"])
        #expect(!tdd.isBlocked)

        let aikido = try! #require(entries.first { $0.id == "aikido@matt" })
        #expect(!aikido.isInstalled && aikido.blockedReason == "Unsafe")
        #expect(aikido.category == "security" && aikido.alwaysOnTokens == nil)

        // Installed from a marketplace that no longer offers it: still listed, still uninstallable.
        let gone = try! #require(entries.first { $0.id == "gone@removed-market" })
        #expect(gone.isInstalled && !gone.isEnabled && gone.name == "gone" && gone.marketplace == "removed-market")

        // Enrichment is optional: the CLI's own JSON alone still produces correct install state.
        let bare = PluginCatalog.merge(list: PluginCatalog.parseList(Data(listJSON.utf8)))
        #expect(bare.count == 3 && bare.first { $0.id == "tdd@matt" }?.isInstalled == true)
        #expect(bare.first { $0.id == "tdd@matt" }?.author == nil)
    }

    @Test func kindsDescribeWhatAPluginAdds() {
        let entries = PluginCatalog.merge(
            list: PluginCatalog.parseList(Data(listJSON.utf8)),
            cache: PluginCatalog.parseCatalogCache(Data(cacheJSON.utf8)))

        let tdd = try! #require(entries.first { $0.id == "tdd@matt" })
        // Declaration order, not the order the JSON happened to list them in.
        #expect(tdd.kinds == [.skills, .mcpServers])
        #expect(tdd.provides(.skills) && tdd.provides(.mcpServers))
        #expect(!tdd.provides(.agents) && !tdd.provides(.hooks))
        #expect(tdd.components?.count(of: .skills) == 2)
        #expect(tdd.components?.groups.map(\.kind) == [.skills, .mcpServers])
        #expect(tdd.components?.groups.first?.names == ["tdd", "grilling"])

        // No cache entry means an unknown inventory, which must not answer yes to every filter.
        let aikido = try! #require(entries.first { $0.id == "aikido@matt" })
        #expect(aikido.components == nil && aikido.kinds.isEmpty)
        #expect(PluginKind.allCases.allSatisfy { !aikido.provides($0) })
    }

    @Test func kindLabelsAreShortInTheBarAndFullInTheDetail() {
        #expect(PluginKind.mcpServers.label == "MCP" && PluginKind.mcpServers.groupLabel == "MCP servers")
        #expect(PluginKind.skills.label == "Skills" && PluginKind.skills.groupLabel == "Skills")
        #expect(PluginKind.allCases.map(\.rawValue) == ["skills", "agents", "commands", "mcpServers", "hooks", "lspServers"])
    }

    @Test func searchMatchesEveryFacet() {
        var e = PluginEntry(id: "tdd@matt", name: "tdd", marketplace: "matt", description: "Test-driven development")
        e.author = "Matt Pocock"; e.category = "productivity"
        #expect(e.matches("") && e.matches("TDD") && e.matches("driven") && e.matches("pocock") && e.matches("product"))
        #expect(e.matches("tdd matt"))          // every term must land
        #expect(!e.matches("tdd nonsense"))
    }

    @Test func formatsCountsAndTokens() {
        #expect(PluginEntry.shortCount(999) == "999")
        #expect(PluginEntry.shortCount(2966) == "3.0K")
        #expect(PluginEntry.shortCount(69140) == "69K")
        #expect(PluginEntry.shortCount(1_600_000) == "1.6M")
        #expect(PluginEntry.shortTokens(842) == "~842 tok")
        #expect(PluginEntry.shortTokens(1622) == "~1.6k tok")
    }
}

@Suite struct PluginServiceTests {
    @Test func argumentsMatchTheCLIContract() {
        typealias Op = PluginService.Operation
        #expect(PluginService.arguments(for: .list) == ["plugin", "list", "--json", "--available"])
        #expect(PluginService.arguments(for: .marketplaces) == ["plugin", "marketplace", "list", "--json"])
        // -y is required when stdout is not a TTY, which it never is here.
        #expect(PluginService.arguments(for: .install("tdd@matt", .user)) == ["plugin", "install", "tdd@matt", "--scope", "user", "-y"])
        #expect(PluginService.arguments(for: .uninstall("tdd@matt", .user)) == ["plugin", "uninstall", "tdd@matt", "--scope", "user", "-y"])
        #expect(PluginService.arguments(for: .update("tdd@matt", .user)) == ["plugin", "update", "tdd@matt", "--scope", "user", "-y"])
        // enable/disable auto-detect scope and reject -y.
        #expect(PluginService.arguments(for: .enable("tdd@matt")) == ["plugin", "enable", "tdd@matt"])
        #expect(PluginService.arguments(for: .disable("tdd@matt")) == ["plugin", "disable", "tdd@matt"])
        // The marketplace subcommands reject -y too (verified against the CLI).
        #expect(PluginService.arguments(for: .marketplaceAdd("owner/repo")) == ["plugin", "marketplace", "add", "owner/repo"])
        #expect(PluginService.arguments(for: .marketplaceRemove("matt")) == ["plugin", "marketplace", "remove", "matt"])
        #expect(PluginService.arguments(for: .marketplaceUpdate("matt")) == ["plugin", "marketplace", "update", "matt"])
        #expect(PluginService.arguments(for: .marketplaceUpdate(nil)) == ["plugin", "marketplace", "update"])
        let _: Op = .list
    }

    @Test func displayCommandIsWhatTheSheetShows() {
        #expect(PluginService.displayCommand(.install("tdd@matt", .user)) == "claude plugin install tdd@matt --scope user -y")
    }

    @Test func errorPrefersStderrAndStripsDecoration() {
        let e = PluginError(command: "claude plugin marketplace remove x", exitCode: 1,
                            output: "\u{001B}[31m✘\u{001B}[0m Failed to remove marketplace: 'x' not found\n")
        #expect(e.message == "Failed to remove marketplace: 'x' not found")
        // Some subcommands say nothing on stderr; stdout is the fallback, the exit code the last resort.
        #expect(PluginError(command: "c", exitCode: 2, output: "  ", stdout: "boom").message == "boom")
        #expect(PluginError(command: "claude plugin list", exitCode: 3, output: "").message == "claude plugin list failed (exit 3)")
    }
}
