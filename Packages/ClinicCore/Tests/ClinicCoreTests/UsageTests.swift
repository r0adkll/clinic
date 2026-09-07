import Foundation
import Testing
@testable import ClinicCore

@Suite struct UsageTests {
    @Test func parsesLimitsAndExtraUsage() throws {
        let json = """
        {"limits":[{"kind":"weekly_all","percent":42.4,"severity":"normal","resets_at":"2026-09-10T00:00:00Z"},
                   {"kind":"session","percent":95,"severity":"warning","resets_at":"2026-09-07T17:50:00.000Z"},
                   {"kind":"weekly_scoped","percent":120,"severity":"exceeded","scope":{"model":{"display_name":"Opus"}}}],
         "extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000,"decimal_places":2,"currency":"USD","spend_limit_reached":false}}
        """
        let s = try UsageSnapshot.parse(Data(json.utf8), subscription: "max")
        #expect(s.bars.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
        #expect(s.bars[0].percent == 95 && s.bars[0].severity == "warning" && s.bars[0].resetsAt != nil)
        #expect(s.bars[2].percent == 100 && s.bars[2].rawPercent == 120 && s.bars[2].title == "Week, Opus")
        #expect(s.credits?.used == 12.34 && s.credits?.limit == 50.0)
        #expect(s.subscription == "max")
    }

    @Test func toleratesGarbage() throws {
        let s = try UsageSnapshot.parse(Data(#"{"limits":[{"percent":"x"},null,{}],"spend":{"enabled":false}}"#.utf8))
        #expect(s.bars.isEmpty && s.credits == nil)
        #expect(throws: UsageError.self) { try UsageSnapshot.parse(Data("[]".utf8)) }
    }

    @Test func parsesCredentials() {
        let c = ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":4102444800000,"subscriptionType":"max"}}"#.utf8))
        #expect(c?.accessToken == "tok" && c?.subscriptionType == "max" && c?.isExpired == false)
        #expect(ClaudeCredentials.parse(Data("{}".utf8)) == nil)
    }
}
