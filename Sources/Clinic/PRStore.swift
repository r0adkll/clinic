import AppKit
import Foundation
import Observation
import os
import ClinicCore

/// Cache and refresh of pull requests for open tabs (ADR-053, given its events and its cadence by
/// ADR-127).
///
/// Three things ask for a read, and this is the only place that decides whether one happens: the
/// clock (at the interval `PullRequestRefresh` picks for each PR), a push (an FSEvents watcher over
/// each open checkout's git directory), and the end of a turn (`TabStore` on the `Stop` hook). The
/// policy itself is pure and lives in `ClinicCore`; what is here is the timer, the watchers and the
/// `gh` calls.
@MainActor
@Observable
final class PRStore {
    /// One pull request pane that exists right now: which PR it shows, which checkout it belongs to,
    /// and whether it is the pane the user is actually looking at. The app answers this — the store
    /// never reaches into `TabStore`.
    struct OpenPR {
        let ref: PullRequestRef
        /// The session's working directory, used to find the repository whose refs to watch.
        let directory: String?
        /// This pane is the front pane of the selected tab of the active window.
        let isFront: Bool
        /// Whose session this pull request belongs to. A watch notification is addressed from it, so it
        /// obeys that session's mute and reveals it when clicked (ADR-033, ADR-128).
        let sessionId: SessionID?
    }

    /// Whether a read also re-fetches GitHub's rendering of the bodies. `.auto` lets
    /// `PullRequestRefresh` decide; `.force` is the ⟳ button, where the user asked for everything.
    enum HTMLPolicy { case auto, force }

    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "github")
    let service = GitHubService()
    private(set) var availability: GitHubService.Availability?
    private(set) var viewerLogin: String?
    private(set) var pullRequests: [String: PullRequest] = [:]   // by ref id (url)
    private(set) var diffs: [String: UnifiedDiff] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    /// GitHub's rendering of the bodies, kept per ref so a status-only read can re-apply it rather
    /// than blanking the timeline back to Markdown until a second round trip lands (ADR-127).
    private var renderedHTML: [String: PullRequest.RenderedHTML] = [:]
    private var htmlFetchedAt: [String: Date] = [:]
    /// The head commit each cached diff was fetched at, so a push invalidates the Files tab.
    private var diffHeads: [String: String] = [:]
    /// When a read was last attempted, successful or not, so a repository `gh` cannot read is retried
    /// on the slow cadence instead of on every tick.
    private var attemptedAt: [String: Date] = [:]
    /// Automatic reads in flight, by ref. Opening a pane asks twice — the footer chip's
    /// `ensureLoaded` and the page's own `attach` — and two concurrent reads would not only pay for
    /// `gh` twice but split a check transition between them, so neither sees it end (ADR-128).
    private var reads: [String: Task<Void, Never>] = [:]
    private var pollTask: Task<Void, Never>?
    private var bumpTasks: [String: Task<Void, Never>] = [:]
    /// One watcher per repository behind an open pane, keyed by its git common directory.
    private var watchers: [String: RefWatcher] = [:]
    /// Resolved git common directory per checkout; a nil value is a directory that is not a repo, so
    /// `git rev-parse` is not re-run for it every tick.
    private var commonDirs: [String: String?] = [:]
    private var activeObserver: (any NSObjectProtocol)?
    var openPRsProvider: (() -> [OpenPR])?
    /// Set by the app: where the watch list is persisted (ADR-128).
    weak var sessions: SessionStore?
    /// Set by the app to route through `TabStore.notify` (ADR-066), as the background agents do.
    var router: ((SessionID?, String, String, NotificationStore.Entry.Kind, PullRequestRef) -> Void)?
    /// Which session each open pull request belongs to, refreshed on every poll, so a verdict landing
    /// between polls still knows who to tell.
    private var sessionIds: [String: SessionID] = [:]

    func start() {
        Task { await refreshAvailability() }
        // Coming back to Clinic is a moment the reader expects the panel to be current: everything on
        // screen is re-read at once rather than waiting out the interval it backed off to.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.poll(staleAfter: PullRequestRefresh.staleOnReturn) }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let tick = self?.nextTick() else { return }
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled else { return }
                await self?.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        for task in bumpTasks.values { task.cancel() }
        bumpTasks.removeAll()
        for task in reads.values { task.cancel() }
        reads.removeAll()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    /// Re-runs `gh auth status`. The page's "Retry" calls this, so a `gh auth login` in another
    /// window is picked up without restarting Clinic.
    func refreshAvailability() async {
        availability = await service.availability()
        viewerLogin = availability?.isReady == true ? await service.viewerLogin() : nil
    }

    func pullRequest(for ref: PullRequestRef) -> PullRequest? { pullRequests[ref.id] }

    func mark(for ref: PullRequestRef) -> PullRequestMark? {
        pullRequests[ref.id].map { PullRequestMark(pr: $0, viewerLogin: viewerLogin) }
    }

    func aggregateMark(for refs: [PullRequestRef]) -> PullRequestMark? {
        PullRequestMark.aggregate(refs.compactMap { mark(for: $0) })
    }

    // MARK: Watching (ADR-128)

    /// The reader asked to be told how this pull request's checks end.
    func isWatched(_ ref: PullRequestRef) -> Bool {
        sessions?.state.watchedPullRequests.contains(ref.id) ?? false
    }

    /// Turns the watch on or off. Switching it on reads the pull request straight away — a watch that
    /// waits out an interval before its first look would miss a run that finishes in the meantime.
    func setWatched(_ ref: PullRequestRef, _ watched: Bool) {
        sessions?.update { state in
            if watched { state.watchedPullRequests.insert(ref.id) } else { state.watchedPullRequests.remove(ref.id) }
        }
        if watched { Task { await read(ref) } }
    }

    func ensureLoaded(_ refs: [PullRequestRef]) {
        for ref in refs where pullRequests[ref.id] == nil { Task { await read(ref) } }
    }

    /// One read at a time per pull request: a second caller joins the one already running instead of
    /// starting another. The ⟳ button and `perform` deliberately go straight to `refresh` — an
    /// explicit gesture should not be answered by someone else's in-flight read.
    private func read(_ ref: PullRequestRef) async {
        if let existing = reads[ref.id] { await existing.value; return }
        let task = Task { await refresh(ref) }
        reads[ref.id] = task
        await task.value
        reads[ref.id] = nil
    }

    // MARK: The clock

    /// How long to wait before looking at the clock again. Five seconds while any pane is open, so a
    /// fifteen-second cadence is actually fifteen seconds; half a minute when there is nothing to
    /// poll. A tick that finds nothing due costs no process.
    private func nextTick() -> Duration {
        (openPRsProvider?() ?? []).isEmpty ? .seconds(30) : .seconds(5)
    }

    /// One pass over the open panes: re-read whatever is due, and keep the ref watchers in step with
    /// which checkouts have a pane open.
    ///
    /// - Parameter staleAfter: for the pane on screen, overrides its interval with this age in
    ///   seconds. Used when the app becomes active, where the question is "is what I am looking at
    ///   stale?" rather than "is the timer up?" — panes behind it keep their own cadence, so
    ///   activating Clinic never fans out into a read per open pull request.
    private func poll(staleAfter: TimeInterval? = nil) async {
        let open = openPRsProvider?() ?? []
        await syncWatchers(open)
        guard availability?.isReady != false else { return }
        let appActive = NSApp.isActive
        let now = Date()
        for item in open { sessionIds[item.ref.id] = item.sessionId }
        for item in open where staleAfter == nil || item.isFront {
            let pr = pullRequests[item.ref.id]
            guard let interval = PullRequestRefresh.interval(for: pr, isFront: item.isFront, appActive: appActive,
                                                             isWatched: isWatched(item.ref)) else { continue }
            let due = item.isFront ? (staleAfter ?? interval.seconds) : interval.seconds
            if let pr {
                guard now.timeIntervalSince(pr.fetchedAt) >= due else { continue }
            } else if let last = attemptedAt[item.ref.id],
                      now.timeIntervalSince(last) < PullRequestRefresh.background.seconds {
                // Nothing cached and a read was tried recently: that read failed, so wait out the slow
                // cadence rather than re-running `gh` every tick.
                continue
            }
            await read(item.ref)
        }
    }

    /// A PR pane came to the front, or came back: fetch what is missing, re-read what went stale
    /// while the pane was away, and make sure its checkout's refs are watched (ADR-127).
    func attach(_ ref: PullRequestRef) async {
        await syncWatchers(openPRsProvider?() ?? [])
        let pr = pullRequests[ref.id]
        if pr == nil {
            if let last = attemptedAt[ref.id], Date().timeIntervalSince(last) < PullRequestRefresh.staleOnReturn { return }
            await read(ref)
        } else if let pr, !pr.isSettled, Date().timeIntervalSince(pr.fetchedAt) >= PullRequestRefresh.staleOnReturn {
            await read(ref)
        }
    }

    /// Something happened that probably changed these PRs — a push, or the end of a turn. Read now,
    /// and once more after GitHub has had time to create the new commit's check runs (ADR-127).
    func bump(_ refs: [PullRequestRef]) {
        guard availability?.isReady != false else { return }
        for ref in refs where !(pullRequests[ref.id]?.isSettled ?? false) {
            bumpTasks[ref.id]?.cancel()
            bumpTasks[ref.id] = Task { [weak self] in
                await self?.read(ref)
                try? await Task.sleep(for: PullRequestRefresh.pushSettle)
                guard !Task.isCancelled else { return }
                await self?.read(ref)
            }
        }
    }

    // MARK: Reads

    func refresh(_ ref: PullRequestRef, html policy: HTMLPolicy = .auto) async {
        guard availability?.isReady != false else { return }
        loading.insert(ref.id); defer { loading.remove(ref.id) }
        attemptedAt[ref.id] = Date()
        do {
            var pr = try await service.pullRequest(ref)
            let cached = pullRequests[ref.id]
            // Re-apply the rendering already in hand *before* the PR reaches the screen: a poll over a
            // running build must not flash every body back to its Markdown source (ADR-127).
            if let html = renderedHTML[ref.id] { pr = pr.applying(html) }
            pullRequests[ref.id] = pr
            errors[ref.id] = nil
            announceChecks(ref, previous: cached, fresh: pr)
            reloadDiffIfHeadMoved(ref, pr)
            let html = policy == .force || PullRequestRefresh.needsRenderedHTML(fresh: pr, cached: cached,
                                                                                htmlFetchedAt: htmlFetchedAt[ref.id])
            // What ADR-127's cadence actually did, for `log stream` (ADR-038): which PR, what state it
            // is in, and whether this read paid for the rendering as well.
            Self.log.debug("pr read \(ref.url.absoluteString, privacy: .public) awaiting=\(pr.isAwaitingResult) html=\(html)")
            if html { await loadRenderedHTML(ref) }
        } catch {
            errors[ref.id] = "\(error)"
            Self.log.warning("pr \(ref.url.absoluteString, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// GitHub's own rendering of the body and comments (ADR-090), folded into the PR already on
    /// screen. Deliberately a second, non-fatal call: the panel is fully usable without it — bodies
    /// fall back to the Markdown source — so a GraphQL failure must not blank a PR that loaded fine.
    ///
    /// The result is kept so the next status-only read can re-apply it (ADR-127); it is re-fetched
    /// when a body changes or when the image URLs GitHub signs into it approach their five-minute
    /// expiry, rather than on every read as it once was.
    func loadRenderedHTML(_ ref: PullRequestRef) async {
        guard pullRequests[ref.id] != nil else { return }
        do {
            let html = try await service.renderedHTML(ref)
            renderedHTML[ref.id] = html
            htmlFetchedAt[ref.id] = Date()
            guard let pr = pullRequests[ref.id] else { return }
            pullRequests[ref.id] = pr.applying(html)
        } catch {
            Self.log.warning("pr html \(ref.url.absoluteString, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// The head commit the cached diff was read at; the Files tab keys its tree on it so a reload
    /// after a push rebuilds even when the same files changed (ADR-127).
    func diffHead(for ref: PullRequestRef) -> String? { diffHeads[ref.id] }

    func loadDiff(_ ref: PullRequestRef) async {
        do {
            diffs[ref.id] = try await service.diff(ref)
            diffHeads[ref.id] = pullRequests[ref.id]?.headRefOid
            errors[ref.id] = nil
        } catch {
            errors[ref.id] = "\(error)"
        }
    }

    /// Tells the reader how a watched run of checks ended (ADR-128), and stops watching a pull request
    /// that has been merged or closed — there is nothing left for it to report.
    ///
    /// `PullRequestWatch.completion` decides whether this read is news at all; the rules that keep a
    /// relaunch from replaying last week's green build live there, where they are tested.
    private func announceChecks(_ ref: PullRequestRef, previous: PullRequest?, fresh: PullRequest) {
        guard isWatched(ref) else { return }
        if fresh.isSettled { setWatched(ref, false); return }
        guard let verdict = PullRequestWatch.completion(previous: previous, fresh: fresh) else { return }
        let body = PullRequestWatch.sentence(verdict, host: ref.codeHost, number: ref.number)
        Self.log.info("pr watch \(ref.url.absoluteString, privacy: .public): \(body, privacy: .public)")
        router?(sessionIds[ref.id], fresh.title, body, .checks(passed: !verdict.isFailure), ref)
    }

    /// A push moves the head commit, which makes the diff the Files tab cached a diff of an older
    /// pull request than the one on screen. Re-read it in place — the tab keeps showing the old files
    /// until the new ones land, rather than falling back to a spinner (ADR-127).
    private func reloadDiffIfHeadMoved(_ ref: PullRequestRef, _ pr: PullRequest) {
        guard let head = pr.headRefOid, diffs[ref.id] != nil, diffHeads[ref.id] != head else { return }
        Task { await loadDiff(ref) }
    }

    func perform(_ ref: PullRequestRef, _ op: @escaping @Sendable (GitHubService) async throws -> Void) async {
        do { try await op(service); errors[ref.id] = nil } catch { errors[ref.id] = "\(error)" }
        await refresh(ref)
    }

    var mergeMethod: GitHubService.MergeMethod {
        GitHubService.MergeMethod(rawValue: UserDefaults.standard.string(forKey: "ClinicMergeMethod") ?? "squash") ?? .squash
    }

    // MARK: Watching for pushes

    /// An FSEvents stream over one repository's git directory, and the refs it speaks for.
    private final class RefWatcher {
        let watcher: FSEventsWatcher
        var refs: [PullRequestRef]
        var task: Task<Void, Never>?

        init(watcher: FSEventsWatcher, refs: [PullRequestRef]) { self.watcher = watcher; self.refs = refs }

        func stop() { task?.cancel(); task = nil; watcher.stop() }
    }

    /// One watcher per repository behind an open pane, over its git directory only.
    ///
    /// The git directory rather than the working tree: a push shows up there as a write under
    /// `refs/remotes/`, and watching it keeps every source-file save the agent makes out of the
    /// stream. It catches the agent's push mid-turn and the one the user makes in the shell alike.
    private func syncWatchers(_ open: [OpenPR]) async {
        var wanted: [String: [PullRequestRef]] = [:]
        for item in open {
            guard let directory = item.directory else { continue }
            if commonDirs[directory] == nil {
                commonDirs[directory] = await GitRepository.commonDirectory(from: directory)
            }
            guard let common = commonDirs[directory] ?? nil else { continue }
            wanted[common, default: []].append(item.ref)
        }
        for (path, watcher) in watchers where wanted[path] == nil {
            watcher.stop()
            watchers[path] = nil
        }
        for (path, refs) in wanted {
            if let existing = watchers[path] { existing.refs = refs; continue }
            let watcher = FSEventsWatcher(paths: [path], latency: 0.5)
            let holder = RefWatcher(watcher: watcher, refs: refs)
            watchers[path] = holder
            watcher.start()
            holder.task = Task { [weak self] in
                for await changed in watcher.changes {
                    guard changed.contains(where: PullRequestRefresh.isRefUpdate) else { continue }
                    guard let self, let refs = self.watchers[path]?.refs else { return }
                    Self.log.debug("refs moved in \(path, privacy: .public): bumping \(refs.count) pr(s)")
                    self.bump(refs)
                }
            }
        }
    }
}

extension Duration {
    /// Whole seconds, for comparing against an age in `TimeInterval`.
    var seconds: TimeInterval { TimeInterval(components.seconds) }
}
