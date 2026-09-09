import Foundation
import Testing
@testable import ClinicCore

/// argv is the contract with the CLI, so it is asserted here rather than discovered at runtime (ADR-093).
@Suite struct MCPServiceTests {
    private let stdio = MCPServerDefinition(type: "stdio", command: "hardcover", args: ["mcp", "serve"], env: ["TOKEN": "s3cret"])

    @Test func addUsesAddJSONWithTheChosenScope() {
        #expect(MCPService.arguments(for: .add(name: "hc", definition: stdio, scope: .user))
                == ["mcp", "add-json", "hc", stdio.json, "--scope", "user"])
        #expect(MCPService.arguments(for: .add(name: "hc", definition: stdio, scope: .project)).last == "project")
    }

    @Test func removeCarriesTheScopeItIsDeletingFrom() {
        #expect(MCPService.arguments(for: .remove(name: "hc", scope: .local))
                == ["mcp", "remove", "hc", "--scope", "local"])
    }

    @Test func theOtherSubcommands() {
        #expect(MCPService.arguments(for: .get(name: "hc")) == ["mcp", "get", "hc"])
        #expect(MCPService.arguments(for: .login(name: "hc")) == ["mcp", "login", "hc"])
        #expect(MCPService.arguments(for: .logout(name: "hc")) == ["mcp", "logout", "hc"])
        #expect(MCPService.arguments(for: .resetProjectChoices) == ["mcp", "reset-project-choices"])
        #expect(MCPService.arguments(for: .importFromClaudeDesktop(scope: .user))
                == ["mcp", "add-from-claude-desktop", "--scope", "user"])
    }

    /// The preview is redacted; the argv that actually runs is not (ADR-093).
    @Test func displayCommandMasksSecretsButArgvDoesNot() {
        let shown = MCPService.displayCommand(.add(name: "hc", definition: stdio, scope: .user))
        #expect(!shown.contains("s3cret"))
        #expect(shown.contains("••••••"))
        #expect(shown.hasPrefix("claude mcp add-json hc "))

        let argv = MCPService.arguments(for: .add(name: "hc", definition: stdio, scope: .user))
        #expect(argv.contains { $0.contains("s3cret") })
    }

    @Test func displayCommandLeavesNonAddOperationsAlone() {
        #expect(MCPService.displayCommand(.remove(name: "hc", scope: .user)) == "claude mcp remove hc --scope user")
    }
}

/// Parsing `claude mcp get`, using its real output — including the failure whose "Issue:" is an HTML page.
@Suite struct MCPHealthTests {
    @Test func connected() {
        #expect(MCPService.parseHealth("""
        hardcover:
          Scope: User config (available in all your projects)
          Status: ✔ Connected
        """) == .connected)
    }

    @Test func needsAuthenticationAndPendingApproval() {
        #expect(MCPService.parseHealth("  Status: ! Needs authentication") == .needsAuthentication)
        #expect(MCPService.parseHealth("  Status: ⏸ Pending approval (run `claude` to approve)") == .pendingApproval)
    }

    @Test func failureKeepsTheIssueAndTruncatesIt() {
        let out = """
        js1:
          Status: ✘ Failed to connect
          Issue: -32000: MCP error -32000: Connection closed
          Type: stdio
        """
        #expect(MCPService.parseHealth(out) == .failed("-32000: MCP error -32000: Connection closed"))

        let html = "  Status: ✘ Failed to connect\n  Issue: " + String(repeating: "x", count: 500)
        guard case .failed(let d) = MCPService.parseHealth(html) else { Issue.record("expected .failed"); return }
        #expect(d.count == 200)
    }

    /// `get` also prints env values and headers in plaintext. Nothing but Status/Issue is retained.
    @Test func doesNotRetainSecretsFromTheRestOfTheOutput() {
        let out = """
        js2:
          Status: ✔ Connected
          Headers:
            Authorization: Bearer zzz
          Environment:
            K=v
        """
        let health = MCPService.parseHealth(out)
        #expect(health == .connected)
        #expect(health.detail == nil)
    }

    @Test func unknownWhenThereIsNoStatusLine() {
        #expect(MCPService.parseHealth("No MCP server named \"nope\".") == .unknown)
    }
}

/// The two-step edit's recovery decision (ADR-093). Verified against the CLI's real behaviour:
/// `remove` succeeds, a bad `add-json` exits 1 leaving the server gone, and re-adding restores it.
@Suite struct MCPEditRecoveryTests {
    @Test func restoresOnlyWhenSomethingRanAndThereIsASnapshot() {
        // The add failed after the remove succeeded — the server is gone, put it back.
        #expect(MCPEditRecovery.shouldRestore(completedSteps: 1, hasSnapshot: true))
        // The remove itself failed: nothing changed, so restoring would add a server back that
        // was never removed.
        #expect(!MCPEditRecovery.shouldRestore(completedSteps: 0, hasSnapshot: true))
        // A plain add or remove has no snapshot and needs no undo.
        #expect(!MCPEditRecovery.shouldRestore(completedSteps: 1, hasSnapshot: false))
        #expect(!MCPEditRecovery.shouldRestore(completedSteps: 0, hasSnapshot: false))
    }

    @Test func messageAlwaysLeadsWithWhatTheCLISaid() {
        let failure = "Invalid configuration: : Invalid input"
        #expect(MCPEditRecovery.message(failure: failure, outcome: .nothingToUndo) == failure)

        let restored = MCPEditRecovery.message(failure: failure, outcome: .restored)
        #expect(restored.hasPrefix(failure) && restored.contains("original server was restored"))

        let lost = MCPEditRecovery.message(failure: failure,
                                           outcome: .restoreFailed(reason: "disk full",
                                                                   command: "claude mcp add-json sentry '{}' --scope user"))
        #expect(lost.hasPrefix(failure))
        #expect(lost.contains("disk full"))
        // The user must be left with something they can run themselves.
        #expect(lost.contains("claude mcp add-json sentry '{}' --scope user"))
    }
}
