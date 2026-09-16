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

    /// The status line's windows over the fetch (ADR-162): newer and unreset replaces, the rest stays.
    @Test func liveWindowsOverlayTheFetch() throws {
        let json = """
        {"limits":[{"kind":"session","percent":40,"severity":"warning","resets_at":"2026-09-16T20:00:00Z"},
                   {"kind":"weekly_all","percent":30,"severity":"normal"},
                   {"kind":"weekly_scoped","percent":70,"severity":"normal","scope":{"model":{"display_name":"Fable"}}}]}
        """
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let fetched = try UsageSnapshot.parse(Data(json.utf8), subscription: "max", now: t0)
        #expect(UsageSnapshot.combining(nil, live: LiveRateLimits(), now: t0) == nil)
        #expect(UsageSnapshot.combining(fetched, live: LiveRateLimits(), now: t0) == fetched)

        var live = LiveRateLimits()
        let report = StatusLineReport(fiveHour: .init(usedPercentage: 55.6, resetsAt: t0.addingTimeInterval(3600)),
                                      sevenDay: .init(usedPercentage: 31, resetsAt: t0.addingTimeInterval(-1)))
        let first = live.absorb(report, at: t0.addingTimeInterval(60))
        #expect(first)
        // The same windows again change nothing and keep their first arrival.
        let again = live.absorb(report, at: t0.addingTimeInterval(120))
        #expect(!again)
        #expect(live.fiveHour?.receivedAt == t0.addingTimeInterval(60))

        let now = t0.addingTimeInterval(90)
        let combined = try #require(UsageSnapshot.combining(fetched, live: live, now: now))
        #expect(combined.bars.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
        #expect(combined.bars[0].rawPercent == 56 && combined.bars[0].severity == "normal")
        #expect(combined.bars[1].percent == 30, "a window whose reset has passed is ignored")
        #expect(combined.bars[2].modelName == "Fable" && combined.subscription == "max")
        #expect(combined.updatedAt == t0.addingTimeInterval(60))

        // A fetch newer than the reading wins.
        var later = fetched; later.fetchedAt = t0.addingTimeInterval(100)
        #expect(UsageSnapshot.combining(later, live: live, now: now)?.bars[0].percent == 40)

        // A report that leaves a window out keeps the one held.
        let partial = live.absorb(StatusLineReport(contextUsedPercentage: 3), at: now)
        #expect(!partial)
        #expect(live.fiveHour != nil)

        // Not connected: the live windows alone, in display order.
        live.absorb(StatusLineReport(fiveHour: .init(usedPercentage: 104, resetsAt: t0.addingTimeInterval(3600)),
                                     sevenDay: .init(usedPercentage: 9, resetsAt: t0.addingTimeInterval(86400))), at: now)
        let alone = try #require(UsageSnapshot.combining(nil, live: live, now: now))
        #expect(alone.bars.map(\.kind) == ["session", "weekly_all"])
        #expect(alone.bars[0].percent == 100 && alone.bars[0].severity == "exceeded" && alone.credits == nil)
    }

    @Test func toleratesGarbage() throws {
        let s = try UsageSnapshot.parse(Data(#"{"limits":[{"percent":"x"},null,{}],"spend":{"enabled":false}}"#.utf8))
        #expect(s.bars.isEmpty && s.credits == nil)
        #expect(throws: UsageError.self) { try UsageSnapshot.parse(Data("[]".utf8)) }
    }

    /// The collapsed snapshot's labels and its drop order (ADR-085).
    @Test func compactSnapshotKeepsThePressingBars() throws {
        let json = """
        {"limits":[{"kind":"session","percent":10,"severity":"normal"},
                   {"kind":"weekly_all","percent":40,"severity":"normal"},
                   {"kind":"weekly_scoped","percent":120,"severity":"exceeded","scope":{"model":{"display_name":"Claude Opus 4.5"}}}]}
        """
        let s = try UsageSnapshot.parse(Data(json.utf8))
        #expect(s.bars.map(\.shortTitle) == ["5h", "7d", "Opus"])
        // Two chips fit: the exceeded scoped bar stays, the calm session bar goes, order is preserved.
        #expect(s.compactBars(limit: 2).map(\.kind) == ["weekly_all", "weekly_scoped"])
        #expect(s.compactBars(limit: 1).map(\.kind) == ["weekly_scoped"])
        #expect(s.compactBars(limit: 9).count == 3)
        #expect(s.compactBars(limit: 0).isEmpty)
    }

    @Test func compactSnapshotFallsBackToPercent() throws {
        let json = """
        {"limits":[{"kind":"session","percent":80,"severity":"normal"},
                   {"kind":"weekly_all","percent":15,"severity":"normal"}]}
        """
        let s = try UsageSnapshot.parse(Data(json.utf8))
        #expect(s.compactBars(limit: 1).map(\.kind) == ["session"])
        // An unknown kind still gets a label rather than an empty chip.
        let odd = try UsageSnapshot.parse(Data(#"{"limits":[{"kind":"monthly_extra","percent":3}]}"#.utf8))
        #expect(odd.bars[0].shortTitle == "Monthly")
    }

    @Test func parsesCredentials() {
        let c = ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":4102444800000,"subscriptionType":"max"}}"#.utf8))
        #expect(c?.accessToken == "tok" && c?.subscriptionType == "max" && c?.isExpired == false)
        #expect(ClaudeCredentials.parse(Data("{}".utf8)) == nil)
    }
}
