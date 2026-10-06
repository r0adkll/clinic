import Foundation
import Testing
@testable import ClinicCore

/// The reporting protocol's words and state (ADR-182).
@Suite struct SessionReportingTests {
    let parent = SessionID("aaaaaaaa-0000-0000-0000-000000000001")
    let child = SessionID("bbbbbbbb-0000-0000-0000-000000000002")

    @Test func briefNamesTheParentAndAsksForAReport() {
        let b = SessionReporting.brief(parentTitle: "Fix rounding", peerName: "clinic-1f", directory: "/repo", reporting: true)
        #expect(b.hasPrefix("You were started by Clinic session \"Fix rounding\" (peer name clinic-1f) working in /repo."))
        #expect(b.contains("call report_to_parent"))
        #expect(b.contains("message clinic-1f directly"))
    }

    @Test func briefWithoutPeerNameOrReportingSaysLess() {
        let b = SessionReporting.brief(parentTitle: "Fix rounding", peerName: nil, directory: "/repo", reporting: false)
        #expect(b == "You were started by Clinic session \"Fix rounding\" working in /repo.")
    }

    @Test func headerNamesTheChildProjectAndShortId() {
        let h = SessionReporting.header(childTitle: "Check tax", project: "pantry", id: child)
        #expect(h == "Report from child session \"Check tax\" (pantry, bbbbbbbb):")
        #expect(SessionReporting.header(childTitle: "x", project: nil, id: child) == "Report from child session \"x\" (bbbbbbbb):")
        #expect(SessionReporting.compose(header: h, message: "  done \n") == h + "\ndone")
    }

    @Test func deliveryWaitsForAPromptOrAWorkingTurn() {
        #expect(SessionReporting.canDeliver(state: .idle, waitingOn: nil))
        #expect(SessionReporting.canDeliver(state: .working, waitingOn: nil))
        #expect(SessionReporting.canDeliver(state: .waitingForInput, waitingOn: "idle_prompt"))
        #expect(!SessionReporting.canDeliver(state: .waitingForInput, waitingOn: "elicitation"))
        #expect(!SessionReporting.canDeliver(state: .waitingForPermission, waitingOn: nil))
        #expect(!SessionReporting.canDeliver(state: .launching, waitingOn: nil))
        #expect(!SessionReporting.canDeliver(state: .exited, waitingOn: nil))
        #expect(!SessionReporting.canDeliver(state: nil, waitingOn: nil))
    }

    @Test func reportsAreKeptPerParentAndCappedOnDeliveredOnes() {
        var s = ClinicState()
        s.childReporting[child] = ChildReporting()
        for i in 0..<(SessionReport.maxPerParent + 3) {
            s.addReport(SessionReport(from: child, message: "r\(i)", at: Date(timeIntervalSince1970: Double(i)),
                                      deliveredAt: i == 1 ? nil : Date()), to: parent)
        }
        let list = s.reports[parent] ?? []
        #expect(list.count == SessionReport.maxPerParent)
        // The held one survived the cap; the oldest delivered ones went.
        #expect(list.contains { $0.message == "r1" && $0.isPending })
        #expect(!list.contains { $0.message == "r0" })
        #expect(s.pendingReports(for: parent).map(\.message) == ["r1"])
        #expect(s.childReporting[child]?.reportedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func reportingStateRoundTrips() throws {
        var s = ClinicState()
        s.childReporting[child] = ChildReporting(paused: true, remindedAt: Date(timeIntervalSince1970: 5))
        s.addReport(SessionReport(id: UUID(), from: child, message: "hello", at: Date(timeIntervalSince1970: 9)), to: parent)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(ClinicState.self, from: try e.encode(s))
        #expect(back.childReporting == s.childReporting)
        #expect(back.reports == s.reports)
    }

    @Test func launchCarriesTheBrief() {
        var l = ClaudeLaunch(mode: .new(id: child), settingsFilePath: "/s.json", prompt: "go")
        l.appendSystemPrompt = "You were started by Clinic session \"p\" working in /r."
        let args = l.arguments
        let i = try! #require(args.firstIndex(of: "--append-system-prompt"))
        #expect(args[i + 1].hasPrefix("You were started"))
        #expect(args.first == "go")
    }
}
