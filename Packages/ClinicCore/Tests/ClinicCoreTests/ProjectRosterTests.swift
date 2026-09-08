import Foundation
import Testing
@testable import ClinicCore

@Suite struct ProjectRosterTests {
    private func date(_ s: Int) -> Date { Date(timeIntervalSince1970: Double(s)) }

    @Test func ordersByRegistrationOldestFirst() {
        let paths = ProjectRoster.paths(.init(registered: ["/c": date(30), "/a": date(10), "/b": date(20)]))
        #expect(paths == ["/a", "/b", "/c"])
    }

    @Test func activityDoesNotReorder() {
        // A session in /c today must not pull it above /a (ADR-077 supersedes ADR-040 for projects).
        let paths = ProjectRoster.paths(.init(registered: ["/a": date(10), "/c": date(30)],
                                              withSessions: ["/c": .distantFuture]))
        #expect(paths == ["/a", "/c"])
    }

    @Test func registeredProjectSurvivesLosingEverySession() {
        let paths = ProjectRoster.paths(.init(registered: ["/a": date(10)], withSessions: [:]))
        #expect(paths == ["/a"])
    }

    @Test func archivedProjectComesBackAtItsOldPositionWithAnUnarchivedSession() {
        // Archive Project unregisters /b; unarchiving one of its sessions re-lists it, and the
        // session's own date keeps it between /a and /c.
        let paths = ProjectRoster.paths(.init(registered: ["/a": date(10), "/c": date(30)],
                                              withSessions: ["/a": date(10), "/b": date(20), "/c": date(30)]))
        #expect(paths == ["/a", "/b", "/c"])
    }

    @Test func removedProjectIsHiddenEvenWithSessions() {
        let paths = ProjectRoster.paths(.init(registered: ["/a": date(10), "/b": date(20)],
                                              withSessions: ["/b": date(5)], removed: ["/b"]))
        #expect(paths == ["/a"])
    }

    @Test func manualOrderComesFirstAndPinnedBeforeIt() {
        let paths = ProjectRoster.paths(.init(registered: ["/a": date(10), "/b": date(20), "/c": date(30), "/chats": date(99)],
                                              manualOrder: ["/c", "/gone", "/c", "/a"],
                                              pinnedFirst: ["/chats"]))
        #expect(paths == ["/chats", "/c", "/a", "/b"])
    }

    @Test func pinnedGroupIsAlwaysListedAndCannotBeRemoved() {
        // Chats is Clinic's own scratch group: it is a starting point even with nothing in it (ADR-068).
        #expect(ProjectRoster.paths(.init(pinnedFirst: ["/chats"])) == ["/chats"])
        let paths = ProjectRoster.paths(.init(registered: ["/a": date(10)], removed: ["/chats"], pinnedFirst: ["/chats"]))
        #expect(paths == ["/chats", "/a"])
    }

    @Test func tiesBreakOnPathSoOrderIsStable() {
        let paths = ProjectRoster.paths(.init(registered: ["/b": date(10), "/a": date(10)]))
        #expect(paths == ["/a", "/b"])
    }
}
