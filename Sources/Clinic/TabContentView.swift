import AppKit
import SwiftUI
import ClinicCore
import GhosttyBridge

/// Persistent AppKit content for one tab (ADR-019 refined): the terminal surfaces live here for the tab's
/// whole life and are never re-parented by SwiftUI; the right-column page is an NSHostingView that is
/// added and removed inside this view.
@MainActor
final class TabContentView: NSView, NSSplitViewDelegate {
    private let outer = NSSplitView()        // left: terminals, right: page
    private let terminals = NSSplitView()    // top: agent surface, bottom: shell panel
    private let surfaceHost = SurfaceHostView()
    private let panelHost = SurfaceHostView()
    private var pageHost: NSHostingView<AnyView>?
    private var rightMin: CGFloat = 320
    private let leftMin: CGFloat = 360

    init(surface: GhosttySurfaceView) {
        super.init(frame: .zero)
        outer.isVertical = true
        outer.dividerStyle = .thin
        outer.delegate = self
        outer.autosaveName = "ClinicRightPane"
        terminals.isVertical = false
        terminals.dividerStyle = .thin
        terminals.autosaveName = "ClinicPanelSplit"
        surfaceHost.addSubview(surface)
        surface.frame = surfaceHost.bounds
        terminals.addArrangedSubview(surfaceHost)
        outer.addArrangedSubview(terminals)
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

    /// Shows or hides the shell panel below the agent surface.
    func setPanel(_ panel: GhosttySurfaceView?) {
        if let panel {
            if panel.superview !== panelHost { panel.removeFromSuperview(); panelHost.addSubview(panel); panel.frame = panelHost.bounds }
            if !terminals.arrangedSubviews.contains(panelHost) {
                terminals.addArrangedSubview(panelHost)
                terminals.setHoldingPriority(.defaultLow, forSubviewAt: 0)
                DispatchQueue.main.async { [terminals] in
                    if terminals.arrangedSubviews.count == 2 { terminals.setPosition(max(120, terminals.bounds.height - 220), ofDividerAt: 0) }
                }
            }
        } else if terminals.arrangedSubviews.contains(panelHost) {
            terminals.removeArrangedSubview(panelHost)
            panelHost.removeFromSuperview()
        }
    }

    /// Shows a page on the right, replaces its content, or removes it.
    func setPage(_ view: AnyView?, minWidth: CGFloat) {
        rightMin = minWidth
        guard let view else {
            if let h = pageHost { outer.removeArrangedSubview(h); h.removeFromSuperview(); pageHost = nil }
            return
        }
        if let h = pageHost {
            h.rootView = view
        } else {
            let h = NSHostingView(rootView: view)
            h.sizingOptions = []
            h.translatesAutoresizingMaskIntoConstraints = false
            outer.addArrangedSubview(h)
            outer.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
            pageHost = h
            DispatchQueue.main.async { [outer, rightMin, leftMin] in
                if outer.arrangedSubviews.count == 2, outer.arrangedSubviews[1].frame.width < rightMin {
                    outer.setPosition(max(leftMin, outer.bounds.width - max(480, rightMin)), ofDividerAt: 0)
                }
            }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === outer ? max(proposedMinimumPosition, leftMin) : max(proposedMinimumPosition, 120)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === outer ? min(proposedMaximumPosition, splitView.bounds.width - rightMin - splitView.dividerThickness) : proposedMaximumPosition
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// Keeps its single subview (a surface) sized to its bounds.
final class SurfaceHostView: NSView {
    override func layout() {
        super.layout()
        for v in subviews { v.frame = bounds }
    }
}
