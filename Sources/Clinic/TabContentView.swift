import AppKit
import SwiftUI
import ClinicCore
import GhosttyBridge

/// Persistent AppKit content for one tab (ADR-019 refined): the agent surface lives here for the tab's
/// whole life and is never re-parented by SwiftUI. The right-hand panel (ADR-079) is a tab strip hosted
/// in an `NSHostingView` above a content area that shows either a SwiftUI page or a shell surface.
@MainActor
final class TabContentView: NSView, NSSplitViewDelegate {
    /// What the panel should show right now; `nil` hides the panel entirely.
    struct PanelContent {
        let chrome: AnyView
        let page: AnyView?
        let terminal: GhosttySurfaceView?
        let minWidth: CGFloat
    }

    private let outer = NSSplitView()             // left: agent surface, right: panel
    private let surfaceHost = SurfaceHostView()
    private let panel = SidePanelHostView()
    private var rightMin: CGFloat = 320
    private let leftMin: CGFloat = 360
    /// True while the panel is being installed and positioned, when the split view hands it interim
    /// widths of its own that must not be mistaken for a width the user chose.
    private var isAdjusting = false

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

    init(surface: GhosttySurfaceView) {
        super.init(frame: .zero)
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.delegate = self
        surfaceHost.addSubview(surface)
        surface.frame = surfaceHost.bounds
        outer.addArrangedSubview(surfaceHost)
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
        guard !isAdjusting, width >= 200, abs(width - Self.savedWidth) >= 1 else { return }
        Self.savedWidth = width
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as AnyObject? === outer, panel.superview != nil else { return }
        rememberWidth()
    }

    /// Smoke hook (`-ClinicDragPanelTo <points>`): stands in for a divider drag, which the tests cannot do.
    func setPanelWidth(_ width: CGFloat) {
        guard outer.arrangedSubviews.count == 2, outer.bounds.width > 0 else { return }
        outer.setPosition(max(leftMin, outer.bounds.width - width - outer.dividerThickness), ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, leftMin)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - rightMin - splitView.dividerThickness)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// The panel itself: a SwiftUI tab strip (the height of the session tab bar) over a content area that holds at most one
/// hosted page and the shell surface, so switching panel tabs never re-parents a libghostty surface.
/// Everything is pinned with constraints: an `NSHostingView` given only a frame collapses to its
/// fitting size.
@MainActor
final class SidePanelHostView: NSView {
    private static let barHeight: CGFloat = 34

    private let chromeHost = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    private let content = NSView()
    private var pageHost: NSHostingView<AnyView>?
    private let terminalHost = SurfaceHostView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chromeHost.sizingOptions = []
        for v in [chromeHost, content, terminalHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(chromeHost)
        addSubview(content)
        content.addSubview(terminalHost)
        terminalHost.isHidden = true
        NSLayoutConstraint.activate([
            chromeHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeHost.topAnchor.constraint(equalTo: topAnchor),
            chromeHost.heightAnchor.constraint(equalToConstant: Self.barHeight),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + Self.pin(terminalHost, to: content))
    }

    required init?(coder: NSCoder) { nil }

    private static func pin(_ view: NSView, to container: NSView) -> [NSLayoutConstraint] {
        [view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
         view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
         view.topAnchor.constraint(equalTo: container.topAnchor),
         view.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
    }

    func apply(_ c: TabContentView.PanelContent) {
        chromeHost.rootView = c.chrome
        if let page = c.page {
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
        terminalHost.show(c.terminal)
        terminalHost.isHidden = c.terminal == nil
        // This view's frame comes from the split view, so its constraint subtree is only resolved on
        // demand: without this a freshly added host stays at zero size and renders blank.
        needsLayout = true
        layoutSubtreeIfNeeded()
        // This view's frame comes from the split view, so its constraint subtree is only resolved on
        // demand: without this a freshly added host stays at zero size and renders blank.
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Drops the hosted page when the panel closes; the shell surface goes back to its pane's keeping.
    func clear() {
        pageHost?.removeFromSuperview()
        pageHost = nil
        terminalHost.show(nil)
        terminalHost.isHidden = true
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
