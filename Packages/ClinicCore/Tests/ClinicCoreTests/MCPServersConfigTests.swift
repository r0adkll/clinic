import Foundation
import Testing
@testable import ClinicCore

@Suite struct MCPServersConfigTests {
    @Test func parsesGlobalAndProjectServers() {
        let json = #"""
        {"mcpServers":{"docs":{"type":"http","url":"https://example.com/mcp","headers":{"X-Key":"abc"}},"hc":{"command":"hardcover","args":["mcp"],"env":{"TOKEN":"secret"}}},
         "projects":{"/p/one":{"mcpServers":{"local":{"command":"npx","args":["-y","x"]}},"enabledMcpjsonServers":["a"],"disabledMcpjsonServers":["b"]},"/p/two":{"mcpServers":{}}}}
        """#
        let entries = MCPServersConfig.parse(Data(json.utf8))
        #expect(entries.map(\.name) == ["docs", "hc", "local"])
        #expect(entries[0].transport == "http" && entries[0].summary == "https://example.com/mcp")
        #expect(entries[0].headerKeys == ["X-Key"] && entries[0].scope == .user)
        #expect(entries[1].transport == "stdio" && entries[1].envKeys == ["TOKEN"] && entries[1].summary == "hardcover mcp")
        #expect(entries[2].scope == .local && entries[2].projectPath == "/p/one")
        let g = MCPServersConfig.governance(for: "/p/one", in: Data(json.utf8))
        #expect(g.enabled == ["a"] && g.disabled == ["b"])
        #expect(MCPServersConfig.parse(Data("nope".utf8)).isEmpty)
    }

    /// Entries carry key *names* only; values stay in the file until `definition(name:…)` asks for them.
    @Test func entriesCarryNoSecretValues() {
        let json = #"{"mcpServers":{"hc":{"command":"x","env":{"TOKEN":"s3cret"}}}}"#
        let e = MCPServersConfig.parse(Data(json.utf8))[0]
        #expect(e.envKeys == ["TOKEN"])
        #expect(!e.summary.contains("s3cret"))
    }

    /// `~/.claude.json` is a *sibling* of `~/.claude`, but a `CLAUDE_CONFIG_DIR` puts it *inside*.
    /// ADR-060 assumed the sibling form in both cases (ADR-093).
    @Test func configFileFollowsClaudeConfigDir() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(ClaudePaths(environment: [:], home: home).configFile.path == "/Users/x/.claude.json")
        #expect(ClaudePaths(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"], home: home).configFile.path == "/tmp/cc/.claude.json")
    }

    @Test func approvalComesFromTheProjectLists() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"mcpServers":{"yes":{"command":"a"},"no":{"command":"b"},"dunno":{"command":"c"}}}"#.utf8)
            .write(to: dir.appendingPathComponent(".mcp.json"))

        let entries = MCPServersConfig.loadProjectFile(projectPath: dir.path, governance: (["yes"], ["no"]))
        #expect(entries.map(\.name) == ["dunno", "no", "yes"])
        #expect(entries.map(\.approval) == [.pending, .disabled, .approved])
        #expect(entries.allSatisfy { $0.scope == .project })
    }

    @Test func redactsSecrets() {
        #expect(MCPServerEntry.redact("npx mcp-remote https://x/ --header Authorization: Bearer QNKf1v1YLxJQe6") == "npx mcp-remote https://x/ --header Authorization: Bearer ••••••")
        #expect(MCPServerEntry.redact("https://api.example.com/mcp?token=abc123def") == "https://api.example.com/mcp?token=••••••")
        #expect(MCPServerEntry.redact("--key sk-ant-1234567890abcdef") == "--key sk-ant-••••••")
        #expect(MCPServerEntry.redact("hardcover mcp serve") == "hardcover mcp serve")
    }

    @Test func validatesNames() {
        #expect(MCPServersConfig.isValidName("hardcover"))
        #expect(MCPServersConfig.isValidName("etsy-docs.v2_1"))
        #expect(!MCPServersConfig.isValidName(""))
        #expect(!MCPServersConfig.isValidName("has space"))
        #expect(!MCPServersConfig.isValidName("--flag"))
        #expect(!MCPServersConfig.isValidName("semi;colon"))
    }
}

@Suite struct MCPSnippetTests {
    /// The shape READMEs actually document.
    @Test func parsesTheDocumentedWrapper() {
        let text = #"""
        {
          "mcpServers": {
            "sentry": { "type": "http", "url": "https://mcp.sentry.dev/mcp" }
          }
        }
        """#
        let s = MCPServersConfig.parseSnippet(text)
        #expect(s.count == 1)
        #expect(s[0].name == "sentry")
        #expect(s[0].definition.type == "http" && s[0].definition.url == "https://mcp.sentry.dev/mcp")
    }

    @Test func parsesAnUnwrappedMapAndKeepsEveryServer() {
        let text = #"{"a":{"command":"x"},"b":{"url":"https://y/mcp"}}"#
        let s = MCPServersConfig.parseSnippet(text)
        #expect(s.map(\.name) == ["a", "b"])
        #expect(s[0].definition.type == "stdio" && s[1].definition.type == "http")
    }

    /// A bare definition has no name to lift, so the form asks for one.
    @Test func parsesABareDefinition() {
        let s = MCPServersConfig.parseSnippet(#"{"command":"npx","args":["-y","srv"],"env":{"K":"v"}}"#)
        #expect(s.count == 1 && s[0].name == "")
        #expect(s[0].definition.command == "npx" && s[0].definition.args == ["-y", "srv"] && s[0].definition.env == ["K": "v"])
    }

    /// `{"command": {…}}` is a bare stdio definition, never a server named "command".
    @Test func doesNotMistakeADefinitionKeyForAName() {
        let s = MCPServersConfig.parseSnippet(#"{"command":"npx","args":[]}"#)
        #expect(s.count == 1 && s[0].name == "")
    }

    @Test func rejectsJunk() {
        #expect(MCPServersConfig.parseSnippet("not json").isEmpty)
        #expect(MCPServersConfig.parseSnippet("").isEmpty)
        #expect(MCPServersConfig.parseSnippet("{}").isEmpty)
        #expect(MCPServersConfig.parseSnippet(#"{"mcpServers":{"x":{"nothing":1}}}"#).isEmpty)
    }

    /// What `add-json` receives must be exactly Claude Code's own on-disk shape.
    @Test func roundTripsToClaudesShape() {
        let d = MCPServerDefinition(type: "stdio", command: "/bin/echo", args: ["a"], env: ["K": "v"])
        // Slashes unescaped: this string is shown in the command preview, not just parsed.
        #expect(d.json == #"{"args":["a"],"command":"/bin/echo","env":{"K":"v"},"type":"stdio"}"#)
        #expect(d.redactedJSON.contains("••••••") && !d.redactedJSON.contains("\"v\""))

        let http = MCPServerDefinition(type: "http", url: "https://x/mcp", headers: ["Authorization": "Bearer z"])
        #expect(http.json.contains("\"url\"") && !http.json.contains("command"))
        #expect(!http.redactedJSON.contains("Bearer z"))
    }
}
