import Foundation
import Testing
@testable import ClinicCore

@Suite struct LoopEvidenceTests {
    private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_792_243_210 + s) }

    @Test func theTrailKeepsTheNewestCrumbsOldestFirst() {
        var trail = BreadcrumbTrail(capacity: 3)
        for i in 0..<5 { trail.add("hook", "event \(i)", at: t(Double(i))) }
        #expect(trail.entries.map(\.message) == ["event 2", "event 3", "event 4"])
    }

    @Test func aKeyedCrumbFoldsIntoTheLastOneWithItsKeyAndMovesToTheEnd() {
        var trail = BreadcrumbTrail()
        trail.add("terminal", "title ✳ Working", key: "title:a", at: t(0))
        trail.add("terminal", "progress busy", key: "progress:a", at: t(1))
        trail.add("terminal", "title ✶ Working", key: "title:a", at: t(2))
        trail.add("terminal", "title ✻ Working", key: "title:a", at: t(3))
        #expect(trail.entries.map(\.message) == ["progress busy", "title ✻ Working"])
        let title = trail.entries[1]
        #expect(title.repeats == 3)
        #expect(title.since == t(0))
        #expect(title.date == t(3))
    }

    @Test func foldingLooksOnlyAsFarBackAsItsWindow() {
        var trail = BreadcrumbTrail(foldWindow: 2)
        trail.add("terminal", "pwd /a", key: "pwd:a", at: t(0))
        trail.add("hook", "PreToolUse", at: t(1))
        trail.add("hook", "PostToolUse", at: t(2))
        trail.add("terminal", "pwd /a", key: "pwd:a", at: t(3))
        #expect(trail.entries.map(\.repeats) == [1, 1, 1, 1])
    }

    @Test func theSameKeyInAnotherCategoryDoesNotFold() {
        var trail = BreadcrumbTrail()
        trail.add("terminal", "a", key: "x", at: t(0))
        trail.add("sessions", "b", key: "x", at: t(1))
        #expect(trail.entries.count == 2)
    }

    @Test func aLoopReportRoundTripsToTheMillisecond() throws {
        var loop = LoopRecord(window: "main 4CA3E817", trippedAt: t(0.125), tripPasses: 40, quietMax: 3,
                              probes: ["tab.pwd", "sessions.sessions"])
        loop.passes = 41
        loop.changedTotals = ["tab.pwd": 1]
        loop.renderedTotals = ["RootToolbar": 1]
        loop.recorded = [.init(index: 41, millis: 9, changed: ["tab.pwd"], rendered: ["RootToolbar×1"],
                               firstResponder: "GhosttySurfaceView 0x1", toolbar: ["header 290", "bell hidden"],
                               frame: "0,0 1800x1130")]
        let report = LoopReport(date: t(0.125), appVersion: "0.6.1 (220)", osVersion: "26.6.2", loop: loop,
                                breadcrumbs: [Breadcrumb(date: t(0.004), category: "hook", message: "Stop")])
        var decoded = try DiagnosticsArchive.decoder.decode(LoopReport.self, from: report.encoded())
        // Written to the millisecond, so a crumb 4 ms after the trip still reads as before it.
        #expect(abs(decoded.breadcrumbs[0].date.timeIntervalSince(t(0.004))) < 0.001)
        #expect(abs(decoded.loop.trippedAt.timeIntervalSince(t(0.125))) < 0.001)
        decoded.date = report.date; decoded.loop.trippedAt = loop.trippedAt; decoded.breadcrumbs[0].date = t(0.004)
        #expect(decoded == report)
    }

    @Test func aReportFromBeforeTheTrailStillReads() throws {
        let old = #"{"appVersion":"0.6.0 (213)","callStack":[],"date":"2026-10-25T01:29:00Z","name":"NSGenericException","osVersion":"26.6.2"}"#
        let report = try DiagnosticsArchive.decoder.decode(ExceptionReport.self, from: Data(old.utf8))
        #expect(report.breadcrumbs == nil)
        #expect(report.loop == nil)
        #expect(report.date == Date(timeIntervalSince1970: 1_792_891_740))
    }
}
