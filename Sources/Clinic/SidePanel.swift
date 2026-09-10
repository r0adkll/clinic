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
        case pr(PullRequestRef)

        var symbol: String {
            switch self {
            case .terminal: "terminal"
            case .diff: "plus.forwardslash.minus"
            case .files: "doc.text.magnifyingglass"
            case .attachments: "photo.on.rectangle"
            case .pr: PullRequestMark.symbol
            }
        }

        /// Point size for `symbol` in the tab strip. Larger in the compact strip, where the glyph is
        /// the whole chip and has to carry the tab's identity on its own (ADR-104). The PR glyph runs
        /// ~2 pt over the boxy ones either way: `arrow.trianglehead.pull` is tall and narrow, so at a
        /// shared size it reads smaller than its neighbours and its arrowhead does not resolve at all
        /// (ADR-089).
        func glyphSize(compact: Bool) -> CGFloat {
            if case .pr = self { return compact ? PRStyle.glyphSize.tabCompact : PRStyle.glyphSize.tab }
            return compact ? 13 : 11
        }

        var defaultTitle: String {
            switch self {
            case .terminal: "Terminal"
            case .diff: "Diff"
            case .files: "Files"
            case .attachments: "Images"
            case .pr(let ref): "PR #\(ref.number)"
            }
        }

        /// How narrow the panel may get while this pane is showing. Main-actor because the Files pane's
        /// answer depends on the shared tree preference (ADR-081).
        @MainActor var minWidth: CGFloat {
            switch self {
            case .terminal: 400
            case .diff, .pr: 380
            // A viewer needs room to be a viewer, and the thumbnail list charges for its column
            // the way the file tree does (ADR-106).
            case .attachments: ImagePrefs.shared.showList ? 400 : 280
            // A hidden tree buys the panel back the width the tree was charging for (ADR-081). This
            // stays a constant deliberately: a minimum that tracked the live tree width would move the
            // panel's own divider while the tree divider was being dragged, and the two would fight.
            case .files: EditorPrefs.shared.showTree ? 500 : 360
            }
        }
    }

    let id = UUID()
    let kind: Kind
    var diff: DiffPanelModel?
    var editor: EditorModel?
    var terminal: GhosttySurfaceView?
    var images: ImageGallery?

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
    func append(_ pane: PanelPane) -> PanelPane {
        panes.append(pane)
        selectedId = pane.id
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
                            Label(tabs.paneTitle(kind, in: tab), systemImage: kind.symbol)
                        }
                    }
                }
            }
            if !tab.panel.panes.isEmpty {
                Section("Open") {
                    ForEach(tab.panel.panes) { pane in
                        Button { tabs.selectPane(pane, in: tab) } label: {
                            Label(tabs.paneTitle(pane.kind, in: tab), systemImage: pane.kind.symbol)
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
        if selected { return Color.accentColor.opacity(hovering ? 0.26 : 0.20) }
        if hovering { return Color.primary.opacity(0.11) }
        return Color.primary.opacity(0.05)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: pane.kind.symbol)
                .font(.system(size: pane.kind.glyphSize(compact: compact)))
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
                .help("Close this panel tab" + (selected ? " (⌘⌃W)" : ""))
            }
        }
        .padding(.leading, compact ? 6 : 8)
        .padding(.trailing, compact ? 6 : 4)
        .frame(height: 24)
        .frame(maxWidth: compact ? nil : 200)
        .background(fill, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear))
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture { tabs.selectPane(pane, in: tab) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        // The compact chip has no room for its name, so the tooltip is where the name lives.
        .help(compact ? title : "")
        .contextMenu {
            Button("Close") { tabs.closePane(pane, in: tab) }
            Button("Close Others") { tab.panel.closeAll(except: pane) }
                .disabled(tab.panel.panes.count < 2)
        }
    }
}

/// What the panel shows when it is open but holds no tabs: the same actions the strip's "+" menu offers.
struct SidePanelEmptyState: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab

    var body: some View {
        ContentUnavailableView {
            Label("Nothing open here", systemImage: "sidebar.right")
        } description: {
            Text("Add a view to work beside the session.")
        } actions: {
            VStack(spacing: 6) {
                ForEach(tabs.availablePanes(for: tab), id: \.self) { kind in
                    Button { tabs.showPane(kind, in: tab) } label: {
                        Label(kind.defaultTitle, systemImage: kind.symbol).frame(maxWidth: 180)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
