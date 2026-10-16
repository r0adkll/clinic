import AppKit
import SwiftUI
import ClinicCore
import GhosttyBridge
import UniformTypeIdentifiers

/// Persistent AppKit content for one tab (ADR-019 refined): the agent surface lives here for the tab's
/// whole life and is never re-parented by SwiftUI. The workspace's two areas (ADR-212) — the main area,
/// with Claude pinned first, and the right panel (ADR-079) — are each a tab strip hosted in an
/// `NSHostingView` above a content area that shows a SwiftUI page or a surface.
@MainActor
final class TabContentView: NSView, NSSplitViewDelegate {
    /// What an area should show right now; `nil` hides the right panel entirely.
    struct PanelContent {
        let chrome: AnyView
        let page: AnyView?
        let terminal: GhosttySurfaceView?
        /// The main area shows Claude's own surface, which never leaves its host (ADR-212).
        var showsAgent = false
        /// A band above the terminal and a bar below it: the Run pane's header and failure bar (ADR-122).
        var terminalHeader: AnyView? = nil
        var terminalFooter: AnyView? = nil
        let minWidth: CGFloat
    }

    private let outer = NSSplitView()             // left: main area, right: panel
    private let main: PaneHostView
    private let panel = PaneHostView()
    private var rightMin: CGFloat = 320
    /// The main area's floor: the terminal's 360 pt, or more for a wider pane in front of it.
    private var leftMin: CGFloat = 360
    /// True while the panel is being installed and positioned, when the split view hands it interim
    /// widths of its own that must not be mistaken for a width the user chose.
    private var isAdjusting = false

    /// True when the keyboard is somewhere inside the panel — the image viewer, a code view, a
    /// filter field. The agent surface reclaims the keyboard whenever the terminal stack re-renders
    /// (ADR-081); that must not include taking it out of the panel, where the reader put it with a
    /// click. Adding an image re-renders the stack, so before this every `show_image` and every ⌘⌫
    /// moved the keyboard back to the terminal mid-use (found 2026-09-10, ADR-107).
    var panelHoldsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === panel || responder.isDescendant(of: panel)
    }

    /// True when the keyboard is in a page or a shell in the main area, rather than in Claude: a
    /// re-render must not pull it back into a surface that is not on screen.
    var mainPaneHoldsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return (responder === main || responder.isDescendant(of: main)) && !main.isAgent(responder)
    }

    /// The width the user last settled the panel at: shared by every tab and window, kept across launches.
    /// Hiding the panel takes it out of the split view, so its own autosave cannot do this for us.
    private static let widthKey = "ClinicPanelWidth"
    private static var savedWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: widthKey)
            return stored > 0 ? CGFloat(stored) : 480
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: widthKey) }
    }

    /// A dragged tab over the content (ADR-218): which area holds it now, nil for another session's, and the
    /// move a drop makes. Set by `TabStore`, which owns the panes.
    var paneArea: ((UUID) -> PaneDropZones.Area?)?
    var onPaneDrop: ((UUID, PaneDropZones.Area) -> Bool)?
    private let dropHighlight = DropZoneHighlightView()

    init(surface: GhosttySurfaceView) {
        main = PaneHostView(agent: surface)
        super.init(frame: .zero)
        // The strips take a tab dropped on them; this takes one dropped on an area's content. The surfaces take
        // text and files, not this type, so the drag passes them up to here.
        registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.clinicPane.identifier)])
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.delegate = self
        outer.addArrangedSubview(main)
        outer.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        outer.translatesAutoresizingMaskIntoConstraints = true
        outer.autoresizingMask = [.width, .height]
        addSubview(outer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        outer.frame = bounds
    }

    /// Shows or updates the main area: its strip, and Claude or the pane in front.
    func setMain(_ content: PanelContent) {
        leftMin = max(360, content.minWidth)
        main.apply(content)
        // A wider pane came to the front of the main area: give it room by narrowing the panel, never
        // past the panel's own minimum.
        if outer.arrangedSubviews.count == 2, main.frame.width < leftMin, outer.bounds.width > 0 {
            outer.setPosition(min(leftMin, outer.bounds.width - rightMin - outer.dividerThickness), ofDividerAt: 0)
        }
    }

    /// Shows, updates or hides the right-hand panel.
    func setPanel(_ content: PanelContent?) {
        guard let content else {
            if panel.superview != nil {
                rememberWidth()
                outer.removeArrangedSubview(panel)
                panel.removeFromSuperview()
                panel.clear()
            }
            return
        }
        rightMin = content.minWidth
        let isNew = panel.superview == nil
        if isNew {
            isAdjusting = true
            outer.addArrangedSubview(panel)
            outer.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        }
        panel.apply(content)
        guard outer.arrangedSubviews.count == 2 else { isAdjusting = false; return }
        if isNew {
            // The panel is added mid-session, so size it now: a hosting view first laid out at zero
            // stays blank until something else forces a pass (it used to take a divider drag).
            layoutSubtreeIfNeeded()
            if outer.bounds.width > 0 {
                openDivider(for: content.minWidth)
                isAdjusting = false
            } else {
                openDividerWhenSized()
            }
            panel.layoutSubtreeIfNeeded()
        } else if panel.frame.width < content.minWidth {
            // A wider pane (the editor) came to the front: give it room without shrinking the terminal below its own minimum.
            openDivider(for: content.minWidth)
        }
    }

    /// Opens the divider to the width the user last chose, widened for the pane's minimum and never
    /// past the terminal's own minimum.
    private func openDivider(for minWidth: CGFloat) {
        guard outer.bounds.width > 0 else { return }
        let want = max(minWidth, Self.savedWidth)
        outer.setPosition(max(leftMin, outer.bounds.width - want - outer.dividerThickness), ofDividerAt: 0)
    }

    /// The panel was added before the window had a width (launch): wait for one, then restore, keeping
    /// the interim widths off the record until we have.
    private func openDividerWhenSized(attempt: Int = 0) {
        guard outer.bounds.width == 0, attempt < 5 else {
            openDivider(for: rightMin)
            isAdjusting = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.openDividerWhenSized(attempt: attempt + 1) }
        }
    }

    /// Records the panel's current width. Ignores widths below any pane minimum, which are only ever the
    /// transient sizes a freshly added arranged subview passes through.
    private func rememberWidth() {
        let width = panel.frame.width
        guard !isAdjusting, panel.superview === outer, width >= 200, abs(width - Self.savedWidth) >= 1 else { return }
        Self.savedWidth = width
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as AnyObject? === outer, panel.superview === outer else { return }
        rememberWidth()
    }

    /// Smoke hook (`-ClinicDragPanelTo <points>`): stands in for a divider drag, which the tests cannot do.
    func setPanelWidth(_ width: CGFloat) {
        guard outer.arrangedSubviews.count == 2, outer.bounds.width > 0 else { return }
        outer.setPosition(max(leftMin, outer.bounds.width - width - outer.dividerThickness), ofDividerAt: 0)
    }

    // MARK: Dropping a tab on an area (ADR-218)

    private func dragTarget(_ info: NSDraggingInfo) -> (id: UUID, target: PaneDropZones.Target)? {
        guard let data = info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(UTType.clinicPane.identifier)),
              let item = try? JSONDecoder().decode(PaneDragItem.self, from: data),
              let from = paneArea?(item.id) else { return nil }
        let p = convert(info.draggingLocation, from: nil)
        let rect = { (v: NSView) -> PaneDropZones.Rect in
            let r = v.convert(v.bounds, to: self)
            return .init(x: r.minX, y: r.minY, width: r.width, height: r.height)
        }
        let panelRect = panel.superview != nil ? rect(panel) : nil
        guard let target = PaneDropZones.target(x: p.x, y: p.y, main: rect(main), panel: panelRect, from: from) else { return nil }
        return (item.id, target)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let hit = dragTarget(sender) else { dropHighlight.removeFromSuperview(); return [] }
        let h = hit.target.highlight
        dropHighlight.show(hit.target.area == .right ? "Open in Right Panel" : "Move Beside Claude",
                           in: NSRect(x: h.x, y: h.y, width: h.width, height: h.height).insetBy(dx: 6, dy: 6), over: self)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight.removeFromSuperview() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropHighlight.removeFromSuperview() }
        guard let hit = dragTarget(sender) else { return false }
        return onPaneDrop?(hit.id, hit.target.area) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropHighlight.removeFromSuperview() }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, leftMin)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - rightMin - splitView.dividerThickness)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// One area of the workspace: a SwiftUI tab strip over a content area that holds at most one hosted
/// page and one shell or run surface, so switching tabs never re-parents a libghostty surface. The main
/// area also holds Claude's surface for the tab's whole life, shown while its pinned tab is in front
/// (ADR-212). Everything is pinned with constraints: an `NSHostingView` given only a frame collapses to
/// its fitting size.
@MainActor
final class PaneHostView: NSView {
    private static let barHeight: CGFloat = 34

    private let chromeHost = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    private let content = NSView()
    private var pageHost: NSHostingView<AnyView>?
    private let terminalHost = SurfaceHostView()
    /// The Run pane's header band and failure bar, around the surface (ADR-122). Zero height when unused.
    private let terminalHeaderHost = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    private let terminalFooterHost = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    private lazy var headerHeight = terminalHeaderHost.heightAnchor.constraint(equalToConstant: 0)
    private lazy var footerHeight = terminalFooterHost.heightAnchor.constraint(equalToConstant: 0)
    private static let footerBarHeight: CGFloat = 44
    /// Claude's surface, in the main area only. Added once and never shown through `show`, which would
    /// re-parent it.
    private let agentHost: SurfaceHostView?
    private let agent: GhosttySurfaceView?

    init(agent: GhosttySurfaceView? = nil) {
        self.agent = agent
        self.agentHost = agent.map { surface in
            let host = SurfaceHostView()
            host.addSubview(surface)
            return host
        }
        super.init(frame: .zero)
        chromeHost.sizingOptions = []
        terminalHeaderHost.sizingOptions = []
        terminalFooterHost.sizingOptions = []
        for v in [chromeHost, content, terminalHost, terminalHeaderHost, terminalFooterHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(chromeHost)
        addSubview(content)
        content.addSubview(terminalHeaderHost)
        content.addSubview(terminalHost)
        content.addSubview(terminalFooterHost)
        terminalHost.isHidden = true
        if let agentHost {
            agentHost.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(agentHost)
            NSLayoutConstraint.activate(Self.pin(agentHost, to: content))
        }
        NSLayoutConstraint.activate([
            chromeHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeHost.topAnchor.constraint(equalTo: topAnchor),
            chromeHost.heightAnchor.constraint(equalToConstant: Self.barHeight),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalHeaderHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalHeaderHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHeaderHost.topAnchor.constraint(equalTo: content.topAnchor),
            headerHeight,
            terminalFooterHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalFooterHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalFooterHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footerHeight,
            terminalHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: terminalHeaderHost.bottomAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: terminalFooterHost.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private static func pin(_ view: NSView, to container: NSView) -> [NSLayoutConstraint] {
        [view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
         view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
         view.topAnchor.constraint(equalTo: container.topAnchor),
         view.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
    }

    /// Whether this responder is Claude's surface, or inside it.
    func isAgent(_ view: NSView) -> Bool {
        guard let agent else { return false }
        return view === agent || view.isDescendant(of: agent)
    }

    func apply(_ c: TabContentView.PanelContent) {
        chromeHost.rootView = c.chrome
        agentHost?.isHidden = !c.showsAgent
        if let page = c.page, !c.showsAgent {
            if let host = pageHost {
                host.rootView = page
            } else {
                let host = NSHostingView(rootView: page)
                host.sizingOptions = []
                host.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(host)
                NSLayoutConstraint.activate(Self.pin(host, to: content))
                pageHost = host
            }
        } else {
            pageHost?.removeFromSuperview()
            pageHost = nil
        }
        let terminal = c.showsAgent ? nil : c.terminal
        terminalHost.show(terminal)
        terminalHost.isHidden = terminal == nil
        let header = terminal == nil ? nil : c.terminalHeader
        let footer = terminal == nil ? nil : c.terminalFooter
        terminalHeaderHost.rootView = header ?? AnyView(EmptyView())
        terminalFooterHost.rootView = footer ?? AnyView(EmptyView())
        headerHeight.constant = header == nil ? 0 : PaneMetrics.headerHeight
        footerHeight.constant = footer == nil ? 0 : Self.footerBarHeight
        terminalHeaderHost.isHidden = header == nil
        terminalFooterHost.isHidden = footer == nil
        // This view's frame comes from its host, so its constraint subtree is only resolved on demand:
        // without this a freshly added host stays at zero size and renders blank.
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Drops the hosted page when the panel closes; the shell surface goes back to its pane's keeping.
    func clear() {
        pageHost?.removeFromSuperview()
        pageHost = nil
        terminalHost.show(nil)
        terminalHost.isHidden = true
        terminalHeaderHost.rootView = AnyView(EmptyView())
        terminalFooterHost.rootView = AnyView(EmptyView())
    }
}

/// Keeps its single subview (a surface) sized to its bounds. `show` swaps that surface, so a freed one
/// never lingers underneath the next.
final class SurfaceHostView: NSView {
    func show(_ surface: NSView?) {
        for v in subviews where v !== surface { v.removeFromSuperview() }
        guard let surface, surface.superview !== self else { return }
        surface.removeFromSuperview()
        addSubview(surface)
        surface.frame = bounds
    }

    override func layout() {
        super.layout()
        for v in subviews { v.frame = bounds }
    }
}

/// The zone a dragged tab would drop into (ADR-218): an accent wash with an accent border and what the drop
/// does, in the middle. It never takes the mouse, so it cannot get in the way of the drag it describes.
@MainActor
final class DropZoneHighlightView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, in rect: NSRect, over host: NSView) {
        let accent = NSColor.controlAccentColor
        layer?.backgroundColor = accent.withAlphaComponent(0.14).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.7).cgColor
        label.stringValue = text
        label.textColor = accent
        frame = rect
        if superview !== host { host.addSubview(self, positioned: .above, relativeTo: nil) }
    }
}

