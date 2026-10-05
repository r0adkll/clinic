import Foundation
import Testing
@testable import ClinicCore

/// The sidebar's session tree (ADR-181).
@Suite struct SessionTreeTests {
    let a = SessionID("aaaaaaaa-0000-0000-0000-000000000001")
    let b = SessionID("bbbbbbbb-0000-0000-0000-000000000002")
    let c = SessionID("cccccccc-0000-0000-0000-000000000003")
    let d = SessionID("dddddddd-0000-0000-0000-000000000004")
    let t0 = Date(timeIntervalSince1970: 1_000)

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func item(_ id: SessionID, _ key: TimeInterval, project: String = "/p", matches: Bool = true) -> SessionTree.Item {
        SessionTree.Item(id: id, projectPath: project, sortKey: at(key), matches: matches)
    }

    @Test func flatWhenNothingHasAParent() {
        let rows = SessionTree.rows(project: "/p", items: [item(a, 1), item(b, 3), item(c, 2)], parents: [:])
        #expect(rows.map(\.id) == [b, c, a])
        #expect(rows.allSatisfy { $0.depth == 0 && !$0.hasChildren && $0.folded.isEmpty && !$0.isContext })
    }

    @Test func childIndentsUnderItsParentInTheParentsProject() {
        // c runs in another project but was spawned by b, so it lives under b and not in /q.
        let parents = [c: SessionParent(id: b, kind: .spawn)]
        let items = [item(a, 5), item(b, 1), item(c, 2, project: "/q")]
        let p = SessionTree.rows(project: "/p", items: items, parents: parents)
        #expect(p.map(\.id) == [a, b, c])
        #expect(p.map(\.depth) == [0, 0, 1])
        #expect(p[1].hasChildren && p[2].parent?.kind == .spawn)
        #expect(SessionTree.rows(project: "/q", items: items, parents: parents).isEmpty)
    }

    @Test func subtreeSortsByItsNewestActivity() {
        // b is old but its child d is the newest thing in the project, so b's subtree goes first.
        let parents = [d: SessionParent(id: b, kind: .fork)]
        let rows = SessionTree.rows(project: "/p", items: [item(a, 5), item(b, 1), item(d, 9)], parents: parents)
        #expect(rows.map(\.id) == [b, d, a])
    }

    @Test func siblingsOrderBySubtreeToo() {
        let parents = [b: SessionParent(id: a, kind: .spawn), c: SessionParent(id: a, kind: .spawn), d: SessionParent(id: b, kind: .spawn)]
        let rows = SessionTree.rows(project: "/p", items: [item(a, 1), item(b, 2), item(c, 5), item(d, 9)], parents: parents)
        #expect(rows.map(\.id) == [a, b, d, c])
        #expect(rows.map(\.depth) == [0, 1, 2, 1])
    }

    @Test func collapsedParentFoldsItsDescendants() {
        let parents = [b: SessionParent(id: a, kind: .spawn), c: SessionParent(id: b, kind: .fork)]
        let rows = SessionTree.rows(project: "/p", items: [item(a, 1), item(b, 2), item(c, 3)], parents: parents, collapsed: [a])
        #expect(rows.map(\.id) == [a])
        #expect(rows[0].hasChildren)
        #expect(Set(rows[0].folded) == [b, c])
    }

    @Test func foldingIsSuspendedWhileFiltering() {
        let parents = [b: SessionParent(id: a, kind: .spawn)]
        let rows = SessionTree.rows(project: "/p", items: [item(a, 1), item(b, 2)], parents: parents, collapsed: [a], filtering: true)
        #expect(rows.map(\.id) == [a, b])
        #expect(rows[0].folded.isEmpty)
    }

    @Test func aMatchingChildKeepsItsParentAsContext() {
        let parents = [b: SessionParent(id: a, kind: .spawn), d: SessionParent(id: c, kind: .spawn)]
        let items = [item(a, 1, matches: false), item(b, 2, matches: true), item(c, 3, matches: false), item(d, 4, matches: false)]
        let rows = SessionTree.rows(project: "/p", items: items, parents: parents, filtering: true)
        #expect(rows.map(\.id) == [a, b])
        #expect(rows[0].isContext && !rows[1].isContext)
    }

    @Test func aChildWhoseParentIsNotVisibleIsARoot() {
        let parents = [b: SessionParent(id: a, kind: .fork)]
        let rows = SessionTree.rows(project: "/p", items: [item(b, 2)], parents: parents)
        #expect(rows == [SessionTree.Row(id: b, depth: 0)])
    }

    @Test func aCycleBreaksIntoRoots() {
        let parents = [a: SessionParent(id: b, kind: .spawn), b: SessionParent(id: a, kind: .spawn), c: SessionParent(id: c, kind: .spawn)]
        let rows = SessionTree.rows(project: "/p", items: [item(a, 1), item(b, 2), item(c, 3)], parents: parents)
        #expect(rows.map(\.id) == [c, b, a])
        #expect(rows.allSatisfy { $0.depth == 0 })
    }

    @Test func descendantsWalkTheRawMap() {
        let parents = [b: SessionParent(id: a, kind: .spawn), c: SessionParent(id: b, kind: .fork), d: SessionParent(id: a, kind: .spawn)]
        #expect(SessionTree.descendants(of: a, parents: parents) == [b, d, c])
        #expect(SessionTree.descendants(of: c, parents: parents).isEmpty)
    }

    @Test func legacySpawnedByDecodesAsSpawnParents() throws {
        let json = #"{"spawnedBy":{"bbbbbbbb-0000-0000-0000-000000000002":"aaaaaaaa-0000-0000-0000-000000000001"}}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let s = try d.decode(ClinicState.self, from: Data(json.utf8))
        #expect(s.parents[b]?.id == a)
        #expect(s.parents[b]?.kind == .spawn)
        #expect(s.children(of: a) == [b])
        // Re-encoded, the new key carries it and the old one is gone.
        let out = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
        #expect(out?["parents"] is [String: Any])
        #expect(out?["spawnedBy"] == nil)
    }

    @Test func parentsRoundTrip() throws {
        var s = ClinicState()
        s.parents[b] = SessionParent(id: a, kind: .fork, since: at(0))
        s.collapsedSessions = [a]
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(ClinicState.self, from: try e.encode(s))
        #expect(back.parents == s.parents)
        #expect(back.collapsedSessions == [a])
    }
}
