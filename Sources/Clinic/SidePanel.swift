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
            case .pr: "arrow.triangle.pull"
            }
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
            case .attachments: 320
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
        "\(isVisible)|\(isZoomed)|\(EditorPrefs.shared.showTree)|\(selectedId?.uuidString ?? "-")|" + panes.map { "\($0.id)\($0.kind)" }.joined(separator: ",")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Chrome

/// Tab strip above the panel content: one chip per pane and an add menu (ADR-079). The panel's
/// show/hide lives in the session tab bar, not here. Chip metrics match `TabChip` so both strips read alike.
struct SidePanelTabBar: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tab.panel.panes) { pane in
                        SidePanelTabChip(tab: tab, pane: pane, selected: pane.id == tab.panel.selectedId)
                    }
                }
                .padding(.vertical, 5)
            }
            Menu {
                ForEach(tabs.availablePanes(for: tab), id: \.self) { kind in
                    Button {
                        tabs.showPane(kind, in: tab)
                    } label: {
                        Label(kind.defaultTitle, systemImage: kind.symbol)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(tabs.availablePanes(for: tab).isEmpty)
            .help("Add a panel tab")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.bar)
    }
}

struct SidePanelTabChip: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let pane: PanelPane
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pane.kind.symbol).font(.caption)
            Text(tabs.paneTitle(pane.kind, in: tab)).font(.callout).lineLimit(1)
            Button { tabs.closePane(pane, in: tab) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.borderless)
                .opacity(hovering || selected ? 1 : 0)
                .help("Close this panel tab" + (selected ? " (⌘⌃W)" : ""))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(selected ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.06) : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture { tabs.selectPane(pane, in: tab) }
        .onHover { hovering = $0 }
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
