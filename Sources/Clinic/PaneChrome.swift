import SwiftUI
import AppKit

/// The chrome every file browser shares (ADR-102): the Files panel, the pull request panel's Files
/// tab and the Diff panel all put a list beside a detail view, and this is everything around the
/// rows — which `FileTreeRowView` already unified (ADR-099).
///
/// Sizing is ADR-103's: the band, its controls and the rows under it are all a step larger than the
/// caption-sized chrome they started as, and every icon in a header is a control-sized target with a
/// fill of its own rather than a bare glyph.

enum PaneMetrics {
    /// Tall enough to hold a 24 pt control with breathing room above and below, which is what makes
    /// the header read as chrome over its list rather than as the first row of it. Both columns of a
    /// pane use it, so their headers are one band rather than two headers of different heights.
    static let headerHeight: CGFloat = 34
    static let padding: CGFloat = 8
    /// A header icon button's square hit target. The glyph inside it is 13 pt; the target is what
    /// you aim at, and it used to be only as large as the glyph.
    static let control: CGFloat = 24
    /// A header text field's height. It fills the band the way a control does, so the field is a
    /// visible place to click rather than a tinted sliver.
    static let fieldHeight: CGFloat = 24
    static let radius: CGFloat = 5
    /// Point size for a header's glyphs. `.caption` is 10 pt on macOS, which is what made these read
    /// as decoration rather than as buttons — and several of these symbols (`eye.slash`, the
    /// collapse arrows) are thin line art that needs the size more than a filled glyph would.
    static let glyph: CGFloat = 14
    /// Point size for a header's text: a path, a language name, a count.
    static let label: CGFloat = 12
}

/// One column's header.
struct PaneHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .padding(.horizontal, PaneMetrics.padding)
            .frame(height: PaneMetrics.headerHeight)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

/// An icon control in a pane header: a square target with its own hover and on-state fill, in the
/// same rounded-rectangle language the file rows use.
///
/// A bare `Image` in a `.borderless` button hit-tests as the glyph and nothing else, and at
/// `.controlSize(.small)` that glyph is about 11 pt — small to see and smaller to hit. This is the
/// one shape every header verb takes (ADR-103).
struct PaneIconButton: View {
    let symbol: String
    var help: String
    /// A toggle's on state: accent glyph over an accent fill, so "hidden files are showing" is
    /// legible without hovering for the tooltip.
    var isOn = false
    let action: () -> Void

    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var fill: Color {
        if !enabled { return .clear }
        // Quiet enough not to read as an alert when the accent colour is a loud one — this button is
        // on for as long as the tree is open, which is most of the time.
        if isOn { return Color.accentColor.opacity(hovering ? 0.18 : 0.11) }
        if hovering { return Color.primary.opacity(0.09) }
        return .clear
    }

    private var tint: Color {
        if !enabled { return Color.secondary.opacity(0.4) }
        return isOn ? Color.accentColor : Color.secondary
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PaneMetrics.glyph, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: PaneMetrics.control, height: PaneMetrics.control)
                .contentShape(Rectangle())
                .background(fill, in: RoundedRectangle(cornerRadius: PaneMetrics.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(help)
    }
}

/// A menu in a header, shaped like `PaneIconButton` so a menu and a button in the same band are the
/// same target and highlight the same way.
struct PaneIconMenu<Content: View>: View {
    let symbol: String
    var help: String
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        Menu { content } label: {
            Image(systemName: symbol)
                .font(.system(size: PaneMetrics.glyph, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: PaneMetrics.control, height: PaneMetrics.control)
                .contentShape(Rectangle())
                .background(hovering ? Color.primary.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: PaneMetrics.radius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(help)
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
        PaneIconButton(symbol: isOn ? "sidebar.left" : "sidebar.leading",
                       help: isOn ? shownHelp : hiddenHelp,
                       isOn: isOn) { isOn.toggle() }
    }
}

/// Filters a list from its own header. A tree while browsing, a ranked flat list while filtering:
/// searching is a different act from browsing, and the hierarchy is noise once you are typing a name.
///
/// The whole capsule is the click target and takes focus (ADR-103) — a `.plain` text field is only
/// as tall as its text, so clicking the field's own padding used to miss it.
struct TreeFilterField: View {
    @Binding var text: String
    /// Shown inside the field while filtering, so the count cannot squeeze the field out of a
    /// 180 pt column when it is not needed.
    var matches: Int?
    var total: Int?

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(focused ? Color.accentColor : Color.secondary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: PaneMetrics.label))
                .focused($focused)
                .onKeyPress(.escape) {
                    if text.isEmpty { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                if let matches, let total {
                    Text("\(matches)/\(total)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(matches == 0 ? Color.secondary : Color.primary.opacity(0.6))
                        .fixedSize()
                }
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: PaneMetrics.fieldHeight)
        .background(Color.primary.opacity(focused ? 0.04 : 0.07), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: focused ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.1), value: focused)
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
    @State private var hovering = false

    private var active: Bool { hovering || start != nil }

    var body: some View {
        // One pixel of *layout*, so the two columns meet at a line rather than across a gap: a 9 pt
        // strip of the pane's own background between them read as a seam that had come apart. The
        // grab area is an overlay, which is wider than the line without taking any width from it.
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            // The line answers the pointer before it is dragged, so the seam is findable rather than
            // something you learn is there (ADR-103).
            .overlay { Rectangle().fill(Color.accentColor).frame(width: 2).opacity(active ? 1 : 0) }
            .overlay {
                Color.clear
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .onHover { hovering = $0 }
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
            .animation(.easeOut(duration: 0.12), value: active)
            .zIndex(1)
    }
}
