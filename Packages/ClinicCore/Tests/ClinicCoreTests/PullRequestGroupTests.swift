import Foundation
import Testing
@testable import ClinicCore

// ADR-230. Shapes from two real sessions: a seven-layer chain built by hand (each PR targeting the branch of
// the one below, no GitHub stack) plus a fix onto main, and a merged GitHub stack beside two fixes.

private func ref(_ n: Int, repo: String = "octocat/example") -> PullRequestRef {
    PullRequestRef(url: URL(string: "https://github.com/\(repo)/pull/\(n)")!)!
}

private func stack(_ number: Int, position: Int, base: String = "main") -> PullRequestStack {
    PullRequestStack(number: number, size: 4, baseRefName: base, position: position, entries: [])
}

@Suite struct PullRequestGroupTests {
    @Test func chainsPullRequestsThatTargetEachOthersHeads() {
        // 14 ← 15 ← 16 onto main, mentioned out of order, and 21 onto main on its own.
        let branches: [Int: PullRequestGroup.Branches] = [
            14: .init(base: "main", head: "layer-1"), 15: .init(base: "layer-1", head: "layer-2"),
            16: .init(base: "layer-2", head: "layer-3"), 21: .init(base: "main", head: "fix"),
        ]
        let groups = PullRequestGroup.grouped([ref(16), ref(14), ref(21), ref(15)],
                                              branches: { branches[$0.number] }, stacks: { _ in nil })
        #expect(groups.map { $0.refs.map(\.number) } == [[21], [14, 15, 16]])
        #expect(groups.map(\.base) == [nil, "main"])
        #expect(groups.map(\.isStack) == [false, true])
    }

    @Test func gitHubStackWinsAndKeepsPositionOrder() {
        let positions = [1296: 1, 1297: 2, 1300: 3, 1301: 4]
        let groups = PullRequestGroup.grouped([ref(1295), ref(1300), ref(1296), ref(1301), ref(1297), ref(1306)],
                                              branches: { _ in nil },
                                              stacks: { r in positions[r.number].map { stack(1302, position: $0) } })
        #expect(groups.map { $0.refs.map(\.number) } == [[1295], [1296, 1297, 1300, 1301], [1306]])
        #expect(groups[1].base == "main")
    }

    @Test func aForkDoesNotChain() {
        // 2 and 3 both sit on 1, so none of the three is drawn as one list.
        let branches: [Int: PullRequestGroup.Branches] = [
            1: .init(base: "main", head: "a"), 2: .init(base: "a", head: "b"), 3: .init(base: "a", head: "c"),
        ]
        let groups = PullRequestGroup.grouped([ref(1), ref(2), ref(3)], branches: { branches[$0.number] }, stacks: { _ in nil })
        #expect(groups.map { $0.refs.map(\.number) } == [[1], [2], [3]])
    }

    @Test func aForkAboveTheBottomKeepsTheChainUnderIt() {
        // 1 ← 2, then 3 and 4 both on 2: 1 and 2 still stack.
        let branches: [Int: PullRequestGroup.Branches] = [
            1: .init(base: "main", head: "a"), 2: .init(base: "a", head: "b"),
            3: .init(base: "b", head: "c"), 4: .init(base: "b", head: "d"),
        ]
        let groups = PullRequestGroup.grouped([ref(1), ref(2), ref(3), ref(4)], branches: { branches[$0.number] }, stacks: { _ in nil })
        #expect(groups.map { $0.refs.map(\.number) } == [[1, 2], [3], [4]])
    }

    @Test func sameBranchNamesInAnotherRepositoryDoNotChain() {
        let a = ref(1, repo: "o/a"), b = ref(2, repo: "o/b")
        let branches: [String: PullRequestGroup.Branches] = [
            a.id: .init(base: "main", head: "x"), b.id: .init(base: "x", head: "y"),
        ]
        let groups = PullRequestGroup.grouped([a, b], branches: { branches[$0.id] }, stacks: { _ in nil })
        #expect(groups.count == 2)
    }

    @Test func unreadPullRequestsStandAloneAndDuplicatesCollapse() {
        let branches: [Int: PullRequestGroup.Branches] = [1: .init(base: "main", head: "a")]
        let groups = PullRequestGroup.grouped([ref(1), ref(2), ref(1)], branches: { branches[$0.number] }, stacks: { _ in nil })
        #expect(groups.map { $0.refs.map(\.number) } == [[2], [1]])
    }

    @Test func aCycleEnds() {
        let branches: [Int: PullRequestGroup.Branches] = [1: .init(base: "b", head: "a"), 2: .init(base: "a", head: "b")]
        let groups = PullRequestGroup.grouped([ref(1), ref(2)], branches: { branches[$0.number] }, stacks: { _ in nil })
        #expect(groups.flatMap(\.refs).map(\.number).sorted() == [1, 2])
    }

    @Test func groupsAreOrderedByTheirNewestMember() {
        // The chain's top (3) is mentioned last, so the chain is the newest group.
        let branches: [Int: PullRequestGroup.Branches] = [
            1: .init(base: "main", head: "a"), 3: .init(base: "a", head: "c"), 9: .init(base: "main", head: "z"),
        ]
        let groups = PullRequestGroup.grouped([ref(1), ref(9), ref(3)], branches: { branches[$0.number] }, stacks: { _ in nil })
        #expect(groups.map { $0.refs.map(\.number) } == [[9], [1, 3]])
    }
}

@Suite struct PullRequestTallyTests {
    private func mark(_ state: PullRequest.State = .open, _ attention: PullRequestMark.Attention = .none) -> PullRequestMark {
        PullRequestMark(state: state, isDraft: false, attention: attention, symbolName: "", summary: "")
    }

    @Test func countsOpenChecksAndFinished() {
        let tally = PullRequestTally([mark(.open, .checksFailing), mark(.open, .checksFailing), mark(.open, .checksPending),
                                      mark(.open, .approved), nil, mark(.merged), mark(.closed)])
        #expect(tally == { var t = PullRequestTally([]); t.open = 5; t.failing = 2; t.running = 1; t.finished = 2; return t }())
        #expect(tally.detail == "2 failing · 1 running")
    }

    @Test func quietWhenNothingFailsOrRuns() {
        #expect(PullRequestTally([mark(), mark(.open, .conflicts)]).detail == nil)
        #expect(PullRequestTally([mark(.open, .checksPending)]).detail == "1 running")
    }
}
