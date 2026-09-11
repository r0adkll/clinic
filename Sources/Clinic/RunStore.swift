import AppKit
import Observation
import os
import ClinicCore
import GhosttyBridge

/// One configuration running in one checkout, as the child process of its own surface (ADR-122).
/// The run belongs to the checkout, not to a tab: closing the session that started it leaves it be.
@MainActor
@Observable
final class Run: Identifiable {
    let key: RunKey
    let projectPath: String
    /// The configuration as it was when this run last started; later edits apply on the next start.
    fileprivate(set) var config: RunConfiguration
    /// Nil once the output has been let go (finished, and no panel shows it any more).
    fileprivate(set) var surface: GhosttySurfaceView?
    fileprivate(set) var status: RunStatus
    /// Bumps on every start, so a panel hosting the old surface swaps in the new one.
    fileprivate(set) var generation = 0
    /// The tab whose panel hosts the surface. Any tab in the checkout may show the run; one at a time holds it.
    fileprivate(set) var hostTabId: UUID?
    /// The checkout's branch, for the pane header.
    fileprivate(set) var branch: String?
    /// Output kept when the surface is let go, so `read_run_output` still answers afterwards.
    fileprivate(set) var retainedOutput: String?
    /// Where this start's wrapper records the exit code (see `RunLaunch`).
    fileprivate var statusFile: String?
    /// What Clinic is doing before the command starts — "Starting Pixel 10 Pro XL…" (ADR-124). Nil
    /// once the terminal is up, or when no device is involved.
    fileprivate(set) var preparing: String?
    /// Why the run never started (no device, a boot that timed out). Shown in the pane.
    fileprivate(set) var problem: String?
    /// The device this start targets (ADR-124).
    fileprivate(set) var device: RunDevice?
    fileprivate var stoppedByUser = false
    fileprivate var restartWhenExited = false
    fileprivate var stopEscalation: Task<Void, Never>?
    fileprivate var prepareTask: Task<Void, Never>?

    nonisolated var id: RunKey { key }
    var name: String { config.name }
    var command: String { config.command ?? "" }

    fileprivate init(key: RunKey, projectPath: String, config: RunConfiguration) {
        self.key = key; self.projectPath = projectPath; self.config = config
        self.status = .running(since: Date())
    }

    /// The run's output so far: live from the surface, or what was kept when it closed.
    var output: String? { surface?.screenText ?? retainedOutput }
}

/// Every run, and every project's `run.json` (ADR-122).
@MainActor
@Observable
final class RunStore {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "runs")

    /// What a checkout's `run.json` said when last read. `error` is set when it would not parse; the file is
    /// then shown as broken and never overwritten.
    struct FileState: Equatable {
        var url: URL
        var file: RunConfigurationFile?
        var error: String?
        var modified: Date?
        var exists: Bool { file != nil || error != nil }
    }

    private(set) var runs: [RunKey: Run] = [:]
    private(set) var files: [String: FileState] = [:]
    /// Suggestions read from build files, per checkout; nil until the first detection finishes.
    private(set) var detected: [String: [RunConfiguration]] = [:]
    /// IDE run configurations found per project root, for the menu's *Import…* row.
    private(set) var importCounts: [String: Int] = [:]
    @ObservationIgnored private var detecting: Set<String> = []
    @ObservationIgnored private var poll: Timer?

    let sessions: SessionStore
    /// Android devices, emulators and iOS simulators runs target (ADR-124).
    let devices: RunDeviceStore
    @ObservationIgnored weak var tabs: TabStore?

    init(sessions: SessionStore) {
        self.sessions = sessions
        self.devices = RunDeviceStore(sessions: sessions)
    }

    // MARK: Checkouts and files

    /// The checkout a tab runs in; nil for Chats and replays, which have no project to run.
    func checkout(for tab: Tab) -> String? {
        guard tab.replay == nil, !SessionStore.isChats(tab.projectPath), !tab.projectPath.isEmpty else { return nil }
        return RunCheckout.root(forCwd: tab.pwd ?? tab.projectPath, projectPath: tab.projectPath)
    }

    func fileURL(checkout: String, projectPath: String) -> URL {
        RunCheckout.fileURL(checkout: checkout, projectPath: projectPath)
    }

    /// The parsed file for a checkout, as last read; nil until `ensureLoaded` has run for it.
    func fileState(checkout: String, projectPath: String) -> FileState? {
        files[fileURL(checkout: checkout, projectPath: projectPath).path]
    }

    func file(checkout: String, projectPath: String) -> RunConfigurationFile? {
        fileState(checkout: checkout, projectPath: projectPath)?.file
    }

    /// Reads the checkout's file if it has not been read, and starts detection. Views call this from
    /// `.task`, never from `body`, so reading never mutates state mid-render.
    func ensureLoaded(checkout: String, projectPath: String) {
        let url = fileURL(checkout: checkout, projectPath: projectPath)
        if files[url.path] == nil { reload(url) }
        startPolling()
        ensureDetected(checkout: checkout, projectPath: projectPath)
    }

    /// Reads each project root's file without starting detection, so the sidebar's project menu can list
    /// configurations the moment it opens.
    func preload(projectPaths: [String]) {
        for path in projectPaths where !SessionStore.isChats(path) {
            let url = fileURL(checkout: path, projectPath: path)
            if files[url.path] == nil { reload(url) }
        }
        startPolling()
    }

    private func reload(_ url: URL) {
        let modified = Self.modificationDate(url)
        var state = FileState(url: url, modified: modified)
        do { state.file = try RunConfigurationFile.load(from: url) }
        catch { state.error = "\(error)" }
        if files[url.path] != state { files[url.path] = state }
    }

    /// `run.json` changes under Clinic — Claude writes it, a branch switch replaces it — so every file
    /// Clinic has read is re-read when its modification date moves. A stat per file every two seconds
    /// while Clinic is active; cheaper and simpler than a vnode watcher per directory, and it sees a
    /// `.clinic/` folder appear where a watcher on it could not.
    private func startPolling() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFiles() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func pollFiles() {
        guard NSApp.isActive else { return }
        for (path, state) in files where Self.modificationDate(URL(fileURLWithPath: path)) != state.modified {
            reload(state.url)
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Writes the editor's file to the path that governs the checkout, and trusts every command in it:
    /// saving is one of the two ways a command becomes Claude-runnable (ADR-122).
    func save(_ file: RunConfigurationFile, checkout: String, projectPath: String) throws {
        let url = fileURL(checkout: checkout, projectPath: projectPath)
        try file.write(to: url)
        reload(url)
        sessions.update { s in
            for config in file.configurations where !config.isCompound && config.isRunnable {
                s.trustedRunCommands.insert(RunTrust.fingerprint(config))
            }
        }
    }

    // MARK: Detection and import

    private func ensureDetected(checkout: String, projectPath: String) {
        guard detected[checkout] == nil, !detecting.contains(checkout) else { return }
        detecting.insert(checkout)
        let root = URL(fileURLWithPath: checkout)
        let projectRoot = URL(fileURLWithPath: projectPath)
        Task.detached(priority: .utility) {
            let fromFiles = RunDetector.detect(in: root)
            let imports = RunImporter.candidates(in: projectRoot).count
            await MainActor.run { [weak self] in
                self?.detected[checkout] = fromFiles
                self?.importCounts[projectPath] = imports
            }
            let xcode = await RunDetector.detectXcode(in: root)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !xcode.isEmpty { self.detected[checkout] = xcode + (self.detected[checkout] ?? []) }
                self.detecting.remove(checkout)
            }
        }
    }

    /// Detected configurations the file does not already run, by command.
    func suggestions(checkout: String, projectPath: String) -> [RunConfiguration] {
        let saved = Set((file(checkout: checkout, projectPath: projectPath)?.configurations ?? []).compactMap(\.command))
        return (detected[checkout] ?? []).filter { !saved.contains($0.command ?? "") }
    }

    // MARK: Selection

    /// What ⌘R runs in a project: the user's pick, then the file's `default`, then its first configuration.
    func selectedConfiguration(projectPath: String, in file: RunConfigurationFile?) -> RunConfiguration? {
        guard let file, !file.configurations.isEmpty else { return nil }
        let id = sessions.state.runSelectionByProject[projectPath] ?? file.defaultId
        return id.flatMap(file.configuration) ?? file.configurations.first
    }

    func select(_ id: String, projectPath: String) {
        guard sessions.state.runSelectionByProject[projectPath] != id else { return }
        sessions.update { $0.runSelectionByProject[projectPath] = id }
    }

    // MARK: Trust (ADR-122)

    /// True when every command the configuration would start has been run or saved by the user.
    func isTrusted(_ config: RunConfiguration, in file: RunConfigurationFile?) -> Bool {
        let prints = file.map { RunTrust.fingerprints(for: config, in: $0) } ?? [RunTrust.fingerprint(config)]
        return !prints.isEmpty && prints.allSatisfy(sessions.state.trustedRunCommands.contains)
    }

    private func trust(_ configs: [RunConfiguration]) {
        let prints = configs.map(RunTrust.fingerprint)
        guard !Set(prints).isSubset(of: sessions.state.trustedRunCommands) else { return }
        sessions.update { $0.trustedRunCommands.formUnion(prints) }
    }

    // MARK: Running

    func run(forKey key: RunKey) -> Run? { runs[key] }

    /// Runs in a checkout, newest first — the menu, the panel's `+` menu and the MCP tools read these.
    func runs(inCheckout checkout: String) -> [Run] {
        runs.values.filter { $0.key.checkout == checkout }.sorted { $0.generation > $1.generation }
    }

    /// The run of a configuration in a checkout, if it has run this launch.
    func run(of config: RunConfiguration, checkout: String) -> Run? { runs[RunKey(checkout: checkout, configId: config.id)] }

    var runningCount: Int { runs.values.filter(\.status.isRunning).count }

    /// Starts a configuration (restarting it when it is already going) in `checkout`. A compound starts
    /// each member. `byUser` marks a run from the UI, which trusts its commands; `tab` is where its pane
    /// opens, fronted when `front`.
    @discardableResult
    func start(_ config: RunConfiguration, file: RunConfigurationFile?, checkout: String, projectPath: String,
               from tab: Tab?, byUser: Bool, front: Bool = true) -> [Run] {
        let members = file?.members(of: config) ?? (config.isCompound ? [] : [config])
        if byUser { trust(members) }
        var started: [Run] = []
        for (i, member) in members.enumerated() where member.isRunnable {
            guard let run = start(member, checkout: checkout, projectPath: projectPath) else { continue }
            started.append(run)
            if let tab { tabs?.openRunPane(run.key, in: tab, front: front && i == 0) }
        }
        return started
    }

    private func start(_ config: RunConfiguration, checkout: String, projectPath: String) -> Run? {
        let key = RunKey(checkout: checkout, configId: config.id)
        if let existing = runs[key] {
            existing.config = config
            if existing.status.isRunning {
                existing.restartWhenExited = true
                stop(existing)
            } else {
                begin(existing)
            }
            return existing
        }
        let run = Run(key: key, projectPath: projectPath, config: config)
        runs[key] = run
        guard begin(run) else { runs[key] = nil; return nil }
        return run
    }

    /// Starts the command, first getting its device ready when it names one (ADR-124). False when it
    /// could not start at all; a device step that fails later leaves the run failed with a `problem`.
    @discardableResult
    private func begin(_ run: Run) -> Bool {
        guard let platform = run.config.device else { return launch(run) }
        let since = Date()
        run.status = .running(since: since)
        run.problem = nil
        run.stoppedByUser = false
        run.restartWhenExited = false
        run.preparing = "Finding \(platform == .android ? "an Android device" : "a simulator")…"
        run.prepareTask?.cancel()
        run.prepareTask = Task { [weak self, weak run] in
            guard let self, let run else { return }
            do {
                let (device, env) = try await self.devices.prepare(platform, projectPath: run.projectPath) { message in
                    Task { @MainActor in if run.prepareTask != nil { run.preparing = message } }
                }
                try Task.checkCancellation()
                run.device = device
                run.preparing = nil
                run.prepareTask = nil
                if !self.launch(run, extraEnvironment: env) {
                    self.failBeforeStart(run, since: since, problem: "The terminal for \(run.name) could not be created.")
                }
            } catch is CancellationError {
                return
            } catch {
                self.failBeforeStart(run, since: since, problem: "\(error)")
            }
        }
        return true
    }

    private func failBeforeStart(_ run: Run, since: Date, problem: String) {
        run.preparing = nil
        run.prepareTask = nil
        run.problem = problem
        run.status = .failed(exitCode: nil, duration: Date().timeIntervalSince(since))
        announce(run)
    }

    @discardableResult
    private func launch(_ run: Run, extraEnvironment: [String: String] = [:]) -> Bool {
        guard let runtime = tabs?.runtime, let command = run.config.command else { return false }
        let directory = RunCheckout.workingDirectory(for: run.config, checkout: run.key.checkout)
        guard FileManager.default.fileExists(atPath: directory) else {
            tabs?.lastSurfaceError = "\(run.name) runs in \(TabFooter.abbreviate(directory)), which does not exist."
            return false
        }
        let statusFile = Self.statusDirectory.appendingPathComponent(UUID().uuidString + ".status").path
        try? FileManager.default.createDirectory(at: Self.statusDirectory, withIntermediateDirectories: true)
        var options = GhosttySurfaceOptions()
        options.workingDirectory = directory
        options.command = RunLaunch.surfaceCommand(shell: RunLaunch.userShell, command: command, statusFile: statusFile)
        options.environment = RunLaunch.environment(for: run.config).merging(extraEnvironment) { _, device in device }
        do {
            let surface = try GhosttySurfaceView(runtime: runtime, options: options)
            surface.delegate = self
            let old = run.surface
            run.surface = surface
            if let previous = run.statusFile { try? FileManager.default.removeItem(atPath: previous) }
            run.statusFile = statusFile
            run.retainedOutput = nil
            run.problem = nil
            if run.config.device == nil { run.device = nil }
            run.status = .running(since: Date())
            run.stoppedByUser = false
            run.restartWhenExited = false
            run.stopEscalation?.cancel()
            run.generation += 1
            old?.free()
            // A run that waited for a device had its pane opened before there was a surface to hold.
            if run.hostTabId == nil, let tabs,
               let fronting = tabs.tabs.first(where: { tabs.window(of: $0).selectedTabId == $0.id && $0.panel.isFront(.run(run.key)) }) {
                run.hostTabId = fronting.id
            }
            syncOcclusion()
            Self.log.info("started \(run.key.description, privacy: .public)")
        } catch {
            Self.log.error("run surface failed: \(error, privacy: .public)")
            tabs?.lastSurfaceError = "\(error)"
            return false
        }
        let checkout = run.key.checkout
        Task { [weak run] in
            let branch = await GitInfo.branch(at: checkout)
            run?.branch = branch
        }
        return true
    }

    /// Ctrl-C, as a person at the terminal would; if the job has not gone in five seconds, SIGTERM to
    /// the pty's foreground process group, then SIGKILL. The surface stays, so the output does too.
    func stop(_ run: Run) {
        if let task = run.prepareTask, run.status.isRunning {
            // Still getting a device ready: stop waiting (a boot already under way carries on, as
            // Android Studio's does), then start over if this was a restart.
            task.cancel()
            run.prepareTask = nil
            run.preparing = nil
            if case .running(let since) = run.status { run.status = .stopped(duration: Date().timeIntervalSince(since)) }
            if run.restartWhenExited { begin(run) }
            return
        }
        guard run.status.isRunning, let surface = run.surface else { return }
        run.stoppedByUser = true
        surface.sendInterrupt()
        run.stopEscalation?.cancel()
        run.stopEscalation = Task { [weak run] in
            try? await Task.sleep(for: .seconds(5))
            guard let run, run.status.isRunning, !Task.isCancelled else { return }
            Self.signal(run, SIGTERM)
            try? await Task.sleep(for: .seconds(3))
            guard run.status.isRunning, !Task.isCancelled else { return }
            if !Self.signal(run, SIGKILL) { run.surface?.free() }
        }
    }

    @discardableResult
    private static func signal(_ run: Run, _ sig: Int32) -> Bool {
        guard let group = run.surface?.foregroundPID, group > 1 else { return false }
        return killpg(group, sig) == 0
    }

    func restart(_ run: Run) {
        if run.status.isRunning { run.restartWhenExited = true; stop(run) } else { begin(run) }
    }

    /// Exit codes, one small file per start, removed once read.
    private static let statusDirectory = ClinicPaths.appSupport.appendingPathComponent("Clinic/runs", isDirectory: true)

    /// `reported` is libghostty's code, which on macOS is `login`'s and always 0; the wrapper's file is
    /// the real one. No file means the wrapper died before writing it: the code is unknown.
    private func finished(_ run: Run, reported: Int32?) {
        guard case .running(let since) = run.status else { return }
        run.stopEscalation?.cancel()
        let exitCode = run.statusFile.flatMap(RunLaunch.recordedExitCode(at:))
        if let file = run.statusFile { try? FileManager.default.removeItem(atPath: file); run.statusFile = nil }
        let duration = Date().timeIntervalSince(since)
        run.status = .finished(exitCode: exitCode, stoppedByUser: run.stoppedByUser, duration: duration)
        Self.log.info("finished \(run.key.description, privacy: .public) with \(exitCode.map(String.init) ?? "?", privacy: .public)")
        if run.restartWhenExited { begin(run); return }
        announce(run)
        disposeIfUnseen(run)
    }

    /// ADR-122: a run that ends while its pane is not on screen posts a notification. A stop the user
    /// asked for is not news.
    private func announce(_ run: Run) {
        guard let tabs else { return }
        let body: String
        let kind: NotificationStore.Entry.Kind
        switch run.status {
        case .succeeded(let d): body = "Succeeded in \(RunStatus.duration(d))"; kind = .finished
        case .failed(let code, _): body = run.problem ?? ("Failed" + (code.map { " (exit \($0))" } ?? "")); kind = .error
        default: return
        }
        if isOnScreen(run) { return }
        tabs.notify(nil, sessionId: nil, title: run.name, body: body, kind: kind)
    }

    private func isOnScreen(_ run: Run) -> Bool {
        guard let tabs, let host = run.hostTabId, let tab = tabs.tabs.first(where: { $0.id == host }) else { return false }
        return tabs.isFrontAndSelected(tab) && tab.panel.isFront(.run(run.key))
    }

    // MARK: Hosting (ADR-122)

    /// The tab now fronting a run takes its surface. Called when a tab is selected, a pane is fronted or
    /// the panel is shown — user actions only, never from a view update.
    func claim(for tab: Tab) {
        guard let tabs, tabs.window(of: tab).selectedTabId == tab.id, tab.panel.isVisible,
              case .run(let key)? = tab.panel.selected?.kind, let run = runs[key], run.surface != nil else { return }
        if run.hostTabId != tab.id { run.hostTabId = tab.id }
        syncOcclusion()
    }

    /// *Show Here*: take a run that another window is showing.
    func show(_ key: RunKey, in tab: Tab) {
        tabs?.openRunPane(key, in: tab, front: true)
    }

    /// Every run surface renders only while its host shows it.
    func syncOcclusion() {
        guard let tabs else { return }
        for run in runs.values {
            guard let surface = run.surface else { continue }
            let host = run.hostTabId.flatMap { id in tabs.tabs.first { $0.id == id } }
            let visible = host.map { tabs.window(of: $0).selectedTabId == $0.id && $0.panel.isFront(.run(run.key)) } ?? false
            surface.isOccluded = !visible
        }
    }

    /// A pane showing `key` closed in `tab`: it gives up the surface, and a finished run nobody shows lets
    /// its output go.
    func paneClosed(_ key: RunKey, in tab: Tab) {
        guard let run = runs[key] else { return }
        if run.hostTabId == tab.id { run.hostTabId = nil }
        disposeIfUnseen(run, ignoring: tab)
        syncOcclusion()
    }

    /// A tab closed: the same, for every run pane it had.
    func tabClosed(_ tab: Tab) {
        for pane in tab.panel.panes { if case .run(let key) = pane.kind { paneClosed(key, in: tab) } }
    }

    private func disposeIfUnseen(_ run: Run, ignoring closing: Tab? = nil) {
        guard !run.status.isRunning, let surface = run.surface, let tabs else { return }
        let shown = tabs.tabs.contains { $0.id != closing?.id && $0.panel.isOpen(.run(run.key)) }
        guard !shown else { return }
        run.retainedOutput = surface.screenText
        run.surface = nil
        run.hostTabId = nil
        surface.free()
    }

    /// Frees every surface; the app is quitting.
    func tearDown() {
        for run in runs.values { run.stopEscalation?.cancel(); run.prepareTask?.cancel(); run.surface?.free(); run.surface = nil }
        try? FileManager.default.removeItem(at: Self.statusDirectory)
    }

    // MARK: Sessions (ADR-122)

    /// *Fix with Claude*: the failed command, its code and its output's tail, pasted as the next prompt.
    func fixWithClaude(_ run: Run, in tab: Tab) {
        guard canFix(run, in: tab), case .failed(let code, _) = run.status else { return }
        let prompt = RunPrompts.fix(name: run.name, command: run.command, exitCode: code, output: run.output ?? "")
        tab.surface.sendPastedLine(prompt)
        tabs?.select(tab)
    }

    func canFix(_ run: Run, in tab: Tab) -> Bool {
        run.status.isFailure && tab.sessionId != nil && tab.state == .idle && !tab.childExited
    }

    /// A session's turn ended (`Stop`). Re-runs, without fronting anything, each configuration marked
    /// `rerunAfterTurn` that has already run in the session's checkout, when the turn changed files.
    func turnEnded(in tab: Tab, snapshots: SnapshotService) {
        guard let checkout = checkout(for: tab), let file = file(checkout: checkout, projectPath: tab.projectPath) else { return }
        let due = file.configurations.filter { $0.reruns && !$0.isCompound && runs[RunKey(checkout: checkout, configId: $0.id)] != nil }
        guard !due.isEmpty, let session = tab.sessionId else { return }
        Task { [weak self] in
            guard await Self.turnChangedFiles(session: session, snapshots: snapshots) else { return }
            guard let self else { return }
            for config in due where self.isTrusted(config, in: file) {
                self.start(config, file: file, checkout: checkout, projectPath: tab.projectPath, from: nil, byUser: false)
            }
        }
    }

    /// The turn's snapshot (ADR-080) says whether it changed anything; the pump seals it just after
    /// `Stop`, so wait briefly for that. No snapshot (not a repository) counts as changed.
    private static func turnChangedFiles(session: SessionID, snapshots: SnapshotService) async -> Bool {
        for _ in 0..<20 {
            if let root = snapshots.repoRoot(for: session) {
                let turns = await snapshots.snapshots(for: session, repoRoot: root).turns
                if let last = turns.last, !last.isInFlight { return !last.isEmpty }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// Resolves a configuration by id or name, case-insensitively, for the MCP tools.
    func configuration(named name: String, in file: RunConfigurationFile) -> RunConfiguration? {
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        return file.configurations.first { $0.id.lowercased() == needle }
            ?? file.configurations.first { $0.name.lowercased() == needle }
    }

    /// Hosting and state facts for `TerminalStack`'s render key: a restart or a change of host must
    /// re-install the panel's surface.
    func renderKey(for tab: Tab) -> String {
        tab.panel.panes.compactMap { pane -> String? in
            guard case .run(let key) = pane.kind, let run = runs[key] else { return nil }
            return "\(run.generation)\(run.hostTabId == tab.id)\(run.surface != nil)\(run.status.isFailure)\(run.preparing != nil)\(run.problem != nil)"
        }.joined(separator: ",")
    }
}

extension RunStore: GhosttySurfaceDelegate {
    private func run(for surface: GhosttySurfaceView) -> Run? { runs.values.first { $0.surface === surface } }

    func surface(_ surface: GhosttySurfaceView, didReceive action: GhosttyAction) -> Bool {
        switch action {
        case .openURL(let url, _): NSWorkspace.shared.open(url); return true
        // A run does not open tabs, rename itself or ring for attention; its end is what notifies.
        case .newTab, .newWindow, .newSplit, .ringBell, .setTitle, .pwd, .progressReport, .commandFinished, .mouseShape, .colorScheme: return true
        case .quit: return false
        case .unhandled: return false
        }
    }

    /// After the command exits a key press asks to close; the output stays until the pane closes.
    func surfaceRequestedClose(_ surface: GhosttySurfaceView, processAlive: Bool) {}

    func surfaceChildExited(_ surface: GhosttySurfaceView, exitCode: Int32?) {
        guard let run = run(for: surface) else { return }
        finished(run, reported: exitCode)
    }
}
