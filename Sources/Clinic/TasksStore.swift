import Foundation
import Observation
import os
import ClinicCore

/// Work items for every project (ADR-112, ADR-113): which sources each project resolves to, their
/// cached and refreshed items, the viewer facts the views need, and detail on selection.
///
/// Shared by every window; what a window *shows* is its own `TasksViewState`. Nothing here runs
/// while no window shows the Tasks screen.
@MainActor
@Observable
final class TasksStore {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "tasks")
    static let openLimit = 1000
    static let closedLimit = 200
    static let maxConcurrent = 4
    static let pollInterval: Duration = .seconds(300)
    /// An appear this soon after a refresh draws from what is already here.
    static let refreshOnAppearAfter: TimeInterval = 30

    let provider: any WorkItemProvider
    private let sessions: SessionStore
    private let cache: WorkItemCache

    private(set) var availability: ToolAvailability?
    /// Automatic resolutions by project path. Overrides live in `ClinicState.taskSources`.
    private(set) var resolutions: [String: WorkItemSourceResolution] = [:]
    /// Open items by source id, as cached and refreshed.
    private(set) var snapshots: [String: CachedWorkItems] = [:]
    /// Closed items by source id, fetched only on demand and never cached (ADR-113).
    private(set) var closed: [String: [WorkItem]] = [:]
    private(set) var sourceErrors: [String: String] = [:]
    private(set) var loadingSources: Set<String> = []
    private(set) var viewers: [String: String] = [:]
    private(set) var mentioned: Set<String> = []
    private(set) var details: [String: WorkItemDetail] = [:]
    private(set) var detailErrors: [String: String] = [:]
    private(set) var detailLoading: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Bumped after every refresh; the detail pane keys its fetch on it, so signed image URLs are
    /// renewed with the list (ADR-112).
    private(set) var generation = 0

    @ObservationIgnored private var visibleCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loadedFromDisk = false
    @ObservationIgnored private var resolvedThisLaunch = false
    @ObservationIgnored private var closedRequested = false
    @ObservationIgnored private var pendingViewedSave: Task<Void, Never>?

    init(sessions: SessionStore, provider: any WorkItemProvider, cache: WorkItemCache = WorkItemCache()) {
        self.sessions = sessions
        self.provider = provider
        self.cache = cache
    }

    // MARK: Projects and sources

    /// Every sidebar project that could have a source, in roster order. Chats has no repository.
    var projects: [Project] { sessions.projects.filter { !SessionStore.isChats($0.path) } }

    /// The override if there is one, else what `gh` resolved.
    func resolution(for projectPath: String) -> WorkItemSourceResolution? {
        if let override = sessions.state.taskSources[projectPath] {
            return override.isEmpty ? .unresolved(reason: "Task source set to None") : .resolved(override)
        }
        return resolutions[projectPath]
    }

    func sources(for projectPath: String) -> [WorkItemSource] { resolution(for: projectPath)?.sources ?? [] }

    func isOverridden(_ projectPath: String) -> Bool { sessions.state.taskSources[projectPath] != nil }

    /// Every source some project points at, once, in roster order.
    var allSources: [WorkItemSource] {
        var seen = Set<String>()
        return projects.flatMap { sources(for: $0.path) }.filter { seen.insert($0.id).inserted }
    }

    /// The project a session for `ref` should run in (ADR-114): the preferred one if it has the
    /// source, else the first in roster order that does.
    func projectPath(for ref: WorkItemRef, preferring preferred: String? = nil) -> String? {
        if let preferred, sources(for: preferred).contains(ref.source) { return preferred }
        return projects.first { sources(for: $0.path).contains(ref.source) }?.path
    }

    // MARK: Items

    /// Open items from every attached source, plus closed ones when asked for.
    func items(includingClosed: Bool) -> [WorkItem] {
        let sources = allSources
        var out = sources.flatMap { snapshots[$0.id]?.items ?? [] }
        if includingClosed {
            let open = Set(out.map(\.id))
            out += sources.flatMap { closed[$0.id] ?? [] }.filter { !open.contains($0.id) }
        }
        return out
    }

    func item(id: String) -> WorkItem? {
        for s in allSources {
            if let hit = snapshots[s.id]?.items.first(where: { $0.id == id }) ?? closed[s.id]?.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    var context: WorkItemFilter.Context { .init(viewers: viewers, mentioned: mentioned) }

    var openCount: Int { allSources.reduce(0) { $0 + (snapshots[$1.id]?.items.count ?? 0) } }
    var truncatedSources: [WorkItemSource] { allSources.filter { snapshots[$0.id]?.truncated == true } }

    func isUpdatedSinceViewed(_ item: WorkItem) -> Bool {
        snapshots[item.ref.source.id]?.isUpdatedSinceViewed(item) ?? false
    }

    /// Selecting an item clears its dot. Saved a beat later, so arrowing down a list is one write.
    func markViewed(_ item: WorkItem) {
        let sid = item.ref.source.id
        guard var snap = snapshots[sid] else { return }
        let seen = snap.lastViewed[item.ref.number]
        guard seen == nil || item.updatedAt > seen! else { return }
        snap.lastViewed[item.ref.number] = max(Date(), item.updatedAt)
        snapshots[sid] = snap
        pendingViewedSave?.cancel()
        pendingViewedSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.persist(Array(self.snapshots.values))
        }
    }

    // MARK: Visibility and refresh

    /// A Tasks screen came on screen in some window.
    func appeared() {
        visibleCount += 1
        if visibleCount == 1 { startPolling() }
        Task { await self.refreshIfStale() }
    }

    func disappeared() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 { pollTask?.cancel(); pollTask = nil }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh(resolve: false)
            }
        }
    }

    private func refreshIfStale() async {
        await loadFromDiskIfNeeded()
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshOnAppearAfter { return }
        await refresh(resolve: !resolvedThisLaunch)
    }

    /// ⌘R: re-resolve every project, then refetch everything.
    func refreshAll() async {
        await refresh(resolve: true)
    }

    /// Re-runs `gh auth status`, then refreshes; the unavailable view's Retry.
    func retry() async {
        availability = nil
        await refresh(resolve: true)
    }

    func refresh(resolve: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Projects come from the session scan; resolving before it lands would resolve nothing.
        await sessions.initialScan?.value
        await loadFromDiskIfNeeded()
        let available = await provider.availability()
        availability = available
        guard available.isReady else { return }

        let unresolved = projects.map(\.path).filter { resolve || resolutions[$0] == nil }
        if !unresolved.isEmpty {
            await resolveProjects(unresolved)
            resolvedThisLaunch = true
        }
        let sources = allSources
        for host in Set(sources.map(\.host)) where viewers[host] == nil {
            if let login = await provider.viewerLogin(host: host) { viewers[host] = login }
        }
        await fetchOpen(sources)
        await fetchMentions(hosts: Set(sources.map(\.host)))
        if closedRequested { await fetchClosed(sources) }
        lastRefresh = Date()
        generation &+= 1
    }

    private func loadFromDiskIfNeeded() async {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        let cache = self.cache
        let (resolved, snaps) = await Task.detached(priority: .userInitiated) { () -> ([String: WorkItemSourceResolution], [CachedWorkItems]) in
            let resolved = cache.loadResolutions()
            var seen = Set<String>()
            let sources = resolved.values.flatMap(\.sources).filter { seen.insert($0.id).inserted }
            return (resolved, sources.compactMap(cache.load))
        }.value
        for (path, r) in resolved where resolutions[path] == nil { resolutions[path] = r }
        for s in snaps where snapshots[s.source.id] == nil { snapshots[s.source.id] = s }
        // Overrides point at sources the automatic resolutions never named.
        let known = Set(snapshots.keys)
        let overridden = sessions.state.taskSources.values.flatMap { $0 }.filter { !known.contains($0.id) }
        if !overridden.isEmpty {
            let more = await Task.detached { overridden.compactMap(cache.load) }.value
            for s in more { snapshots[s.source.id] = s }
        }
    }

    private func resolveProjects(_ paths: [String]) async {
        let provider = self.provider
        await forEachLimited(paths) { path in
            await provider.resolveSources(projectPath: path)
        } each: { path, resolution in
            self.resolutions[path] = resolution
        }
        let snapshot = resolutions
        let cache = self.cache
        Task.detached { try? cache.saveResolutions(snapshot) }
    }

    private func fetchOpen(_ sources: [WorkItemSource]) async {
        let provider = self.provider, limit = Self.openLimit
        await forEachLimited(sources) { source -> Result<WorkItemPage, any Error> in
            do { return .success(try await provider.list(source, state: .open, limit: limit)) }
            catch { return .failure(error) }
        } before: { source in
            self.loadingSources.insert(source.id)
        } each: { source, result in
            self.loadingSources.remove(source.id)
            switch result {
            case .success(let page):
                let viewed = self.snapshots[source.id]?.lastViewed ?? [:]
                let live = Set(page.items.map(\.ref.number))
                let snap = CachedWorkItems(source: source, fetchedAt: Date(), items: page.items, truncated: page.truncated,
                                           lastViewed: viewed.filter { live.contains($0.key) })
                self.snapshots[source.id] = snap
                self.sourceErrors[source.id] = nil
                self.persist([snap])
            case .failure(let error):
                self.sourceErrors[source.id] = Self.describe(error)
                Self.log.warning("tasks \(source.id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    private func fetchMentions(hosts: Set<String>) async {
        var refs = Set<String>()
        var failed = false
        for host in hosts.sorted() {
            do { refs.formUnion(try await provider.mentioningViewer(host: host).map(\.id)) }
            catch { failed = true; Self.log.warning("tasks mentions \(host, privacy: .public): \(error, privacy: .public)") }
        }
        // A failed search keeps the last answer rather than emptying the view.
        if !failed || mentioned.isEmpty { mentioned = refs }
    }

    /// A project added while the screen is up resolves and loads now, not at the next poll.
    func projectsChanged() {
        guard visibleCount > 0, !isRefreshing, availability?.isReady == true else { return }
        let missing = projects.map(\.path).filter { resolutions[$0] == nil && sessions.state.taskSources[$0] == nil }
        guard !missing.isEmpty else { return }
        Task {
            await resolveProjects(missing)
            let new = missing.flatMap { self.sources(for: $0) }.filter { snapshots[$0.id] == nil }
            if !new.isEmpty { await fetchOpen(new) }
        }
    }

    /// The state filter now includes Closed somewhere: fetch them once, and keep them fresh from then on.
    func ensureClosed() {
        guard !closedRequested else { return }
        closedRequested = true
        Task {
            guard availability?.isReady == true else { return }
            await fetchClosed(allSources)
            generation &+= 1
        }
    }

    private func fetchClosed(_ sources: [WorkItemSource]) async {
        let provider = self.provider, limit = Self.closedLimit
        await forEachLimited(sources) { source -> Result<WorkItemPage, any Error> in
            do { return .success(try await provider.list(source, state: .closed, limit: limit)) }
            catch { return .failure(error) }
        } each: { source, result in
            if case .success(let page) = result { self.closed[source.id] = page.items }
        }
    }

    // MARK: Composer suggestions (ADR-117)

    /// A project's best few open tasks to start a session on, from what is loaded. Tasks that already
    /// have a session are left out.
    func suggestions(for projectPath: String, limit: Int = 3) -> [WorkItem] {
        let sources = sources(for: projectPath)
        guard !sources.isEmpty else { return [] }
        let linked = Set(sessions.state.workItemLinks.values.flatMap { $0.map(\.id) })
        return WorkItemSuggestions.rank(sources.flatMap { snapshots[$0.id]?.items ?? [] }, context: context, linked: linked, limit: limit)
    }

    /// A composer opened on a project. Draw from the cache at once, then bring *this project's*
    /// sources up to date if they are older than the poll interval. The rest of the roster is left to
    /// the Tasks screen.
    func composerAppeared(projectPath: String) async {
        guard !SessionStore.isChats(projectPath) else { return }
        await loadFromDiskIfNeeded()
        let available = await provider.availability()
        availability = available
        guard available.isReady, !isRefreshing else { return }
        if resolution(for: projectPath) == nil { await resolveProjects([projectPath]) }
        let sources = sources(for: projectPath)
        for host in Set(sources.map(\.host)) where viewers[host] == nil {
            if let login = await provider.viewerLogin(host: host) { viewers[host] = login }
        }
        let stale = sources.filter { source in
            guard !loadingSources.contains(source.id) else { return false }
            guard let fetched = snapshots[source.id]?.fetchedAt else { return true }
            return Date().timeIntervalSince(fetched) > Self.suggestionMaxAge
        }
        if !stale.isEmpty { await fetchOpen(stale) }
    }

    /// The poll interval: a composer never shows suggestions staler than an open Tasks screen would.
    static let suggestionMaxAge: TimeInterval = 300

    // MARK: Detail

    func loadDetail(_ ref: WorkItemRef) async {
        guard !detailLoading.contains(ref.id) else { return }
        detailLoading.insert(ref.id)
        defer { detailLoading.remove(ref.id) }
        do {
            details[ref.id] = try await provider.detail(ref)
            detailErrors[ref.id] = nil
        } catch {
            detailErrors[ref.id] = Self.describe(error)
        }
    }

    // MARK: Overrides (ADR-113)

    /// Nil = Automatic, [] = None, else these sources.
    func setSourceOverride(_ sources: [WorkItemSource]?, for projectPath: String) {
        sessions.update { s in s.taskSources[projectPath] = sources }
        Task {
            if sources == nil { await resolveProjects([projectPath]) }
            let missing = self.sources(for: projectPath).filter { snapshots[$0.id] == nil }
            if !missing.isEmpty, availability?.isReady == true { await fetchOpen(missing) }
        }
    }

    // MARK: Links (ADR-114)

    func sessionIds(for ref: WorkItemRef) -> [SessionID] {
        sessions.state.workItemLinks.filter { $0.value.contains { $0.id == ref.id } }.map(\.key)
            .sorted { (sessions.sessions[$0]?.activityDate ?? .distantPast) > (sessions.sessions[$1]?.activityDate ?? .distantPast) }
    }

    func linkedSessionCount(_ ref: WorkItemRef) -> Int {
        sessions.state.workItemLinks.values.reduce(0) { $0 + ($1.contains { $0.id == ref.id } ? 1 : 0) }
    }

    // MARK: Plumbing

    private func persist(_ snaps: [CachedWorkItems]) {
        let cache = self.cache
        Task.detached(priority: .utility) { for s in snaps { try? cache.save(s) } }
    }

    /// Runs `work` over `inputs` at most `maxConcurrent` at a time, delivering each result on the
    /// main actor as it lands, so one slow repository never holds the others back (ADR-113).
    private func forEachLimited<In: Sendable, Out: Sendable>(
        _ inputs: [In], _ work: @escaping @Sendable (In) async -> Out,
        before: (In) -> Void = { _ in }, each: (In, Out) -> Void
    ) async {
        var queue = inputs[...]
        await withTaskGroup(of: (In, Out).self) { group in
            for _ in 0..<Self.maxConcurrent {
                guard let next = queue.popFirst() else { break }
                before(next)
                group.addTask { (next, await work(next)) }
            }
            for await (input, output) in group {
                each(input, output)
                if let next = queue.popFirst() {
                    before(next)
                    group.addTask { (next, await work(next)) }
                }
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? GitHubError {
            let trimmed = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(e)" : trimmed
        }
        return "\(error)"
    }
}
