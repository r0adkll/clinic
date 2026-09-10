import SwiftUI
import AppKit

/// The chrome every file browser shares (ADR-102): the Files panel, the pull request panel's Files
/// tab and the Diff panel all put a list beside a detail view, and this is everything around the
/// rows — which `FileTreeRowView` already unified (ADR-099).

enum PaneMetrics {
    /// Taller than a row (`FileTreeMetrics.rowHeight`), so a header reads as chrome over its list
    /// rather than as the first row of it. Both columns of a pane use it, so their headers are one
    /// band rather than two headers of different heights side by side.
    static let headerHeight: CGFloat = 28
    static let padding: CGFloat = 8
}

/// One column's header.
struct PaneHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, PaneMetrics.padding)
            .frame(height: PaneMetrics.headerHeight)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

/// Shows and hides a browser's list column.
///
/// It lives at the pane's **top-left in both states** — in the list's header while the list is open,
/// in the detail header once it is not. That keeps ADR-081's rule that the toggle can never hide
/// itself, and adds one it did not have: the button does not move when the list opens.
struct TreeToggleButton: View {
    @Binding var isOn: Bool
    var shownHelp = "Hide the file list"
    var hiddenHelp = "Show the file list"

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "sidebar.left" : "sidebar.leading")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        .help(isOn ? shownHelp : hiddenHelp)
    }
}

/// Filters a list from its own header. A tree while browsing, a ranked flat list while filtering:
/// searching is a different act from browsing, and the hierarchy is noise once you are typing a name.
struct TreeFilterField: View {
    @Binding var text: String
    /// Shown inside the field while filtering, so the count cannot squeeze the field out of a
    /// 180 pt column when it is not needed.
    var matches: Int?
    var total: Int?

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($focused)
                .onKeyPress(.escape) {
                    if text.isEmpty { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                if let matches, let total {
                    Text("\(matches)/\(total)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The draggable seam between a list column and its detail column.
///
/// The gesture measures in **global** space: the handle moves as it is dragged, so a `.local`
/// translation is taken against an origin that has just moved and the column chases the pointer
/// (ADR-081). `commit` fires when the drag ends rather than on every frame, so a stored width is
/// written once per drag and not many times a second.
struct TreeSplitHandle: View {
    @Binding var width: CGFloat
    /// The width actually on screen when the drag starts; a stored width may be clamped smaller.
    let base: CGFloat
    let clamp: (CGFloat) -> CGFloat
    var commit: ((CGFloat) -> Void)?

    @State private var start: CGFloat?

    var body: some View {
        // One pixel of *layout*, so the two columns meet at a line rather than across a gap: a 9 pt
        // strip of the pane's own background between them read as a seam that had come apart. The
        // grab area is an overlay, which is wider than the line without taking any width from it.
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let from = start ?? base
                                if start == nil { start = from }
                                width = clamp(from + value.translation.width)
                            }
                            .onEnded { _ in
                                start = nil
                                commit?(width.rounded())
                            }
                    )
            }
            .zIndex(1)
    }
}
