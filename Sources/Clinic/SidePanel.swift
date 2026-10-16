import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import ClinicCore
import GhosttyBridge

/// One tab in a session's workspace (ADR-079, ADR-212), in its main area or its right panel. Owns whatever
/// long-lived state its content needs — a git model, an editor model, a shell surface — so switching tabs,
/// or moving one between the areas, never rebuilds it.
@MainActor
@Observable
final class PanelPane: Identifiable {
    /// What a panel tab shows. Most kinds are one pane per tab, so a quick action re-focuses the pane
    /// it already opened; PRs and runs are distinguished by their ref or key, so each gets its own tab.
    /// A kind that `allowsSeveral` can be opened again beside itself, each pane its own identity (ADR-198).
    enum Kind: Hashable {
        case terminal, diff, files, attachments
        /// A round of the agent's questions, answered as a form (ADR-131).
        case grill
        case pr(PullRequestRef)
        /// A run's output (ADR-122). The surface belongs to `RunStore`, not to the pane.
        case run(RunKey)

        /// Whether a session may hold more than one pane of this kind (ADR-198). The quick action still
        /// fronts the one used last; *New …* adds another. Shells, and Files since ADR-212.
        var allowsSeveral: Bool { self == .terminal || self == .files }

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
            case .attachments: "Media"
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
            // widest minimum in the panel.
            case .grill: 460
            }
        }
    }

    let id = UUID()
    let kind: Kind
    /// Which of its kind this pane is, from 1, for a kind that `allowsSeveral`: the lowest number no
    /// open pane of the kind holds, so closing *Terminal 2* frees the name for the next one (ADR-198).
    var ordinal = 1
    /// The title the pane's shell last reported (OSC 0/2), which names its chip (ADR-198).
    var shellTitle: String?
    var diff: DiffPanelModel?
    /// A pull request pane's changed files. Held here rather than in the view, so the commands that
    /// read a diff (ADR-188) reach it the way they reach the Diff panel's.
    var changes: DiffBrowser?
    var editor: EditorModel?
    var terminal: GhosttySurfaceView?
    var images: ImageGallery?
    /// The round on screen and the reader's answers to it (ADR-131). Long-lived, so switching panes
    /// never loses a half-typed answer.
    var grill: GrillPaneModel?

    /// When this pane was last fronted, on one clock for every pane in every area, so "the one used
    /// last" holds across the main area and the right panel (ADR-198, ADR-212). Zero: never fronted.
    private(set) var frontedAt = 0
    private static var clock = 0
    func markFronted() { Self.clock += 1; frontedAt = Self.clock }

    init(kind: Kind) { self.kind = kind }

    /// Releases the pane's resources; called when the pane or its tab closes.
    func tearDown() {
        diff?.stopWatching()
        editor?.stop()
        terminal?.free()
        terminal = nil
    }
}

/// One of a session's two tab areas (ADR-212): the main area, where Claude is pinned first, or the right
/// panel (ADR-079). An ordered strip of panes with one selected. In the main area no selection means
/// Claude is in front; the right panel also shows and hides.
@MainActor
@Observable
final class SidePanel {
    /// The main area, which always shows (Claude when no pane is selected).
    let isMain: Bool
    private(set) var panes: [PanelPane] = []
    var selectedId: UUID? {
        didSet {
            selected?.markFronted()
            syncWatchers()
        }
    }
    /// The main area is always visible.
    var isVisible: Bool {
        didSet {
            // Only ever put back, never re-set to what it is: an observed property assigned in its own
            // didSet recurses until the stack runs out.
            if isMain && !isVisible { isVisible = true; return }
            syncWatchers()
        }
    }

    init(isMain: Bool = false) {
        self.isMain = isMain
        self.isVisible = isMain
    }

    var selected: PanelPane? { panes.first { $0.id == selectedId } }
    var isEmpty: Bool { panes.isEmpty }

    /// The pane of this kind a quick action means: the only one, or of several, the one fronted last (ADR-198).
    func pane(_ kind: PanelPane.Kind) -> PanelPane? { SidePanel.mostRecent(of: panes(kind)) }
    /// Of these panes, the one fronted last; one never fronted counts as older than any that was.
    static func mostRecent(of candidates: [PanelPane]) -> PanelPane? {
        candidates.max { $0.frontedAt < $1.frontedAt }
    }
    func panes(_ kind: PanelPane.Kind) -> [PanelPane] { panes.filter { $0.kind == kind } }
    func contains(_ pane: PanelPane) -> Bool { panes.contains { $0.id == pane.id } }
    /// Each shell pane is drawn only while it is the one on screen, in a tab on screen (ADR-019, ADR-198).
    func occludeShells(tabHidden: Bool) {
        for pane in panes(.terminal) { pane.terminal?.isOccluded = tabHidden || !isVisible || pane.id != selectedId }
    }
    /// The pane is open, the area is showing, and this pane is the one on screen.
    func isFront(_ kind: PanelPane.Kind) -> Bool { isVisible && selected?.kind == kind }
    func isOpen(_ kind: PanelPane.Kind) -> Bool { pane(kind) != nil }

    @discardableResult
    func append(_ pane: PanelPane, select: Bool = true) -> PanelPane {
        panes.append(pane)
        if select { selectedId = pane.id }
        return pane
    }

    /// Puts a pane at a position in the strip, for a drop between two tabs (ADR-215).
    func insert(_ pane: PanelPane, at index: Int, select: Bool = true) {
        panes.insert(pane, at: min(max(0, index), panes.count))
        if select { selectedId = pane.id }
    }

    func select(_ pane: PanelPane) {
        selectedId = pane.id
        isVisible = true
    }

    /// Takes a pane out of the strip without tearing it down, for a move to the other area (ADR-212).
    /// Selects its neighbour — in the main area, Claude when it was the last — and the right panel hides
    /// when the last one goes.
    @discardableResult
    func detach(_ pane: PanelPane) -> PanelPane? {
        guard let index = panes.firstIndex(where: { $0.id == pane.id }) else { return nil }
        panes.remove(at: index)
        if selectedId == pane.id {
            selectedId = isMain ? panes[safe: index - 1]?.id ?? panes.first?.id : panes[safe: index]?.id ?? panes.last?.id
        }
        // The panel goes with its last pane (ADR-130, over ADR-079): an empty panel is a column of
        // chrome around nothing, and the reader who closed the thing they were reading wants the
        // session back. The empty state is still reachable — showing the panel with no panes.
        if panes.isEmpty && !isMain { isVisible = false }
        return pane
    }

    /// Closes a pane, selecting its neighbour.
    func close(_ pane: PanelPane) {
        guard detach(pane) != nil else { return }
        pane.tearDown()
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
        isVisible = isMain
    }

    /// Only the pane on screen watches the file system; the others idle until they come back to the
    /// front, when `DiffPanelModel.bind` starts the watcher again (ADR-183).
    private func syncWatchers() {
        for pane in panes where !isVisible || pane.id != selectedId { pane.diff?.stopWatching() }
    }

    /// Cycles the selection; ⌃⇥ inside the panel. In the main area Claude is one of the stops.
    func cycle(by delta: Int) {
        let ids: [UUID?] = (isMain ? [nil] : []) + panes.map { Optional($0.id) }
        guard ids.count > 1, let current = ids.firstIndex(where: { $0 == selectedId }) else { return }
        selectedId = ids[(current + delta + ids.count) % ids.count]
    }

    /// Everything that changes what the AppKit host must show, in one string (see `TerminalStack`).
    /// The tree toggle is in here because it changes the Files pane's minimum width, which only the
    /// host knows what to do with (ADR-081).
    var renderKey: String {
        "\(isVisible)|\(EditorPrefs.shared.showTree)|\(ImagePrefs.shared.showList)|\(selectedId?.uuidString ?? "-")|" + panes.map { "\($0.id)\($0.kind)" }.joined(separator: ",")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Chrome

/// Tab strip above one of the workspace's areas (ADR-212): one chip per pane and a menu of everything else
/// (ADR-079, sized and made adaptive by ADR-104). Every area draws the same strip (ADR-214). The main area's
/// pins Claude first and carries the panel toggle at its trailing end.
struct PaneTabStrip: View {
    @Environment(TabStore.self) private var tabs
    @Environment(KeyBindings.self) private var bindings
    let tab: Tab
    let area: Tab.Area
    @State private var dropTargeted = false

    private var group: SidePanel { tab.group(area) }

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
                    // Chords and the other strip's move button change the selection from outside this
                    // strip; without this the tab they select can be off the end of a scrolled strip.
                    .onChange(of: group.selectedId) {
                        guard let id = group.selectedId else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            addMenu
            trailing
        }
        .padding(.horizontal, PaneMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.bar)
        // A tab dropped on the strip but not on a chip goes to the end of this area (ADR-215). A chip's
        // own drop target, which puts it before that chip, wins over this one.
        .overlay { if dropTargeted { Color.accent.opacity(0.08).allowsHitTesting(false) } }
        .dropDestination(for: PaneDragItem.self) { items, _ in
            PaneDrag.drop(items, in: tab, area: area, before: nil, tabs: tabs)
        } isTargeted: { dropTargeted = $0 }
        .contentShape(Rectangle())
        // ⇧-click anywhere the chips are not hides the panel (ADR-130): the same gesture that closes
        // a tab, aimed at the strip, closes the thing the strip belongs to. A plain click on the bar
        // still does nothing. The main area does not hide, so its strip ignores the gesture.
        .onTapGesture { if area == .right, NSEvent.modifierFlags.contains(.shift) { tabs.hidePanel(tab) } }
    }

    private func chips(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if area == .main {
                ClaudeTabChip(tab: tab, selected: group.selectedId == nil, compact: compact)
            }
            ForEach(group.panes) { pane in
                SidePanelTabChip(tab: tab, pane: pane, selected: pane.id == group.selectedId, compact: compact)
                    .id(pane.id)
            }
        }
        // A chip's `maxWidth` is a cap on a long title, not a width to grow into. Without this the
        // row is handed the strip's whole width and every chip stretches to 200 pt — three tabs then
        // measure 340 pt to `ViewThatFits` and draw 600, overflowing the panel they are sized for.
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var trailing: some View {
        if area == .main, !tab.isReplay {
            Divider().frame(height: 16)
            PaneIconButton(symbol: "sidebar.right",
                           help: tab.panel.isVisible ? "Hide the right panel" + bindings.hint(.togglePanelVisibility) + ", or ⇧-click its tab bar"
                                                     : "Show the right panel" + bindings.hint(.togglePanelVisibility),
                           isOn: tab.panel.isVisible) { tabs.togglePanelVisibility(tab) }
        }
    }

    /// Add a view to this area, or jump to a tab already open in either.
    ///
    /// It lists the open tabs as well as the addable kinds, which makes it the strip's overflow list:
    /// in the compact form the chips are glyphs, and this is where their names are. It is therefore
    /// never disabled (ADR-104). The main area's is also where every view is reached, now that the
    /// openers are gone (ADR-213).
    private var addMenu: some View {
        PaneIconMenu(symbol: "plus", help: area == .main ? "Open a view beside Claude" : "Open a view in this panel") {
            let available = tabs.availablePanes(for: tab)
            if !available.isEmpty {
                Section("Add") {
                    ForEach(available, id: \.self) { kind in
                        // A kind already open that allows several adds another, named as such (ADR-198).
                        Button { tabs.addPane(kind, in: tab, area: area) } label: {
                            Label { Text(tab.isOpen(kind) ? "New " + kind.defaultTitle + " Tab" : tabs.paneTitle(kind, in: tab)) } icon: { kind.icon }
                        }
                    }
                }
            }
            let here = group.panes
            if area == .main || !here.isEmpty {
                Section("Open") {
                    if area == .main {
                        Button { tabs.selectClaude(in: tab) } label: { Label("Claude", systemImage: "sparkle") }
                    }
                    paneButtons(here)
                }
            }
            let other = tab.group(area == .main ? .right : .main).panes
            if !other.isEmpty {
                Section(area == .main ? "In the Right Panel" : "In the Main Area") { paneButtons(other) }
            }
        }
    }

    private func paneButtons(_ panes: [PanelPane]) -> some View {
        ForEach(panes) { pane in
            Button { tabs.selectPane(pane, in: tab) } label: {
                Label { Text(tabs.paneTitle(pane, in: tab)) } icon: { pane.kind.icon }
            }
        }
    }
}

extension UTType {
    /// A dragged tab (ADR-218). Clinic's own type, so a terminal, which takes dropped text and files, never
    /// receives one: as text, a tab released over a shell was pasted into it.
    static let clinicPane = UTType(exportedAs: "com.r0adkll.clinic.pane")
}

/// What a dragged tab carries: its pane's id.
struct PaneDragItem: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .clinicPane) }
}

/// Dragging a tab between and within the strips (ADR-215), and onto an area's content (ADR-218). A pane from
/// another session's workspace is refused.
enum PaneDrag {
    static func payload(_ pane: PanelPane) -> PaneDragItem { PaneDragItem(id: pane.id) }

    /// Moves the dragged tab to `area`, before `before` or at the end. True when it was a tab of this session.
    @MainActor
    static func drop(_ items: [PaneDragItem], in tab: Tab, area: Tab.Area, before: PanelPane?, tabs: TabStore) -> Bool {
        guard let id = items.first?.id, let pane = tab.allPanes.first(where: { $0.id == id }) else { return false }
        tabs.movePane(pane, in: tab, to: area, before: before)
        return true
    }
}

/// Where a dragged tab will land: a short accent bar at the edge of the chip it would go beside.
private struct DropMarker: View {
    let visible: Bool

    var body: some View {
        Capsule().fill(Color.accent)
            .frame(width: 2, height: 18)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// The chip every tab strip draws (ADR-104): a resting fill on every chip, hover a shade deeper, the
/// selected one in the accent with an accent border. In the compact form a chip without its fill is
/// indistinguishable from a toolbar glyph, and the strip stops reading as a row of tabs at all.
private struct TabChipChrome: ViewModifier {
    let selected: Bool
    let compact: Bool
    @Binding var hovering: Bool

    private var fill: Color {
        if selected { return Color.accent.opacity(hovering ? 0.26 : 0.20) }
        if hovering { return Color.primary.opacity(0.11) }
        return Color.primary.opacity(0.05)
    }

    func body(content: Content) -> some View {
        content
            .padding(.leading, compact ? 6 : 8)
            .padding(.trailing, compact ? 6 : 4)
            .frame(height: 24)
            .frame(maxWidth: compact ? nil : 200)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accent.opacity(0.55) : .clear))
            .foregroundStyle(selected ? Color.accent : Color.primary)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// The main area's pinned Claude chip (ADR-212): the session's state glyph and *Claude*. It has no close
/// button, because closing it is closing the session, which the header's menu and ⌘W do through the close
/// sheet.
struct ClaudeTabChip: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let selected: Bool
    var compact = false
    @State private var hovering = false
    @State private var dropTargeted = false

    private var title: String {
        if tab.isReplay { return "Replay" }
        return tab.sessionId == nil ? "Shell" : "Claude"
    }

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if tab.sessionId == nil { Image(systemName: "terminal").font(.system(size: compact ? 13 : 11)) }
                else { StateGlyph(tab: tab) }
            }
            .frame(width: 16)
            if !compact {
                // Pinned: no close button, so the title gets the chip's trailing inset to itself.
                Text(title).font(.callout).lineLimit(1).padding(.trailing, 4)
            }
        }
        .modifier(TabChipChrome(selected: selected, compact: compact, hovering: $hovering))
        // Claude is pinned: a tab dropped on it lands right after it, first among the others (ADR-215).
        .overlay(alignment: .trailing) { DropMarker(visible: dropTargeted).offset(x: 3) }
        .dropDestination(for: PaneDragItem.self) { items, _ in
            PaneDrag.drop(items, in: tab, area: .main, before: tab.main.panes.first, tabs: tabs)
        } isTargeted: { dropTargeted = $0 }
        .onTapGesture { tabs.selectClaude(in: tab) }
        .help(compact ? title : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) { tabs.selectClaude(in: tab) }
        .contextMenu {
            Button("Close Session…") { tabs.close(tab) }
            Divider()
            MoveToWindowMenu(tab: tab)
        }
    }
}

/// One tab in a strip. Two forms of the same chip: labelled, and glyph-only for a narrow area.
struct SidePanelTabChip: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let pane: PanelPane
    let selected: Bool
    var compact = false
    @State private var hovering = false
    @State private var dropTargeted = false

    private var title: String { tabs.paneTitle(pane, in: tab) }
    /// Whether this tab is in the main area, which names its menu's *Move to …* (ADR-212).
    private var inMain: Bool { tab.area(of: pane) == .main }

    var body: some View {
        HStack(spacing: 5) {
            PaneGlyph(tab: tab, pane: pane, compact: compact)
                .frame(width: 16)
            if !compact {
                Text(title).font(.callout).lineLimit(1)
                // Always laid out, only faded in: a close button that appears on hover must not reflow
                // the chip it belongs to.
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
                .accessibilityLabel("Close \(title)")
                .help("Close this tab" + (selected && !inMain ? " (⌘⌃W)" : "") + ", or ⇧-click the tab")
            }
        }
        .modifier(TabChipChrome(selected: selected, compact: compact, hovering: $hovering))
        // Dragged to another place in this strip, or to the other area's strip, the tab moves there with
        // its state; dropped on this chip, a tab lands before it (ADR-215).
        .draggable(PaneDrag.payload(pane)) {
            HStack(spacing: 5) {
                PaneGlyph(tab: tab, pane: pane, compact: false)
                Text(title).font(.callout).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(Color.accent.opacity(0.20), in: RoundedRectangle(cornerRadius: 6))
        }
        .overlay(alignment: .leading) { DropMarker(visible: dropTargeted).offset(x: -3) }
        .dropDestination(for: PaneDragItem.self) { items, _ in
            guard let area = tab.area(of: pane) else { return false }
            return PaneDrag.drop(items, in: tab, area: area, before: pane, tabs: tabs)
        } isTargeted: { dropTargeted = $0 }
        // ⇧-click closes (ADR-130). A pane closes without asking — nothing is running in it that the
        // tab does not already own — and this is the compact chip's only pointer-driven close, since
        // there is no room there for an ✕.
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) { tabs.closePane(pane, in: tab) }
            else { tabs.selectPane(pane, in: tab) }
        }
        // The compact chip has no room for its name, so the tooltip is where the name lives.
        .help(compact ? title + " — ⇧-click to close" : "")
        .contextMenu {
            // Any tab can sit in either area (ADR-212). The menu is the way there without dragging (ADR-215).
            Button(inMain ? "Move to Right Panel" : "Move to Main Area") { tabs.movePane(pane, in: tab) }
            Divider()
            Button("Close") { tabs.closePane(pane, in: tab) }
            Button("Close Others") { tabs.closeOtherPanes(pane, in: tab) }
                .disabled((tab.area(of: pane).map { tab.group($0).panes.count } ?? 0) < 2)
        }
    }
}

/// What the panel shows when it is open but holds no tabs (ADR-172): the views it can hold, each
/// saying what it would show for this tab and the chord that opens it from anywhere, then what this
/// session has produced — its pull requests and runs — and the chord that hides the panel.
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
                                              open: { tabs.addPane(.pr(ref), in: tab, area: .right) }) {
                                    PRTabGlyph(ref: ref, size: 15).frame(width: 26, height: 26)
                                }
                            }
                            ForEach(runs, id: \.self) { key in
                                let run = tabs.runs.run(forKey: key)
                                EmptyPanelRow(title: run?.name ?? key.configId, detail: "Run output · " + RunText.status(run),
                                              open: { tabs.addPane(.run(key), in: tab, area: .right) }) {
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

    /// The empty state's own icon and title, centred over the rows the way `ContentUnavailableView`
    /// draws them, so the panel still reads as empty at a glance before it reads as a list.
    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Open beside the session").font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Views open as tabs in this panel. Their shortcuts work from anywhere in the tab.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8).padding(.bottom, 4)
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
        }
        .frame(maxWidth: .infinity)
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
            return count > 0 ? "\(count) item\(count == 1 ? "" : "s") from this session" : "Screenshots, GIFs and videos Claude shows you land here"
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

    /// Into this panel, as the header says: a shell or Files opens another here even when one is open
    /// in the main area, rather than fronting that one. Grill takes the keyboard as it does from its chord.
    private func open(_ kind: PanelPane.Kind) {
        tabs.addPane(kind, in: tab, area: .right)
        if kind == .grill { tabs.grillKeyboardRequests.insert(tab.id) }
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
