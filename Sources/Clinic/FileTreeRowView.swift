import SwiftUI
import ClinicCore

/// Metrics every file list in the app shares (ADR-099): the Files panel's repo tree, the pull
/// request panel's changed-file tree and its filter results, and Quick Open. One place, so the four
/// of them indent, size and highlight identically.
enum FileTreeMetrics {
    /// AppKit's source-list row height. Every row is a hit target this tall and the *full* width of
    /// its column — the trees this replaced hit-tested only the label, so clicking to the right of a
    /// short file name did nothing at all.
    static let rowHeight: CGFloat = 24
    /// A two-line row (a filter hit: name over its directory) needs the second line's leading.
    static let twoLineRowHeight: CGFloat = 36
    static let indent: CGFloat = 13
    static let chevron: CGFloat = 12
    static let icon: CGFloat = 16
    /// Horizontal breathing room around the list, so the row's rounded fill is inset from the edges
    /// the way a macOS source list's is.
    static let listInset: CGFloat = 6
    static let radius: CGFloat = 5
}

/// One row of a file list: a full-width control carrying an optional disclosure chevron, a glyph,
/// the name, an optional dimmed second line, and a trailing accessory.
///
/// It is a `Button`, not a `Label` with a tap gesture. That is the whole point of ADR-099: a button's
/// label fills the row and hit-tests as one rectangle, it takes the pointer's press feedback and the
/// accessibility role for free, and — for a directory — it means the row *is* the disclosure control
/// rather than the 12 pt triangle in front of it.
struct FileTreeRowView<Accessory: View>: View {
    let name: String
    /// Shown dimmed under the name; the row grows to `twoLineRowHeight` when present.
    var subtitle: String?
    var depth: Int = 0
    var symbol: String
    /// `nil` for a leaf. A directory passes its state and gets a chevron that turns with it.
    var isExpanded: Bool?
    var isSelected: Bool = false
    var help: String?
    let accessory: () -> Accessory
    let activate: () -> Void

    @State private var hovering = false

    init(name: String,
         subtitle: String? = nil,
         depth: Int = 0,
         symbol: String,
         isExpanded: Bool? = nil,
         isSelected: Bool = false,
         help: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory,
         activate: @escaping () -> Void) {
        self.name = name
        self.subtitle = subtitle
        self.depth = depth
        self.symbol = symbol
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.help = help
        self.accessory = accessory
        self.activate = activate
    }

    private var isDirectory: Bool { isExpanded != nil }

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 4) {
                chevron
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: FileTreeMetrics.icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isDirectory && !isSelected ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        // A folded chain (`api/src/commonMain/kotlin`, ADR-091) is read from its
                        // tail: middle truncation eats the only segment that says where you are.
                        .truncationMode(name.contains("/") ? .head : .middle)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                accessory()
            }
            .padding(.leading, CGFloat(depth) * FileTreeMetrics.indent + 6)
            .padding(.trailing, 6)
            .frame(height: subtitle == nil ? FileTreeMetrics.rowHeight : FileTreeMetrics.twoLineRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The fill and the hit shape are the same rectangle, so what looks clickable is what is.
            .contentShape(Rectangle())
            .background(fill, in: RoundedRectangle(cornerRadius: FileTreeMetrics.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(help ?? name)
    }

    /// A directory's chevron. Files reserve the same width so names line up down the column.
    @ViewBuilder
    private var chevron: some View {
        Group {
            if let isExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.12), value: isExpanded)
            }
        }
        .frame(width: FileTreeMetrics.chevron)
    }
}

/// A generic parameter cannot be inferred from a default argument, so the accessory-less row — most
/// of them — needs its own initialiser, the way SwiftUI's own containers do it.
extension FileTreeRowView where Accessory == EmptyView {
    init(name: String,
         subtitle: String? = nil,
         depth: Int = 0,
         symbol: String,
         isExpanded: Bool? = nil,
         isSelected: Bool = false,
         help: String? = nil,
         activate: @escaping () -> Void) {
        self.init(name: name, subtitle: subtitle, depth: depth, symbol: symbol, isExpanded: isExpanded,
                  isSelected: isSelected, help: help, accessory: { EmptyView() }, activate: activate)
    }
}

/// The scroll container every file list uses.
///
/// A `ScrollView` + `LazyVStack`, not a `List`. macOS `List` inserts about 8 pt of its own spacing
/// between rows, and `listRowSpacing` — the one control for it — is `unavailable` on macOS, so a
/// tree drew at a 32 pt pitch and lost a quarter of the rows a panel column can hold. Measured side
/// by side in a harness before choosing (ADR-099). `LazyVStack` is lazy, so a 50 000-file repo still
/// builds only the rows on screen.
struct FileTreeScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, FileTreeMetrics.listInset)
                .padding(.vertical, 4)
        }
    }
}

/// A heading over a group of rows, in place of a `List` section header.
struct FileTreeSectionHeader: View {
    let title: String
    var top: CGFloat = 8

    init(_ title: String, top: CGFloat = 8) { self.title = title; self.top = top }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .padding(.top, top)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum FileGlyph {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "txt", "rst", "adoc": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns", "pdf": return "photo"
        case "sh", "fish", "zsh", "bash", "bat": return "terminal"
        case "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "py", "rb", "js", "ts", "tsx", "jsx", "kt", "java": return "chevron.left.forwardslash.chevron.right"
        case "lock", "resolved": return "lock"
        default: return "doc"
        }
    }
}
