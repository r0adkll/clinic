import SwiftUI
import AppKit
import ClinicCore

/// Terminal on the left, a page on the right, in a native NSSplitView: smooth live resize, native divider hit
/// area and cursor, position remembered by AppKit's autosave. Environment objects are re-injected into the
/// hosted SwiftUI trees because NSHostingView does not inherit them.
struct RightSplit<Left: View, Right: View>: NSViewRepresentable {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(PRStore.self) private var prs
    @Environment(NotificationStore.self) private var history
    @Environment(UsageService.self) private var usage
    let leftMin: CGFloat
    let rightMin: CGFloat
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right

    init(leftMin: CGFloat = 360, rightMin: CGFloat = 320, @ViewBuilder left: @escaping () -> Left, @ViewBuilder right: @escaping () -> Right) {
        self.leftMin = leftMin; self.rightMin = rightMin; self.left = left; self.right = right
    }

    func makeCoordinator() -> Coordinator { Coordinator(leftMin: leftMin, rightMin: rightMin) }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        let leftHost = NSHostingView(rootView: inject(left()))
        let rightHost = NSHostingView(rootView: inject(right()))
        leftHost.translatesAutoresizingMaskIntoConstraints = false
        rightHost.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(leftHost)
        split.addArrangedSubview(rightHost)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)          // the terminal absorbs window resizes
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)      // the page keeps its width
        split.autosaveName = "ClinicRightPane"
        context.coordinator.leftHost = leftHost
        context.coordinator.rightHost = rightHost
        DispatchQueue.main.async {
            // First appearance without a saved position: give the page a sensible width.
            if split.subviews[1].frame.width < rightMin { split.setPosition(max(leftMin, split.bounds.width - 480), ofDividerAt: 0) }
        }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.leftHost?.rootView = inject(left())
        context.coordinator.rightHost?.rootView = inject(right())
    }

    private func inject<V: View>(_ v: V) -> AnyView {
        AnyView(v.environment(tabs).environment(sessions).environment(prs).environment(history).environment(usage))
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        let leftMin: CGFloat
        let rightMin: CGFloat
        var leftHost: NSHostingView<AnyView>?
        var rightHost: NSHostingView<AnyView>?
        init(leftMin: CGFloat, rightMin: CGFloat) { self.leftMin = leftMin; self.rightMin = rightMin }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(proposedMinimumPosition, leftMin)
        }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            min(proposedMaximumPosition, splitView.bounds.width - rightMin - splitView.dividerThickness)
        }
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    }
}
