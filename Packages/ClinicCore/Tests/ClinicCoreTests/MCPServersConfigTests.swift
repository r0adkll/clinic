import Foundation
import Testing
@testable import ClinicCore

@Suite struct MCPServersConfigTests {
    @Test func parsesGlobalAndProjectServers() {
        let json = #"""
        {"mcpServers":{"docs":{"type":"http","url":"https://example.com/mcp"},"hc":{"command":"hardcover","args":["mcp"],"env":{"TOKEN":"secret"}}},
         "projects":{"/p/one":{"mcpServers":{"local":{"command":"npx","args":["-y","x"]}},"enabledMcpjsonServers":["a"],"disabledMcpjsonServers":["b"]},"/p/two":{"mcpServers":{}}}}
        """#
        let entries = MCPServersConfig.parse(Data(json.utf8))
        #expect(entries.map(\.name) == ["docs", "hc", "local"])
        #expect(entries[0].transport == "http" && entries[0].summary == "https://example.com/mcp")
        #expect(entries[1].transport == "stdio" && entries[1].envKeys == ["TOKEN"] && entries[1].summary == "hardcover mcp")
        #expect(entries[2].scope == .project("/p/one"))
        let g = MCPServersConfig.governance(for: "/p/one", in: Data(json.utf8))
        #expect(g.enabled == ["a"] && g.disabled == ["b"])
        #expect(MCPServersConfig.parse(Data("nope".utf8)).isEmpty)
    }

    @Test func redactsSecrets() {
        #expect(MCPServerEntry.redact("npx mcp-remote https://x/ --header Authorization: Bearer QNKf1v1YLxJQe6") == "npx mcp-remote https://x/ --header Authorization: Bearer ••••••")
        #expect(MCPServerEntry.redact("https://api.example.com/mcp?token=abc123def") == "https://api.example.com/mcp?token=••••••")
        #expect(MCPServerEntry.redact("--key sk-ant-1234567890abcdef") == "--key sk-ant-••••••")
        #expect(MCPServerEntry.redact("hardcover mcp serve") == "hardcover mcp serve")
    }
}
