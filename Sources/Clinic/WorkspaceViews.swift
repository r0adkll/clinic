import AppKit
import SwiftUI
import ClinicCore

// MARK: - The main area's strip (ADR-212)

/// The main area's tab row: Claude pinned first, then the tabs the reader added beside it, a `+` that adds
/// here, and at the trailing end the openers, the zoom and the panel toggle that the footer and the
/// session tab bar used to carry (ADR-212, over ADR-049 and ADR-079).
struct MainTabStrip: View {
    @Environment(TabStore.self) private var tabs
    @Environment(KeyBindings.self) private var bindings
    let tab: Tab

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ClaudeTabItem(tab: tab, selected: tab.main.selectedId == nil)
                        ForEach(tab.main.panes) { pane in
                            MainTabItem(tab: tab, pane: pane, selected: pane.id == tab.main.selectedId)
                                .id(pane.id)
                        }
                        addMenu.padding(.leading, 4)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity)
                }
                // A chord or the right panel's move button can select a tab off the end of a long row.
                .onChange(of: tab.main.selectedId) {
                    guard let id = tab.main.selectedId else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Spacer(minLength: 8)
            if !tab.isReplay {
                WorkspaceOpeners(tab: tab)
                Divider().frame(height: 18).padding(.horizontal, 6)
                PaneIconButton(symbol: tab.panel.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: tab.panel.isZoomed ? "Shrink the panel back beside the session" + bindings.hint(.zoomPanel)
                                                        : "Expand the panel to fill the window" + bindings.hint(.zoomPanel),
                               isOn: tab.panel.isZoomed) { tabs.togglePanelZoom(tab) }
                PaneIconButton(symbol: "sidebar.right",
                               help: tab.panel.isVisible ? "Hide the right panel" + bindings.hint(.togglePanelVisibility) + ", or ⇧-click its tab bar"
                                                         : "Show the right panel" + bindings.hint(.togglePanelVisibility),
                               isOn: tab.panel.isVisible) { tabs.togglePanelVisibility(tab) }
                    .padding(.trailing, PaneMetrics.padding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Adds a view beside Claude, or jumps to one already open here.
    private var addMenu: some View {
        PaneIconMenu(symbol: "plus", help: "Open a view beside Claude") {
            let available = tabs.availablePanes(for: tab)
            if !available.isEmpty {
                Section("Add") {
                    ForEach(available, id: \.self) { kind in
                        Button { tabs.addPane(kind, in: tab, area: .main) } label: {
                            Label { Text(tab.isOpen(kind) ? "New " + kind.defaultTitle + " Tab" : tabs.paneTitle(kind, in: tab)) } icon: { kind.icon }
                        }
                    }
                }
            }
            if !tab.main.panes.isEmpty {
                Section("Open") {
                    Button { tabs.selectClaude(in: tab) } label: { Label("Claude", systemImage: "sparkle") }
                    ForEach(tab.main.panes) { pane in
                        Button { tabs.selectPane(pane, in: tab) } label: {
                            Label { Text(tabs.paneTitle(pane, in: tab)) } icon: { pane.kind.icon }
                        }
                    }
                }
            }
        }
    }
}

/// A main-area tab, drawn as a label over an accent underline when selected (direction B on the design
/// canvas, ADR-212). The row is as tall as the strip, so the whole height is the target.
private struct UnderlinedTab<Glyph: View, Trailing: View>: View {
    let title: String
    let selected: Bool
    let select: () -> Void
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            glyph.frame(width: 14)
            Text(title).font(.callout).lineLimit(1)
            trailing
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: 220)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background(hovering && !selected ? Color.primary.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(selected ? Color.accent : .clear).frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        // A tab to VoiceOver and to accessibility clients: its name, selected or not, and a press.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

/// The pinned Claude tab (ADR-212): the session's state glyph and *Claude*. It has no close button,
/// because closing it is closing the session, which the header's menu and ⌘W do through the close sheet.
struct ClaudeTabItem: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let selected: Bool

    private var title: String {
        if tab.isReplay { return "Replay" }
        return tab.sessionId == nil ? "Shell" : "Claude"
    }

    var body: some View {
        UnderlinedTab(title: title, selected: selected, select: { tabs.selectClaude(in: tab) }) {
            if tab.sessionId == nil { Image(systemName: "terminal").font(.system(size: 11)) }
            else { StateGlyph(tab: tab) }
        } trailing: { EmptyView() }
        .help(tab.sessionId == nil ? "The shell" : "The session")
        .contextMenu {
            Button("Close Session…") { tabs.close(tab) }
            Divider()
            MoveToWindowMenu(tab: tab)
        }
    }
}

/// A tab the reader added beside Claude: its glyph, its name and a close button that fades in, like the
/// panel's chips (ADR-104), and the same menu with *Move to Right Panel* (ADR-212).
struct MainTabItem: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let pane: PanelPane
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        UnderlinedTab(title: tabs.paneTitle(pane, in: tab), selected: selected, select: {
            if NSEvent.modifierFlags.contains(.shift) { tabs.closePane(pane, in: tab) } else { tabs.selectPane(pane, in: tab) }
        }) {
            PaneGlyph(tab: tab, pane: pane, compact: false)
        } trailing: {
            HStack(spacing: 0) {
                TabMoveButton(toRight: true) { tabs.movePane(pane, in: tab) }
                Button { tabs.closePane(pane, in: tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(tabs.paneTitle(pane, in: tab))")
                .help("Close this tab, or ⇧-click it")
            }
            .opacity(hovering || selected ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Move to Right Panel") { tabs.movePane(pane, in: tab) }
            Divider()
            Button("Close") { tabs.closePane(pane, in: tab) }
            Button("Close Others") { tabs.closeOtherPanes(pane, in: tab) }
                .disabled(tab.main.panes.count < 2)
        }
    }
}

/// A tab's own move button (ADR-212): the same pane, with its state, in the other area.
struct TabMoveButton: View {
    /// From the main area to the right panel, or back.
    let toRight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: toRight ? "arrow.right.to.line" : "arrow.left.to.line")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(toRight ? "Move to Right Panel" : "Move to Main Area")
        .help(toRight ? "Move this tab to the right panel" : "Move this tab beside Claude")
    }
}

/// A pane's glyph in a strip: a PR's service glyph with its state, a run's status, else its symbol.
struct PaneGlyph: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let pane: PanelPane
    let compact: Bool

    var body: some View {
        if case .pr(let ref) = pane.kind {
            PRTabGlyph(ref: ref, size: pane.kind.glyphSize(compact: compact))
        } else if case .run(let key) = pane.kind {
            RunStatusGlyph(run: tabs.runs.run(forKey: key), idleSymbol: "play.fill", size: pane.kind.glyphSize(compact: compact) + 1)
        } else {
            Image(systemName: pane.kind.symbol).font(.system(size: pane.kind.glyphSize(compact: compact)))
        }
    }
}

// MARK: - Openers (ADR-212, the footer's quick actions moved)

/// Terminal, Files and Diff always, then Media, Grill and each pull request once the session has some,
/// as the footer showed them (ADR-079, ADR-131). Each fronts its view wherever it is open, else opens
/// it in the right panel. Filled: on screen. Outlined: open behind another tab. Plain: not open.
struct WorkspaceOpeners: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(PRStore.self) private var prs
    @Environment(KeyBindings.self) private var bindings
    let tab: Tab

    var body: some View {
        HStack(spacing: 2) {
            opener(.terminal, "Terminal", .togglePanel)
            opener(.files, "Files", .toggleEditor)
            opener(.diff, "Diff", .toggleDiffPage)
            if let id = tab.sessionId, let n = sessions.state.attachments[id]?.count, n > 0 {
                opener(.attachments, "Media", .toggleAttachments)
            }
            if let id = tab.sessionId, !sessions.grillRounds(for: id).isEmpty {
                OpenerButton(help: "Grill — the agent's questions" + bindings.hint(.toggleGrill),
                             front: tab.isFront(.grill), open: tab.isOpen(.grill), action: { tabs.toggleGrill(tab) }) {
                    Image(systemName: PanelPane.Kind.grill.symbol).font(.system(size: 12))
                }
            }
            ForEach(prs.ordered(tabs.pullRequests(for: tab))) { ref in
                OpenerButton(help: "Pull request " + ref.codeHost.reference(ref.number), front: tab.isFront(.pr(ref)),
                             open: tab.isOpen(.pr(ref)), action: { tabs.togglePRPage(tab, ref: ref) }) {
                    HStack(spacing: 3) {
                        PRTabGlyph(ref: ref, size: PRStyle.glyphSize.tab)
                        Text(ref.codeHost.reference(ref.number)).font(.callout).monospacedDigit()
                    }
                }
            }
        }
    }

    private func opener(_ kind: PanelPane.Kind, _ title: String, _ action: ShortcutAction) -> some View {
        OpenerButton(help: title + bindings.hint(action), front: tab.isFront(kind), open: tab.isOpen(kind),
                     action: { tabs.showPane(kind, in: tab) }) {
            Image(systemName: kind.symbol).font(.system(size: 12))
        }
    }
}

/// One opener: glyph-sized, with ADR-079's three states.
private struct OpenerButton<Label: View>: View {
    let help: String
    let front: Bool
    let open: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 6)
                .frame(minWidth: 26, minHeight: 24)
                .background(front ? Color.accent.opacity(0.18) : hovering ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open && !front ? Color.accent.opacity(0.4) : .clear))
                .foregroundStyle(front ? Color.accent : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - The session header (ADR-212)

/// The toolbar's leading item: what the window is showing. For a session, its project's icon, its title
/// and state, and a line of project · branch · model ▾ · effort ▾ · context, which the footer used to
/// carry, with a ⋯ menu for the verbs the session tab's ✕ and menu used to hold.
struct WorkspaceHeader: View {
    @Environment(TabStore.self) private var tabs
    /// Passed in: toolbar content sits outside the `.environment(window)` the window's views get.
    let window: WindowState

    var body: some View {
        if let screen = window.screen {
            Text(screen.title).font(.headline)
        } else if window.editingDraft != nil {
            Text("New session").font(.headline)
        } else if let tab = tabs.selectedTab(in: window) {
            SessionHeader(tab: tab)
        }
    }
}

struct SessionHeader: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            ProjectIcon(project: Project(path: tab.projectPath), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tab.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    StatePill(tab: tab)
                }
                meta
            }
            // A toolbar item is as wide as it asks to be, and the controls after it overflow into a »
            // menu rather than squeeze it: the cap is what lets a long title truncate instead.
            .frame(maxWidth: 290, alignment: .leading)
            menu
        }
        .padding(.horizontal, 4)
    }

    private var meta: some View {
        HStack(spacing: 5) {
            Button(action: copyDirectory) {
                // The branch when there is one: the icon beside the title already names the project.
                HStack(spacing: 3) {
                    if let branch = tab.gitBranch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch).truncationMode(.middle)
                    } else {
                        Text(Project(path: tab.projectPath).name)
                    }
                }
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Working directory (click to copy): \(tab.pwd ?? tab.projectPath)")
            if tab.sessionId != nil {
                Text("·")
                ModelMenu(tab: tab, compact: true)
                Text("·")
                EffortMenu(tab: tab, compact: true)
                if let percent = tab.statusLine?.contextUsedPercentage {
                    Text("·")
                    ContextGauge(percent: percent, windowSize: tab.statusLine?.contextWindowSize).fixedSize()
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var menu: some View {
        Menu {
            Button("Close Session…") { tabs.close(tab) }
            if let id = tab.sessionId, let summary = sessions.sessions[id] {
                Button("Archive") { SessionActions.archive(summary, sessions: sessions, tabs: tabs) }
                Divider()
                Button("Details…") { NotificationCenter.default.post(name: .clinicSessionDetails, object: id.rawValue) }
            }
            Divider()
            MoveToWindowMenu(tab: tab)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Close, archive, move or show details of this session")
    }

    private func copyDirectory() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.pwd ?? tab.projectPath, forType: .string)
    }
}

/// The session's state in words, coloured only for what wants the reader (ADR-096's palette).
struct StatePill: View {
    let tab: Tab

    var body: some View {
        if let label {
            let tint = label.1
            Text(label.0)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tint.opacity(0.18), in: Capsule())
                .foregroundStyle(tint)
        }
    }

    private var label: (String, Color)? {
        if tab.isReplay { return ("Replay", .secondary) }
        switch tab.state {
        case .launching: return ("Starting", .secondary)
        case .working: return ("Working", .secondary)
        case .waitingForPermission, .waitingForInput: return ("Needs you", .orange)
        case .idle: return tab.unread ? ("Finished", .blue) : ("Idle", .secondary)
        case .exited: return ("Exited", .secondary)
        case nil: return nil
        }
    }
}
