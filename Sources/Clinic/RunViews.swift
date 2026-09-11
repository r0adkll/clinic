import AppKit
import SwiftUI
import ClinicCore

// MARK: - Actions (ADR-122)

/// Where the Run commands point: the selected tab's checkout and the `run.json` that governs it.
struct RunContext {
    let tab: Tab?
    let checkout: String
    let projectPath: String
    let file: RunConfigurationFile?
    let fileError: String?
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

/// What a Run sheet is for: the editor, the IDE import, or ⌃⌘R's picker.
struct RunSheetRequest: Identifiable {
    enum Mode { case edit, importIDE, choose }
    let id = UUID()
    let mode: Mode
    let checkout: String
    let projectPath: String
    let tabId: UUID?
}

extension TabStore {
    func runContext(for tab: Tab? = nil) -> RunContext? {
        guard let tab = tab ?? selectedTab, let checkout = runs.checkout(for: tab) else { return nil }
        let state = runs.fileState(checkout: checkout, projectPath: tab.projectPath)
        return RunContext(tab: tab, checkout: checkout, projectPath: tab.projectPath, file: state?.file, fileError: state?.error)
    }

    /// The project root's context, for the sidebar's project menu: runs there happen in the root.
    func runContext(projectPath: String) -> RunContext? {
        guard !SessionStore.isChats(projectPath) else { return nil }
        let state = runs.fileState(checkout: projectPath, projectPath: projectPath)
        let tab = selectedTab.flatMap { runs.checkout(for: $0) == projectPath ? $0 : nil }
            ?? tabs.first { runs.checkout(for: $0) == projectPath }
        return RunContext(tab: tab, checkout: projectPath, projectPath: projectPath, file: state?.file, fileError: state?.error)
    }

    /// ⌘R: runs (or restarts) the selected configuration; with nothing configured, opens the picker.
    func runSelectedConfiguration() {
        guard let ctx = runContext() else { return }
        guard let config = runs.selectedConfiguration(projectPath: ctx.projectPath, in: ctx.file) else {
            showRunSheet(.choose, context: ctx); return
        }
        run(config, in: ctx)
    }

    /// Starts `config` in the context's checkout, with its pane in the context's tab — or, from the
    /// project menu with no tab in that checkout, in a new shell tab there, so the output has a home.
    func run(_ config: RunConfiguration, in ctx: RunContext, byUser: Bool = true) {
        let tab = ctx.tab ?? {
            newShell(in: ctx.checkout)
            return selectedTab
        }()
        runs.start(config, file: ctx.file, checkout: ctx.checkout, projectPath: ctx.projectPath, from: tab, byUser: byUser)
    }

    /// ⌃⌘.: stops the selected configuration's run (every member, for a compound).
    func stopSelectedRun() {
        for run in selectedRuns() where run.status.isRunning { runs.stop(run) }
    }

    /// The runs of the selected configuration in the selected tab's checkout.
    func selectedRuns() -> [Run] {
        guard let ctx = runContext(), let file = ctx.file,
              let config = runs.selectedConfiguration(projectPath: ctx.projectPath, in: file) else { return [] }
        return file.members(of: config).compactMap { runs.run(of: $0, checkout: ctx.checkout) }
    }

    var canRunSelected: Bool { runContext() != nil }
    var canStopSelectedRun: Bool { selectedRuns().contains { $0.status.isRunning } }

    /// *Set Up with Claude…*: the composer in the project root, worktree off, the prompt filled in (ADR-122).
    func setUpRunsWithClaude(projectPath: String) {
        startNewSession(projectPath: projectPath, prompt: RunPrompts.setUp, worktreeName: nil, workItem: nil)
    }

    func showRunSheet(_ mode: RunSheetRequest.Mode, context ctx: RunContext) {
        let request = RunSheetRequest(mode: mode, checkout: ctx.checkout, projectPath: ctx.projectPath, tabId: ctx.tab?.id)
        NotificationCenter.default.post(name: .clinicRunSheet, object: request)
    }

    func revealRunFile(_ ctx: RunContext) {
        let url = runs.fileURL(checkout: ctx.checkout, projectPath: ctx.projectPath)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: ctx.projectPath)) }
    }
}

extension Notification.Name {
    /// Object: a `RunSheetRequest` (ADR-122).
    static let clinicRunSheet = Notification.Name("com.r0adkll.clinic.runSheet")
}

// MARK: - Glyphs

/// A run's state mark, in ADR-096's vocabulary: motion for running, colour only for outcomes, never
/// the accent. With no run, the configuration's own symbol.
struct RunStatusGlyph: View {
    let run: Run?
    var idleSymbol = "play.fill"
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch run?.status {
            case .running?:
                SpinningArc(tint: AnyShapeStyle(.foreground), size: size).frame(width: size, height: size)
            case .succeeded?:
                Image(systemName: "checkmark").font(.system(size: size, weight: .bold)).foregroundStyle(.green)
            case .failed?:
                Image(systemName: "xmark").font(.system(size: size, weight: .bold)).foregroundStyle(.red)
            case .stopped?:
                Image(systemName: "circle").font(.system(size: size, weight: .medium)).foregroundStyle(.secondary)
            case nil:
                Image(systemName: idleSymbol).font(.system(size: size))
            }
        }
        .accessibilityLabel(RunText.status(run))
    }
}

@MainActor
enum RunText {
    static func status(_ run: Run?) -> String {
        switch run?.status {
        case .running?: "Running"
        case .succeeded(let d)?: "Succeeded in \(RunStatus.duration(d))"
        case .failed(let code, _)?: code.map { "Exit \($0)" } ?? "Failed"
        case .stopped?: "Stopped"
        case nil: "Not started"
        }
    }

    /// The menu's trailing fact for a configuration: its state, and how long ago it ended.
    static func menuSuffix(_ run: Run?) -> String? {
        switch run?.status {
        case .running?: return "running"
        case .succeeded?: return "succeeded"
        case .failed(let code, _)?: return code.map { "failed (exit \($0))" } ?? "failed"
        case .stopped?: return "stopped"
        case nil: return nil
        }
    }
}

/// A running clock, ticking once a second while the run lasts.
struct RunClock: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            Text(RunStatus.clock(ctx.date.timeIntervalSince(since))).monospacedDigit()
        }
    }
}

// MARK: - The Run pane

/// The pane's header (ADR-122, the shared 34 pt band of ADR-102): which run and where, how it is going,
/// and Restart / Stop.
struct RunPaneHeader: View {
    @Environment(TabStore.self) private var tabs
    let run: Run
    let tab: Tab

    var body: some View {
        PaneHeader {
            Image(systemName: run.config.uiSymbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(run.name).font(.callout.weight(.semibold)).lineLimit(1)
            if let branch = run.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .padding(.leading, 4)
                    .help(run.key.checkout)
            }
            if let device = run.device {
                Label(device.name, systemImage: device.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help(device.detail.map { "\(device.name) · \($0)" } ?? device.name)
            }
            Spacer(minLength: 8)
            status
            Divider().frame(height: 14).padding(.horizontal, 3)
            PaneIconButton(symbol: "arrow.clockwise", help: "Restart " + run.name) {
                tabs.runs.restart(run)
            }
            PaneIconButton(symbol: "stop.fill", help: "Stop " + run.name) { tabs.runs.stop(run) }
                .disabled(!run.status.isRunning)
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 5) {
            RunStatusGlyph(run: run, size: 11)
            switch run.status {
            case .running(let since): RunClock(since: since).foregroundStyle(.secondary)
            case .succeeded: Text(RunText.status(run)).foregroundStyle(.green)
            case .failed: Text(RunText.status(run)).foregroundStyle(.red)
            case .stopped: Text("Stopped").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}

/// Under a failed run's output: what happened, then Restart and *Fix with Claude* (ADR-122).
struct RunFailureBar: View {
    @Environment(TabStore.self) private var tabs
    let run: Run
    let tab: Tab

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.red)
            Group {
                if case .failed(let code, let duration) = run.status {
                    Text(code.map { "Failed with exit code \($0)" } ?? "Failed")
                    + Text(" · " + RunStatus.duration(duration)).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
            Spacer(minLength: 8)
            Button { tabs.runs.restart(run) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            if tab.sessionId != nil {
                Button { tabs.runs.fixWithClaude(run, in: tab) } label: { Label("Fix with Claude", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!tabs.runs.canFix(run, in: tab))
                    .help(tabs.runs.canFix(run, in: tab)
                          ? "Send the command, its exit code and the last 200 lines of output to this session"
                          : "Claude is working; this becomes available when the session is back at its prompt")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red.opacity(0.10))
        .overlay(alignment: .top) { Rectangle().fill(Color.red.opacity(0.32)).frame(height: 1) }
    }
}

/// A run pane that is not holding the surface: another window has it, its output was let go, or it has
/// not run in this checkout yet.
struct RunPanePlaceholder: View {
    @Environment(TabStore.self) private var tabs
    let runKey: RunKey
    let tab: Tab

    var body: some View {
        let run = tabs.runs.run(forKey: runKey)
        VStack(spacing: 0) {
            if let run { RunPaneHeader(run: run, tab: tab) }
            VStack(spacing: 10) {
                if let run, let step = run.preparing {
                    // Getting a device ready (ADR-124): the terminal comes once it is.
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(.secondary)
                    Button("Cancel") { tabs.runs.stop(run) }
                } else if let run, let problem = run.problem, run.surface == nil {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    Text(problem).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                    Button("Try Again") { tabs.runs.restart(run) }
                } else if let run, run.surface != nil {
                    Text("Showing in another window").foregroundStyle(.secondary)
                    Button("Show Here") { tabs.runs.show(runKey, in: tab) }
                } else {
                    Text(run == nil ? "Not started" : "Its output was closed").foregroundStyle(.secondary)
                    Button(run == nil ? "Run" : "Run Again") { runAgain() }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func runAgain() {
        guard let ctx = tabs.runContext(for: tab) else { return }
        let config = ctx.file?.configuration(runKey.configId) ?? tabs.runs.run(forKey: runKey)?.config
        if let config { tabs.run(config, in: ctx) }
    }
}

// MARK: - Toolbar (ADR-122, option A)

/// The named pill: the state mark, the configuration ⌘R runs, its clock while it runs, and a chevron
/// whose choices open in a popover (ADR-123); ■ beside it while that configuration is running.
///
/// The label is a plain button's, not a `Menu`'s: a toolbar menu's label is flattened to a template
/// image and drops its sibling views (ADR-078), which would lose the name and the clock.
struct RunToolbarControl: View {
    @Environment(TabStore.self) private var tabs
    @Environment(KeyBindings.self) private var bindings
    let tab: Tab

    var body: some View {
        if let checkout = tabs.runs.checkout(for: tab) {
            content(checkout: checkout)
                .task(id: checkout) { tabs.runs.ensureLoaded(checkout: checkout, projectPath: tab.projectPath) }
        }
    }

    @ViewBuilder private func content(checkout: String) -> some View {
        let ctx = tabs.runContext(for: tab)
        let config = ctx.flatMap { tabs.runs.selectedConfiguration(projectPath: $0.projectPath, in: $0.file) }
        let members = config.flatMap { c in ctx?.file?.members(of: c) } ?? []
        let run = members.compactMap { tabs.runs.run(of: $0, checkout: checkout) }.first(where: \.status.isRunning)
            ?? config.flatMap { tabs.runs.run(of: $0, checkout: checkout) }
            ?? members.first.flatMap { tabs.runs.run(of: $0, checkout: checkout) }
        HStack(spacing: 6) {
            ToolbarSplitButton(help: help(config: config, run: run),
                               choicesHelp: "Choose what ⌘R runs, set up or edit configurations", smokeId: "run") {
                primary(ctx: ctx, config: config)
            } label: {
                HStack(spacing: 7) {
                    Group {
                        // The configuration's own icon stands where ▶ would (ADR-125), until a run
                        // has something to say: motion, ✓ or ✗ are status, and status wins.
                        if let config { RunStatusGlyph(run: run, idleSymbol: config.uiSymbol, size: 12) }
                        else { Image(systemName: "play.fill").foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 12))
                    .frame(width: 14)
                    Text(config?.name ?? "Run…")
                        .foregroundStyle(config == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if case .running(let since)? = run?.status {
                        RunClock(since: since).foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .padding(.trailing, config == nil ? 10 : 0)
                // A name needs room to stay put as runs come and go; *Run…* does not. With nothing
                // configured the pill is only as wide as it reads, so an unconfigured project is not
                // charged 196 pt of toolbar (ADR-126). No fixed width, so the word sizes itself.
                .frame(width: config == nil ? nil : 156, height: 28, alignment: .leading)
            } choices: {
                RunPopover(context: ctx)
            }
            .frame(width: config == nil ? nil : 196, height: 28)
            if run?.status.isRunning == true {
                Button { tabs.stopSelectedRun() } label: { Image(systemName: "stop.fill").font(.system(size: 11)) }
                    .help("Stop " + (config?.name ?? "") + bindings.hint(.stopRun))
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    private func primary(ctx: RunContext?, config: RunConfiguration?) {
        guard let ctx else { return }
        // Nothing configured yet: the pill's own click goes straight to the editor, where a
        // configuration gets written — the picker has nothing to pick from (ADR-126).
        if let config { tabs.run(config, in: ctx) } else { tabs.showRunSheet(.edit, context: ctx) }
    }

    private func help(config: RunConfiguration?, run: Run?) -> String {
        guard let config else { return "Set up run configurations for this project" }
        let verb = run?.status.isRunning == true ? "Restart " : "Run "
        return verb + config.name + (config.command.map { " — " + $0 } ?? "") + bindings.hint(.run)
    }
}

/// One line of the Run menu. The toolbar's popover and the menu bar's Run menu render the same list,
/// so the two can never offer different things (ADR-123).
struct RunMenuEntry: Identifiable {
    enum Kind {
        case note(String)
        case header(String)
        case divider
        /// A saved configuration: choosing it makes it what ⌘R runs.
        case configuration(RunConfiguration, selected: Bool, state: String?)
        case action(title: String, symbol: String?, subtitle: String?, enabled: Bool, perform: @MainActor () -> Void)
    }
    let id: String
    let kind: Kind
}

extension TabStore {
    func runMenuEntries(_ context: RunContext?) -> [RunMenuEntry] {
        guard let ctx = context else { return [.init(id: "none", kind: .note("Select a session or shell in a project to run it."))] }
        var out: [RunMenuEntry] = []
        let configs = ctx.file?.configurations ?? []
        let selected = runs.selectedConfiguration(projectPath: ctx.projectPath, in: ctx.file)
        let setUp: RunMenuEntry.Kind = .action(title: "Set Up with Claude…", symbol: "sparkles", subtitle: nil, enabled: true) {
            self.setUpRunsWithClaude(projectPath: ctx.projectPath)
        }
        if let error = ctx.fileError {
            out.append(.init(id: "error", kind: .note("run.json can’t be read: " + error)))
            out.append(.init(id: "reveal", kind: .action(title: "Reveal run.json", symbol: "doc", subtitle: nil, enabled: true) { self.revealRunFile(ctx) }))
        } else if configs.isEmpty {
            out.append(.init(id: "empty", kind: .note("\(ctx.projectName) has no run configurations yet.")))
            out.append(.init(id: "setup-first", kind: .action(title: "Set Up with Claude…", symbol: "sparkles",
                                                              subtitle: "Claude reads the build and writes .clinic/run.json", enabled: true) {
                self.setUpRunsWithClaude(projectPath: ctx.projectPath)
            }))
            out.append(.init(id: "add", kind: .action(title: "Add Configuration…", symbol: "plus", subtitle: nil, enabled: true) {
                self.showRunSheet(.edit, context: ctx)
            }))
        } else {
            for config in configs {
                out.append(.init(id: "c:" + config.id, kind: .configuration(config, selected: selected?.id == config.id,
                                                                             state: RunText.menuSuffix(runs.run(of: config, checkout: ctx.checkout)))))
            }
        }
        let suggestions = runs.suggestions(checkout: ctx.checkout, projectPath: ctx.projectPath)
        if !suggestions.isEmpty {
            out.append(.init(id: "detected", kind: .header("Detected")))
            for config in suggestions {
                out.append(.init(id: "d:" + config.id, kind: .action(title: config.name, symbol: config.uiSymbol, subtitle: config.command, enabled: true) {
                    self.run(config, in: ctx)
                }))
            }
        }
        if !configs.isEmpty || ctx.fileError != nil {
            out.append(.init(id: "div", kind: .divider))
            out.append(.init(id: "edit", kind: .action(title: "Edit Configurations…", symbol: nil, subtitle: nil, enabled: ctx.fileError == nil) {
                self.showRunSheet(.edit, context: ctx)
            }))
            out.append(.init(id: "setup", kind: setUp))
        }
        if let found = runs.importCounts[ctx.projectPath], found > 0 {
            out.append(.init(id: "import", kind: .action(title: "Import from IntelliJ / VS Code…", symbol: nil, subtitle: nil,
                                                         enabled: ctx.fileError == nil) { self.showRunSheet(.importIDE, context: ctx) }))
        }
        return out
    }
}

/// The toolbar pill's choices, in a popover with a caret (ADR-123).
struct RunPopover: View {
    @Environment(TabStore.self) private var tabs
    let context: RunContext?

    var body: some View {
        PopoverMenu(width: 340) {
            ForEach(tabs.runMenuEntries(context)) { entry in
                switch entry.kind {
                case .note(let text): PopoverMenuNote(text: text)
                case .header(let title): PopoverMenuDivider(); PopoverMenuHeader(title: title)
                case .divider: PopoverMenuDivider()
                case .configuration(let config, let selected, let state):
                    PopoverMenuRow(title: config.name, trailing: state, checked: selected) {
                        if let ctx = context { tabs.runs.select(config.id, projectPath: ctx.projectPath) }
                    } icon: { Image(systemName: config.uiSymbol) }
                case .action(let title, let symbol, let subtitle, let enabled, let perform):
                    PopoverMenuRow(title: title, subtitle: subtitle, checked: hasChecks ? false : nil, action: perform) {
                        if let symbol { Image(systemName: symbol) }
                    }
                    .disabled(!enabled)
                }
            }
        }
    }

    /// With configurations listed, every row keeps the check column so titles line up under them.
    private var hasChecks: Bool { !(context?.file?.configurations.isEmpty ?? true) }
}

/// The menu bar's rendering of the same entries (ADR-122, ADR-123).
struct RunMenuItems: View {
    @Environment(TabStore.self) private var tabs
    let context: RunContext?

    var body: some View {
        ForEach(tabs.runMenuEntries(context)) { entry in
            switch entry.kind {
            case .note(let text): Text(text)
            case .header(let title): Divider(); Text(title)
            case .divider: Divider()
            case .configuration(let config, let selected, let state):
                Toggle(isOn: Binding(get: { selected }, set: { on in
                    if on, let ctx = context { tabs.runs.select(config.id, projectPath: ctx.projectPath) }
                })) {
                    Label(config.name + (state.map { "  ·  " + $0 } ?? ""), systemImage: config.uiSymbol)
                }
            case .action(let title, let symbol, let subtitle, let enabled, let perform):
                Button { perform() } label: {
                    if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
                    if let subtitle { Text(subtitle) }
                }
                .disabled(!enabled)
            }
        }
    }
}

/// The sidebar project menu's *Run ▸* (ADR-122): the project's configurations, run in its root.
struct ProjectRunMenu: View {
    @Environment(TabStore.self) private var tabs
    let projectPath: String

    var body: some View {
        if let ctx = tabs.runContext(projectPath: projectPath), let file = ctx.file, !file.configurations.isEmpty {
            Menu("Run") {
                ForEach(file.configurations) { config in
                    Button { tabs.run(config, in: ctx) } label: { Label(config.name, systemImage: config.uiSymbol) }
                }
                Divider()
                Button("Edit Configurations…") { tabs.showRunSheet(.edit, context: ctx) }
            }
        } else if !SessionStore.isChats(projectPath) {
            Button("Set Up Run Configurations with Claude…") { tabs.setUpRunsWithClaude(projectPath: projectPath) }
        }
    }
}


/// The menu bar's Run menu (ADR-122): Run, Stop, Choose, then the same items as the toolbar's menu.
struct RunCommandItems: View {
    let tabs: TabStore
    let key: (ShortcutAction) -> KeyboardShortcut?

    var body: some View {
        let ctx = tabs.runContext()
        let config = ctx.flatMap { tabs.runs.selectedConfiguration(projectPath: $0.projectPath, in: $0.file) }
        Button(config.map { "Run \($0.name)" } ?? "Run") { tabs.runSelectedConfiguration() }
            .keyboardShortcut(key(.run)).disabled(ctx == nil)
        Button("Stop") { tabs.stopSelectedRun() }
            .keyboardShortcut(key(.stopRun)).disabled(!tabs.canStopSelectedRun)
        Button("Choose Configuration…") { if let ctx { tabs.showRunSheet(.choose, context: ctx) } }
            .keyboardShortcut(key(.chooseRunConfiguration)).disabled(ctx == nil)
        Divider()
        RunMenuItems(context: ctx).environment(tabs)
    }
}
