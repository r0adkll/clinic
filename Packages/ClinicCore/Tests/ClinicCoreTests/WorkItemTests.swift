import Foundation
import Testing
@testable import ClinicCore

// No test here runs `gh` (CI has no auth). Coverage is argv building, parsing and the pure filter (ADR-113).

private let clinic = WorkItemSource.github("r0adkll/clinic")
private let enterprise = WorkItemSource.github("platform/api", host: "github.acme.corp")

private func item(_ n: Int, _ title: String = "Issue", source: WorkItemSource = clinic, body: String = "", state: WorkItemState = .open,
                  author: String = "octocat", assignees: [String] = [], labels: [String] = [], milestone: String? = nil,
                  comments: Int = 0, created: TimeInterval = 0, updated: TimeInterval = 0) -> WorkItem {
    WorkItem(ref: WorkItemRef(source: source, number: n, url: URL(string: "https://\(source.host)/\(source.scope)/issues/\(n)")!),
             title: title, body: body, state: state, author: author, assignees: assignees,
             labels: labels.map { WorkItemLabel(name: $0, color: "d73a4a") }, milestone: milestone, commentCount: comments,
             createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated))
}

// MARK: - Sources and refs

@Suite struct WorkItemSourceTests {
    @Test func identityAndHalves() {
        #expect(clinic.id == "github:github.com/r0adkll/clinic")
        #expect(clinic.owner == "r0adkll")
        #expect(clinic.repo == "clinic")
        #expect(clinic.shortName == "clinic")
        #expect(clinic.webURL?.absoluteString == "https://github.com/r0adkll/clinic")
        #expect(enterprise.id == "github:github.acme.corp/platform/api")
        let ref = WorkItemRef(source: clinic, number: 12, url: URL(string: "https://github.com/r0adkll/clinic/issues/12")!)
        #expect(ref.display == "r0adkll/clinic#12")
        #expect(ref.shortDisplay == "clinic#12")
    }
}

// MARK: - Arguments

@Suite struct GitHubIssueArgumentTests {
    @Test func issuesPageIsGraphQLOnTheSourceHost() {
        let args = GitHubService.arguments(for: .issues(enterprise, .open, after: nil))
        #expect(Array(args.prefix(8)) == ["api", "graphql", "--hostname", "github.acme.corp", "-F", "owner=platform", "-F", "repo=api"])
        #expect(!args.contains { $0.hasPrefix("after=") })
        let query = args.last ?? ""
        #expect(query.hasPrefix("query="))
        #expect(query.contains("states:[OPEN]"))
        #expect(query.contains("comments{totalCount}"))
        // The whole point of GraphQL over `gh issue list`: no comment bodies in the list.
        #expect(!query.contains("comments(first"))
    }

    @Test func laterPagesCarryTheCursorAndClosedSpellsItsState() {
        let args = GitHubService.arguments(for: .issues(clinic, .closed, after: "Y3Vyc29y"))
        #expect(args.contains("after=Y3Vyc29y"))
        #expect(args.last?.contains("states:[CLOSED]") == true)
    }

    @Test func repoViewRunsInTheProject() {
        let op = GitHubService.Operation.repoView(projectPath: "/tmp/p")
        #expect(GitHubService.arguments(for: op) == ["repo", "view", "--json", "nameWithOwner,url"])
        #expect(GitHubService.directory(for: op)?.path == "/tmp/p")
        #expect(GitHubService.environment(for: op).isEmpty)
    }

    @Test func mentionsSearchPicksEnterpriseByEnvironment() {
        let op = GitHubService.Operation.mentions(host: "github.acme.corp", limit: 200)
        #expect(GitHubService.arguments(for: op) == ["search", "issues", "--mentions", "@me", "--state", "open", "--limit", "200", "--json", "url,number,repository"])
        #expect(GitHubService.environment(for: op) == ["GH_HOST": "github.acme.corp"])
        #expect(GitHubService.environment(for: .mentions(host: "github.com", limit: 200)).isEmpty)
    }

    @Test func detailAndViewer() {
        let ref = WorkItemRef(source: clinic, number: 7, url: URL(string: "https://github.com/r0adkll/clinic/issues/7")!)
        let args = GitHubService.arguments(for: .issueDetail(ref))
        #expect(args.contains("number=7"))
        #expect(args.last?.contains("closedByPullRequestsReferences") == true)
        #expect(GitHubService.arguments(for: .viewer(host: nil)) == ["api", "user", "--jq", ".login"])
        #expect(GitHubService.arguments(for: .viewer(host: "github.acme.corp")) == ["api", "user", "--jq", ".login", "--hostname", "github.acme.corp"])
    }
}

// MARK: - Parsing

/// Trimmed, anonymised capture of `GitHubService.issuesQuery` against a public repository.
private let issuesPage = """
{"data":{"repository":{"issues":{
  "pageInfo":{"hasNextPage":true,"endCursor":"Y3Vyc29yOnYyOpK0"},
  "nodes":[
    {"number":14420,"title":"gh fails HTTPS requests with an instant connection reset",
     "body":"Since 2.100.0 every request resets.","url":"https://github.com/octo/cli/issues/14420",
     "state":"OPEN","stateReason":null,"createdAt":"2026-09-10T20:19:58Z","updatedAt":"2026-09-10T21:48:01Z","closedAt":null,
     "author":{"login":"gloox"},"assignees":{"nodes":[{"login":"octocat"}]},
     "labels":{"nodes":[{"name":"needs-triage","color":"D6393F"},{"name":"bug","color":""}]},
     "milestone":{"title":"v2.101"},"comments":{"totalCount":5}},
    {"number":14309,"title":"Attach cannot work for app tokens","body":"","url":"https://github.com/octo/cli/issues/14309",
     "state":"CLOSED","stateReason":"NOT_PLANNED","createdAt":"2026-09-01T08:19:52Z","updatedAt":"2026-09-10T19:49:02.123Z",
     "closedAt":"2026-09-10T19:49:02Z","author":null,"assignees":{"nodes":[]},"labels":{"nodes":[]},"milestone":null,
     "comments":{"totalCount":10}},
    {"title":"no number, skipped"}
  ]}}}}
"""

@Suite struct GitHubIssueParsingTests {
    let source = WorkItemSource.github("octo/cli")

    @Test func parsesAPage() throws {
        let page = try GitHubIssues.parseIssuesPage(Data(issuesPage.utf8), source: source)
        #expect(page.nextCursor == "Y3Vyc29yOnYyOpK0")
        #expect(page.items.count == 2)
        let first = page.items[0]
        #expect(first.ref.number == 14420)
        #expect(first.ref.source == source)
        #expect(first.state == .open)
        #expect(first.author == "gloox")
        #expect(first.assignees == ["octocat"])
        #expect(first.labels == [WorkItemLabel(name: "needs-triage", color: "D6393F"), WorkItemLabel(name: "bug", color: nil)])
        #expect(first.milestone == "v2.101")
        #expect(first.commentCount == 5)
        #expect(first.updatedAt > first.createdAt)
        let second = page.items[1]
        #expect(second.state == .closed)
        #expect(second.stateReason == "not_planned")
        #expect(second.author == "ghost")
        #expect(second.closedAt != nil)
        #expect(second.milestone == nil)
    }

    @Test func lastPageHasNoCursor() throws {
        let json = #"{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":"x"},"nodes":[]}}}}"#
        #expect(try GitHubIssues.parseIssuesPage(Data(json.utf8), source: source).nextCursor == nil)
    }

    @Test func graphQLErrorsSurfaceTheirMessage() {
        let json = #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository with the name 'octo/gone'."}]}"#
        #expect {
            try GitHubIssues.parseIssuesPage(Data(json.utf8), source: source)
        } throws: { error in
            (error as? GitHubError)?.stderr.contains("Could not resolve") == true
        }
    }

    @Test func repoView() {
        let s = GitHubIssues.parseRepoView(Data(#"{"nameWithOwner":"platform/api","url":"https://github.acme.corp/platform/api"}"#.utf8))
        #expect(s == enterprise)
        #expect(GitHubIssues.parseRepoView(Data("{}".utf8)) == nil)
    }

    @Test func unresolvedReasons() {
        #expect(GitHubIssues.unresolvedReason("failed to run git: fatal: not a git repository (or any of the parent directories): .git\n") == "Not a git repository")
        #expect(GitHubIssues.unresolvedReason("no git remotes found") == "No git remote")
        #expect(GitHubIssues.unresolvedReason("none of the git remotes configured for this repository point to a known GitHub host. To tell gh about a new GitHub host, please use `gh auth login`") == "No GitHub remote gh knows")
        #expect(GitHubIssues.unresolvedReason("\n  something odd happened\nmore") == "something odd happened")
        #expect(GitHubIssues.unresolvedReason("") == "gh could not resolve a repository")
    }

    @Test func mentions() throws {
        let json = #"[{"number":89,"repository":{"name":"sign","nameWithOwner":"r0adkll/sign"},"url":"https://github.com/r0adkll/sign/issues/89"},{"number":1}]"#
        let refs = try GitHubIssues.parseMentions(Data(json.utf8), host: "github.com")
        #expect(refs.map(\.id) == ["https://github.com/r0adkll/sign/issues/89"])
        #expect(refs.first?.source == .github("r0adkll/sign"))
    }

    @Test func detail() throws {
        let json = """
        {"data":{"repository":{"issue":{
          "bodyHTML":"<p>Body</p>","author":{"login":"gloox","avatarUrl":"https://avatars.example/u/1"},
          "comments":{"totalCount":140,"nodes":[
            {"id":"IC_1","url":"https://github.com/octo/cli/issues/1#issuecomment-1","createdAt":"2026-09-10T20:19:58Z",
             "bodyHTML":"<p>Hi</p>","author":{"login":"octocat","avatarUrl":"https://avatars.example/u/2"}},
            {"id":"IC_2","createdAt":"2026-09-10T21:00:00Z","bodyHTML":"<p>Gone</p>","author":null}]},
          "closedByPullRequestsReferences":{"nodes":[
            {"number":55,"title":"Fix it","url":"https://github.com/octo/cli/pull/55","state":"MERGED","isDraft":false}]}
        }}}}
        """
        let ref = WorkItemRef(source: source, number: 1, url: URL(string: "https://github.com/octo/cli/issues/1")!)
        let d = try GitHubIssues.parseDetail(Data(json.utf8), ref: ref)
        #expect(d.bodyHTML == "<p>Body</p>")
        #expect(d.authorAvatarURL?.absoluteString == "https://avatars.example/u/1")
        #expect(d.comments.map(\.author) == ["octocat", "ghost"])
        #expect(d.totalComments == 140)
        #expect(d.linkedPullRequests.first?.state == .merged)
        #expect(d.linkedPullRequests.first?.number == 55)
    }
}

// MARK: - Filter

@Suite struct WorkItemFilterTests {
    let ctx = WorkItemFilter.Context(viewers: ["github.com": "me", "github.acme.corp": "corp-me"],
                                     mentioned: ["https://github.com/r0adkll/clinic/issues/3"])
    let items = [
        item(1, "Crash on launch", author: "me", assignees: ["someone"], labels: ["bug", "p1"], milestone: "0.2", comments: 4, created: 10, updated: 50),
        item(2, "Sidebar polish", body: "the CRASH is cosmetic", assignees: ["Me"], labels: ["UI"], comments: 9, created: 20, updated: 40),
        item(3, "Mentioned thing", labels: ["Bug"], created: 30, updated: 30),
        item(4, "Enterprise work", source: enterprise, assignees: ["corp-me"], created: 40, updated: 20),
        item(5, "Old closed", state: .closed, author: "me", created: 5, updated: 60),
    ]

    @Test func viewsUseTheViewerOfEachHost() {
        var f = WorkItemFilter()
        f.view = .assigned
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [2, 4])
        f.view = .created
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [1])
        f.view = .mentioned
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [3])
        f.view = .all
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [1, 2, 3, 4])
        // No viewer known for a host: nothing is "mine" there.
        #expect(WorkItemFilter.matches(items[3], view: .assigned, context: .init()) == false)
    }

    @Test func stateFilter() {
        var f = WorkItemFilter(); f.view = .all
        f.state = .closed
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [5])
        f.state = .all
        #expect(f.apply(items, context: ctx).count == 5)
    }

    @Test func labelsMustAllMatchCaseInsensitively() {
        var f = WorkItemFilter(); f.view = .all
        f.labels = ["bug"]
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [1, 3])
        f.labels = ["BUG", "p1"]
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [1])
    }

    @Test func assigneeAuthorMilestone() {
        var f = WorkItemFilter(); f.view = .all
        f.assignee = WorkItemFilter.unassigned
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [3])
        f.assignee = "me"
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [2])
        f.assignee = nil; f.author = "ME"
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [1])
        f.author = nil; f.milestone = "0.2"
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [1])
        #expect(f.hasRefinements)
        f.clearRefinements()
        #expect(!f.hasRefinements)
    }

    @Test func textSearch() {
        var f = WorkItemFilter(); f.view = .all
        f.text = "crash"
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [1, 2])   // title and body
        f.text = "crash launch"
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [1])      // every term
        f.text = "#3"
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [3])      // exact number
        f.text = "platform/api"
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [4])      // repository
    }

    @Test func sorts() {
        var f = WorkItemFilter(); f.view = .all
        f.sort = .created
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [4, 3, 2, 1])
        f.sort = .comments
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [2, 1, 3, 4])
        f.sort = .number
        #expect(f.apply(items, context: ctx).map(\.ref.number) == [4, 3, 2, 1])
    }

    @Test func countsFollowTheRefinements() {
        var f = WorkItemFilter()
        f.text = "crash"
        let views = f.viewCounts(items, context: ctx)
        #expect(views[.all] == 2)
        #expect(views[.assigned] == 1)
        #expect(views[.created] == 1)
        #expect(views[.mentioned] == 0)
        f.view = .all; f.text = ""
        #expect(f.sourceCounts(items, context: ctx) == [clinic.id: 3, enterprise.id: 1])
    }

    @Test func savedFiltersDecodeTolerantly() throws {
        var f = WorkItemFilter(); f.view = .mentioned; f.labels = ["bug"]; f.grouping = .project
        #expect(try JSONDecoder().decode(WorkItemFilter.self, from: JSONEncoder().encode(f)) == f)
        let partial = try JSONDecoder().decode(WorkItemFilter.self, from: Data(#"{"view":"all","sort":"nonsense","future":1}"#.utf8))
        #expect(partial.view == .all)
        #expect(partial.sort == .updated)
        #expect(partial.state == .open)
    }

    @Test func facetsMergeByName() {
        let facets = WorkItemFacets(items)
        #expect(facets.labels.map(\.name) == ["bug", "p1", "UI"])
        #expect(facets.assignees == ["corp-me", "Me", "someone"])
        #expect(facets.authors == ["me", "octocat"])
        #expect(facets.milestones == ["0.2"])
    }
}

// MARK: - Branch names and prompts (ADR-114)

@Suite struct WorkItemSessionTests {
    @Test func branchNames() {
        #expect(WorkItemBranch.name(for: item(123, "Crash on launch when sidebar is empty!")) == "issue-123-crash-on-launch-when-sidebar-is-empty")
        #expect(WorkItemBranch.name(for: item(7, "Égalité: ça marche?")) == "issue-7-egalite-ca-marche")
        #expect(WorkItemBranch.name(for: item(8, "🔥🔥")) == "issue-8")
        #expect(WorkItemBranch.slug("alpha beta gamma delta", max: 10) == "alpha-beta")   // cut lands between words
        #expect(WorkItemBranch.slug("alpha beta gamma delta", max: 13) == "alpha-beta")   // backs up to a whole word
        #expect(WorkItemBranch.slug("supercalifragilistic", max: 5) == "super")          // one long word is cut
    }

    @Test func promptNamesTheIssueByURL() {
        let prompt = GitHubWorkItemProvider.prompt(for: item(12, "Fix the thing"))
        #expect(prompt.contains("r0adkll/clinic#12"))
        #expect(prompt.contains("\"Fix the thing\""))
        #expect(prompt.contains("gh issue view https://github.com/r0adkll/clinic/issues/12 --comments"))
    }
}

// MARK: - Composer suggestions (ADR-117)

@Suite struct WorkItemSuggestionTests {
    let context = WorkItemFilter.Context(viewers: ["github.com": "r0adkll"], mentioned: [])

    @Test func tiersThenRecency() {
        let items = [
            item(1, updated: 900),                                     // unassigned, newest
            item(2, assignees: ["R0ADKLL"], updated: 100),             // mine, oldest
            item(3, author: "r0adkll", updated: 500),                  // filed by me
            item(4, assignees: ["someone"], updated: 950),             // someone else's
            item(5, state: .closed, assignees: ["r0adkll"], updated: 999),
            item(6, updated: 300),                                     // mentions me
        ]
        var ctx = context
        ctx.mentioned = [items[5].id]
        #expect(WorkItemSuggestions.rank(items, context: ctx, limit: 10).map(\.ref.number) == [2, 3, 6, 1])
        #expect(WorkItemSuggestions.rank(items, context: ctx).map(\.ref.number) == [2, 3, 6])
    }

    @Test func itemsWithSessionsAreLeftOut() {
        let mine = item(2, assignees: ["r0adkll"])
        #expect(WorkItemSuggestions.rank([mine, item(1)], context: context, linked: [mine.id]).map(\.ref.number) == [1])
    }

    @Test func unknownViewerRanksByRecencyAlone() {
        let items = [item(1, source: enterprise, assignees: ["someone"], updated: 10), item(2, source: enterprise, updated: 20)]
        #expect(WorkItemSuggestions.rank(items, context: context).map(\.ref.number) == [2, 1])
    }
}

// MARK: - Cache and state

@Suite struct WorkItemCacheTests {
    @Test func roundTripsPerSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = WorkItemCache(directory: dir)
        #expect(cache.url(for: enterprise).lastPathComponent == "github-github.acme.corp-platform-api.json")
        #expect(cache.load(clinic) == nil)
        let cached = CachedWorkItems(source: clinic, fetchedAt: Date(timeIntervalSince1970: 1_000), items: [item(1, updated: 100)],
                                     truncated: true, lastViewed: [1: Date(timeIntervalSince1970: 50)])
        try cache.save(cached)
        let loaded = try #require(cache.load(clinic))
        #expect(loaded == cached)
        #expect(loaded.isUpdatedSinceViewed(loaded.items[0]))
        #expect(!loaded.isUpdatedSinceViewed(item(2, updated: 100)))   // never viewed ≠ unread
    }

    @Test func stateKeepsOverridesAndLinks() throws {
        var state = ClinicState()
        let id = SessionID.generate()
        let ref = WorkItemRef(source: clinic, number: 1, url: URL(string: "https://github.com/r0adkll/clinic/issues/1")!)
        state.taskSources["/p"] = [enterprise]
        state.taskSources["/none"] = []
        state.workItemLinks[id] = [ref]
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(ClinicState.self, from: e.encode(state))
        #expect(back.taskSources == state.taskSources)
        #expect(back.workItemLinks == state.workItemLinks)
        // Older state files have neither key.
        let old = try d.decode(ClinicState.self, from: Data(#"{"version":1}"#.utf8))
        #expect(old.taskSources.isEmpty && old.workItemLinks.isEmpty)
    }
}
