import AppKit
import Observation
import SwiftUI
import ClinicCore
import GhosttyBridge

/// One tab in a session tab's right-hand panel (ADR-079). Owns whatever long-lived state its content
/// needs — a git model, an editor model, a shell surface — so switching panel tabs never rebuilds it.
@MainActor
@Observable
final class PanelPane: Identifiable {
    /// Panel tab identity. Two panes of the same kind never coexist, so a quick action re-focuses the
    /// pane it already opened; PRs are distinguished by their ref, so each PR gets its own tab.
    enum Kind: Hashable {
        case terminal, diff, files, attachments
        /// A round of the agent's questions, answered as a form (ADR-131).
        case grill
        case pr(PullRequestRef)
        /// A run's output (ADR-122). The surface belongs to `RunStore`, not to the pane.
        case run(RunKey)

        var symbol: String {
            switch self {
            case .terminal: "terminal"
            case .diff: "plus.forwardslash.minus"
            case .files: "doc.text.magnifyingglass"
            case .attachments: "photo.on.rectangle"
            case .grill: "flame"
            case .pr: PullRequestMark.symbol
            case .run: "play.fill"
            }
        }

        /// Point size for the glyph in the tab strip. Larger in the compact strip, where the glyph is
        /// the whole chip and has to carry the tab's identity on its own (ADR-104). A PR tab draws its
        /// service's state glyph instead of `symbol` (ADR-116), sized by `PRStyle.glyphSize`.
        func glyphSize(compact: Bool) -> CGFloat {
            if case .pr = self { return compact ? PRStyle.glyphSize.tabCompact : PRStyle.glyphSize.tab }
            return compact ? 13 : 11
        }

        /// `symbol` as an image, except that a PR shows its service's glyph (ADR-116). For menus and
        /// labels; the tab chip itself draws `PRTabGlyph`, which also shows the PR's state.
        var icon: Image {
            if case .pr(let ref) = self { return Image(ref.codeHost.art.open).renderingMode(.template) }
            return Image(systemName: symbol)
        }

        var defaultTitle: String {
            switch self {
            case .terminal: "Terminal"
            case .diff: "Diff"
            case .files: "Files"
            case .attachments: "Images"
            case .grill: "Grill"
            case .pr(let ref): ref.codeHost.reference(ref.number)
            case .run(let key): key.configId
            }
        }

        /// How narrow the panel may get while this pane is showing. Main-actor because the Files pane's
        /// answer depends on the shared tree preference (ADR-081).
        @MainActor var minWidth: CGFloat {
            switch self {
            case .terminal, .run: 400
            case .diff, .pr: 380
            // A viewer needs room to be a viewer, and the thumbnail list charges for its column
            // the way the file tree does (ADR-106).
            case .attachments: ImagePrefs.shared.showList ? 400 : 280
            // A hidden tree buys the panel back the width the tree was charging for (ADR-081). This
            // stays a constant deliberately: a minimum that tracked the live tree width would move the
            // panel's own divider while the tree divider was being dragged, and the two would fight.
            case .files: EditorPrefs.shared.showTree ? 500 : 360
            // A question's body runs to paragraphs and its choices to full sentences, so this is the
            // widest minimum in the panel. A long round widens further with `zoomPanel` (ADR-131).
            case .grill: 460
            }
        }
    }

    let id = UUID()
    let kind: Kind
    var diff: DiffPanelModel?
    var editor: EditorModel?
    var terminal: GhosttySurfaceView?
    var images: ImageGallery?
    /// The round on screen and the reader's answers to it (ADR-131). Long-lived, so switching panes
    /// never loses a half-typed answer.
    var grill: GrillPaneModel?

    init(kind: Kind) { self.kind = kind }

    /// Releases the pane's resources; called when the pane or its tab closes.
    func tearDown() {
        diff?.stopWatching()
        editor?.stop()
        terminal?.free()
        terminal = nil
    }
}

/// The right-hand panel of one session tab (ADR-079): an ordered strip of panes with one selected,
/// plus a visibility flag the footer quick actions drive.
@MainActor
@Observable
final class SidePanel {
    private(set) var panes: [PanelPane] = []
    var selectedId: UUID? { didSet { syncWatchers() } }
    /// Hiding the panel un-zooms it, so the two controls can never leave a tab with no way back (ADR-081).
    var isVisible = false { didSet { if !isVisible { isZoomed = false }; syncWatchers() } }
    /// The panel fills the tab, with the agent surface hidden behind it (ADR-081).
    var isZoomed = false

    var selected: PanelPane? { panes.first { $0.id == selectedId } }
    var isEmpty: Bool { panes.isEmpty }

    func pane(_ kind: PanelPane.Kind) -> PanelPane? { panes.first { $0.kind == kind } }
    /// The pane is open, the panel is showing, and this pane is the one on screen.
    func isFront(_ kind: PanelPane.Kind) -> Bool { isVisible && selected?.kind == kind }
    func isOpen(_ kind: PanelPane.Kind) -> Bool { pane(kind) != nil }

    @discardableResult
    func append(_ pane: PanelPane, select: Bool = true) -> PanelPane {
        panes.append(pane)
        if select { selectedId = pane.id }
        return pane
    }

    func select(_ pane: PanelPane) {
        selectedId = pane.id
        isVisible = true
    }

    /// Closes a pane, selecting its neighbour; the panel hides when the last one goes.
    func close(_ pane: PanelPane) {
        guard let index = panes.firstIndex(where: { $0.id == pane.id }) else { return }
        panes.remove(at: index)
        pane.tearDown()
        if selectedId == pane.id {
            selectedId = panes[safe: index]?.id ?? panes.last?.id
        }
        // The panel goes with its last pane (ADR-130, over ADR-079): an empty panel is a column of
        // chrome around nothing, and the reader who closed the thing they were reading wants the
        // session back. The empty state is still reachable — showing the panel with no panes.
        if panes.isEmpty { isVisible = false }
    }

    func closeAll(except keep: PanelPane? = nil) {
        for pane in panes where pane.id != keep?.id { pane.tearDown() }
        panes = keep.map { [$0] } ?? []
        selectedId = keep?.id
    }

    func tearDown() {
        for pane in panes { pane.tearDown() }
        panes = []
        selectedId = nil
        isVisible = false
        isZoomed = false
    }

    /// Only the pane on screen watches the file system; the others idle until they come back to the front.
    private func syncWatchers() {
        for pane in panes where !isVisible || pane.id != selectedId { pane.diff?.stopWatching() }
    }

    /// Cycles the selection; ⌃⇥ inside the panel.
    func cycle(by delta: Int) {
        guard panes.count > 1, let current = panes.firstIndex(where: { $0.id == selectedId }) else { return }
        let next = (current + delta + panes.count) % panes.count
        selectedId = panes[next].id
    }

    /// Everything that changes what the AppKit host must show, in one string (see `TerminalStack`).
    /// The tree toggle is in here because it changes the Files pane's minimum width, which only the
    /// host knows what to do with (ADR-081).
    var renderKey: String {
        "\(isVisible)|\(isZoomed)|\(EditorPrefs.shared.showTree)|\(ImagePrefs.shared.showList)|\(selectedId?.uuidString ?? "-")|" + panes.map { "\($0.id)\($0.kind)" }.joined(separator: ",")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Chrome

/// Tab strip above the panel content: one chip per pane and a menu of everything else (ADR-079,
/// sized and made adaptive by ADR-104). The panel's show/hide lives in the session tab bar, not here.
struct SidePanelTabBar: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab

    var body: some View {
        HStack(spacing: 6) {
            // Labelled chips while they fit, icon-only when they do not, scrolling only when even
            // those do not. The strip this replaced always drew `TabChip`'s full metrics — sized for
            // a window-wide bar — into a 380 pt column, so a fourth tab scrolled out of sight behind
            // a hidden scroll bar (ADR-104). `ViewThatFits` falls through to its last candidate when
            // none fit, which is what makes the scrolling one the backstop rather than the default.
            ViewThatFits(in: .horizontal) {
                chips(compact: false)
                chips(compact: true)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        chips(compact: true)
                    }
                    // ⌘⌃] and the footer quick actions change the selection from outside the strip;
                    // without this the tab they select can be off the end of a scrolled strip.
                    .onChange(of: tab.panel.selectedId) {
                        guard let id = tab.panel.selectedId else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            addMenu
        }
        .padding(.horizontal, PaneMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.bar)
        .contentShape(Rectangle())
        // ⇧-click anywhere the chips are not hides the panel (ADR-130): the same gesture that closes
        // a tab, aimed at the strip, closes the thing the strip belongs to. A plain click on the bar
        // still does nothing. The strip only exists while the panel shows, so this is hide, not toggle.
        .onTapGesture { if NSEvent.modifierFlags.contains(.shift) { tabs.hidePanel(tab) } }
    }

    private func chips(compact: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(tab.panel.panes) { pane in
                SidePanelTabChip(tab: tab, pane: pane,
                                 selected: pane.id == tab.panel.selectedId, compact: compact)
                    .id(pane.id)
            }
        }
        // A chip's `maxWidth` is a cap on a long title, not a width to grow into. Without this the
        // row is handed the strip's whole width and every chip stretches to 200 pt — three tabs then
        // measure 340 pt to `ViewThatFits` and draw 600, overflowing the panel they are sized for.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Add a view, or jump to one that is already open.
    ///
    /// It lists the open panes as well as the addable kinds, which makes it the strip's overflow
    /// list: in the compact form the chips are glyphs, and this is where their names are. It is
    /// therefore never disabled — the old menu emptied itself once all five kinds were open and sat
    /// there greyed out, explaining nothing (ADR-104).
    private var addMenu: some View {
        PaneIconMenu(symbol: "plus", help: "Open a view in this panel") {
            let available = tabs.availablePanes(for: tab)
            if !available.isEmpty {
                Section("Add") {
                    ForEach(available, id: \.self) { kind in
                        Button { tabs.showPane(kind, in: tab) } label: {
                            Label { Text(tabs.paneTitle(kind, in: tab)) } icon: { kind.icon }
                        }
                    }
                }
            }
            if !tab.panel.panes.isEmpty {
                Section("Open") {
                    ForEach(tab.panel.panes) { pane in
                        Button { tabs.selectPane(pane, in: tab) } label: {
                            Label { Text(tabs.paneTitle(pane.kind, in: tab)) } icon: { pane.kind.icon }
                        }
                    }
                }
            }
        }
    }
}

/// One tab in the strip. Two forms of the same chip: labelled, and glyph-only for a narrow panel.
///
/// Every chip carries a resting fill, not only the selected one. In the compact form a chip without
/// one is indistinguishable from a toolbar glyph, and the strip stops reading as a row of tabs at all
/// (ADR-104).
struct SidePanelTabChip: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let pane: PanelPane
    let selected: Bool
    var compact = false
    @State private var hovering = false

    private var title: String { tabs.paneTitle(pane.kind, in: tab) }

    private var fill: Color {
        if selected { return Color.accent.opacity(hovering ? 0.26 : 0.20) }
        if hovering { return Color.primary.opacity(0.11) }
        return Color.primary.opacity(0.05)
    }

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if case .pr(let ref) = pane.kind {
                    PRTabGlyph(ref: ref, size: pane.kind.glyphSize(compact: compact))
                } else if case .run(let key) = pane.kind {
                    RunStatusGlyph(run: tabs.runs.run(forKey: key), idleSymbol: "play.fill", size: pane.kind.glyphSize(compact: compact) + 1)
                } else {
                    Image(systemName: pane.kind.symbol)
                        .font(.system(size: pane.kind.glyphSize(compact: compact)))
                }
            }
            .frame(width: 16)
            if !compact {
                Text(title).font(.callout).lineLimit(1)
                // Always laid out, only faded in: a close button that appears on hover must not
                // reflow the chip it belongs to.
                Button { tabs.closePane(pane, in: tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                        .background(hovering ? Color.primary.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .opacity(hovering || selected ? 1 : 0)
                .help("Close this panel tab" + (selected ? " (⌘⌃W)" : "") + ", or ⇧-click the tab")
            }
        }
        .padding(.leading, compact ? 6 : 8)
        .padding(.trailing, compact ? 6 : 4)
        .frame(height: 24)
        .frame(maxWidth: compact ? nil : 200)
        .background(fill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(selected ? Color.accent.opacity(0.55) : .clear))
        .foregroundStyle(selected ? Color.accent : Color.primary)
        .contentShape(Rectangle())
        // ⇧-click closes (ADR-130). A panel pane closes without asking — nothing is running in it
        // that the tab does not already own — and this is the compact chip's only pointer-driven
        // close, since there is no room there for an ✕.
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) { tabs.closePane(pane, in: tab) }
            else { tabs.selectPane(pane, in: tab) }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        // The compact chip has no room for its name, so the tooltip is where the name lives.
        .help(compact ? title + " — ⇧-click to close" : "")
        .contextMenu {
            Button("Close") { tabs.closePane(pane, in: tab) }
            Button("Close Others") { tabs.closeOtherPanes(pane, in: tab) }
                .disabled(tab.panel.panes.count < 2)
        }
    }
}

/// What the panel shows when it is open but holds no tabs (ADR-172): the views it can hold, each
/// saying what it would show for this tab and the chord that opens it from anywhere, then what this
/// session has produced — its pull requests and runs — and the chords that hide or zoom the panel.
///
/// An empty panel is only ever asked for (ADR-130), so it is read by someone choosing what to put
/// here; a row per view with a reason to pick it is that choice, where a stack of bare buttons was not.
struct SidePanelEmptyState: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(PRStore.self) private var prs
    @Environment(KeyBindings.self) private var bindings
    let tab: Tab

    var body: some View {
        let available = tabs.availablePanes(for: tab)
        let views = available.filter(\.isView)
        // Newest first: ⌘⇧P opens the newest PR, so the row carrying its chord leads.
        let refs = available.compactMap { if case .pr(let ref) = $0 { ref } else { nil } }.reversed()
        let runs = available.compactMap { if case .run(let key) = $0 { key } else { nil } }
        // Centred in the pane when it fits, scrolling from the top when it does not (ADR-120's rule).
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    section("Views") {
                        ForEach(views, id: \.self) { kind in
                            EmptyPanelRow(title: kind.defaultTitle, detail: detail(for: kind),
                                          urgent: kind == .grill && waitingQuestions > 0,
                                          chord: action(for: kind).flatMap { bindings.chord(for: $0) }?.display,
                                          open: { open(kind) }) {
                                AccentTile(symbol: kind.symbol, size: 26, glyph: 12)
                            }
                        }
                    }
                    if !refs.isEmpty || !runs.isEmpty {
                        section("This session") {
                            ForEach(Array(refs.enumerated()), id: \.element) { index, ref in
                                EmptyPanelRow(title: prTitle(ref), detail: prDetail(ref),
                                              chord: index == 0 ? bindings.chord(for: .togglePRPage)?.display : nil,
                                              open: { tabs.togglePRPage(tab, ref: ref) }) {
                                    PRTabGlyph(ref: ref, size: 15).frame(width: 26, height: 26)
                                }
                            }
                            ForEach(runs, id: \.self) { key in
                                let run = tabs.runs.run(forKey: key)
                                EmptyPanelRow(title: run?.name ?? key.configId, detail: "Run output · " + RunText.status(run),
                                              open: { tabs.showPane(.run(key), in: tab) }) {
                                    RunStatusGlyph(run: run, size: 13).frame(width: 26, height: 26)
                                }
                            }
                        }
                    }
                    footer
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 20).padding(.vertical, 28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Titles, not refs: a row reading "#412" says nothing about which pull request it is.
        .task(id: refs.map(\.id)) { prs.ensureLoaded(Array(refs)) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Open beside the session").font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Views open as tabs in this panel. Their shortcuts work from anywhere in the tab.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The home screen's section caption (ADR-120).
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 8).frame(height: 20)
            content()
        }
    }

    /// How to leave, in the same key caps: an empty panel's one other job is getting out of the way.
    private var footer: some View {
        HStack(spacing: 14) {
            footerHint("Hide", .togglePanelVisibility)
            footerHint("Zoom", .zoomPanel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func footerHint(_ title: String, _ action: ShortcutAction) -> some View {
        if let chord = bindings.chord(for: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                KeyCap(chord.display)
            }
        }
    }

    // MARK: Facts

    private var folder: String { Project(path: tab.pwd ?? tab.projectPath).name }

    private var waitingQuestions: Int {
        tab.sessionId.map { sessions.openGrillRounds(for: $0) }?
            .reduce(0) { $0 + ($1.questions.count - $1.answeredCount) } ?? 0
    }

    /// What the view would show for this tab, from what is already known — never a fetch.
    private func detail(for kind: PanelPane.Kind) -> String {
        switch kind {
        case .terminal: return "A shell in \(folder)"
        case .diff: return tab.gitBranch.map { "Changes on \($0), by turn or branch" } ?? "Changes by turn or branch"
        case .files: return "Browse and edit \(folder)"
        case .attachments:
            let count = tab.sessionId.flatMap { sessions.state.attachments[$0]?.count } ?? 0
            return count > 0 ? "\(count) image\(count == 1 ? "" : "s") from this session" : "Images Claude shows you land here"
        case .grill:
            let waiting = waitingQuestions
            return waiting > 0 ? "\(waiting) question\(waiting == 1 ? "" : "s") waiting for you" : "Answer Claude's question rounds as a form"
        case .pr, .run: return ""
        }
    }

    private func prTitle(_ ref: PullRequestRef) -> String {
        let number = ref.codeHost.reference(ref.number)
        return prs.pullRequest(for: ref).map { "\(number) \($0.title)" } ?? number
    }

    private func prDetail(_ ref: PullRequestRef) -> String {
        guard let pr = prs.pullRequest(for: ref) else { return ref.repository }
        let state = pr.isDraft && pr.state == .open ? "Draft" : pr.state.rawValue.capitalized
        return "\(ref.repository) · \(state)"
    }

    private func action(for kind: PanelPane.Kind) -> ShortcutAction? {
        switch kind {
        case .terminal: .togglePanel
        case .diff: .toggleDiffPage
        case .files: .toggleEditor
        case .attachments: .toggleAttachments
        case .grill: .toggleGrill
        case .pr, .run: nil
        }
    }

    /// Through the same openers as the menu and the chords, so Grill takes the keyboard as it does there.
    private func open(_ kind: PanelPane.Kind) {
        if kind == .grill { tabs.toggleGrill(tab) } else { tabs.showPane(kind, in: tab) }
    }
}

private extension PanelPane.Kind {
    /// One of the fixed views, as opposed to something this session produced (a PR, a run).
    var isView: Bool {
        switch self {
        case .pr, .run: false
        default: true
        }
    }
}

/// One choice in the empty panel: glyph, title over a line of detail, and the chord that opens it.
private struct EmptyPanelRow<Glyph: View>: View {
    let title: String
    let detail: String
    /// The detail is something waiting on the reader, so it wears the sidebar's orange (ADR-096).
    var urgent = false
    var chord: String? = nil
    let open: () -> Void
    @ViewBuilder let glyph: Glyph
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    Text(detail).font(.system(size: 11))
                        .foregroundStyle(urgent ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let chord { KeyCap(chord) }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(title) in this panel" + (chord.map { " (\($0))" } ?? ""))
    }
}
