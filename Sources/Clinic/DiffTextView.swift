import AppKit
import SwiftUI
import ClinicCore

/// The diff body: one read-only text view per rendered page (ADR-100).
///
/// The shape it replaces — a `LazyVStack` of row views — cost ~10.6 ms of main thread per frame at a
/// moderate scroll and 19.4 ms at a flick, almost all of it `.textSelection(.enabled)` at ~35 µs per
/// selectable `Text` (four to a row). A text view draws a viewport rather than materialising views,
/// so its cost is flat in scroll speed: 1.7–2.0 ms per frame on the same 7,524-row patch.
///
/// Every line is the same height, so all of the geometry here — which lines are visible, which file
/// the reader is inside, where a path lives, which lines to tint — is integer arithmetic. Nothing in
/// the drawing path asks the layout manager anything.

// MARK: - Metrics

@MainActor
enum DiffMetrics {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    static let headerFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)

    /// Width of one character. The font is monospaced, so this is the whole horizontal geometry.
    static let advance: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width
    /// Fixed for every line, which is what makes line ↔ y arithmetic.
    static let lineHeight: CGFloat = ceil(font.ascender - font.descender + font.leading) + 2
    /// Two line-number columns plus the +/− marker, drawn in the ruler.
    static let gutterWidth: CGFloat = 100
    static let oldColumnRight: CGFloat = 44
    static let newColumnRight: CGFloat = 84
    static let markerRight: CGFloat = 96
    /// The floating file header that stands in for ADR-080's pinned section headers.
    static let headerHeight: CGFloat = 24
    static let leftPadding: CGFloat = 6

    /// Uniform line height is what makes the geometry arithmetic.
    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.lineBreakMode = .byClipping
        return p
    }()

    /// The band behind a line, drawn full width by the body and matched by the gutter so a changed
    /// line reads as one stripe across both.
    static func band(_ kind: DiffDocument.LineKind) -> NSColor? {
        switch kind {
        case .fileHeader: NSColor.windowBackgroundColor
        case .hunk: NSColor.controlAccentColor.withAlphaComponent(0.08)
        case .code(let code): tint(code)
        }
    }

    static func tint(_ kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: NSColor.systemGreen.withAlphaComponent(0.14)
        case .deletion: NSColor.systemRed.withAlphaComponent(0.14)
        case .context, .noNewline: nil
        }
    }

    static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind { case .addition: "+"; case .deletion: "−"; case .context: " "; case .noNewline: "\\" }
    }
}

/// One coloured range within a line, in the line's own coordinates. The highlighter hands these
/// back rather than an `AttributedString` per row: they are cheap to send across an actor boundary
/// and they apply straight onto the text storage.
struct DiffToken: Sendable, Equatable {
    let range: NSRange
    let colour: DiffSyntaxTheme.RGBA
}

// MARK: - Source

/// What the body renders, held by reference. `DiffDocument` and the token table are `Equatable` and
/// enormous; handing them to a view by value makes SwiftUI deep-compare them on every update
/// (ADR-080). The generations are the cheap values a view body reads to learn something changed.
@MainActor
@Observable
final class DiffTextSource {
    private(set) var document = DiffDocument()
    private(set) var tokens: [String: [DiffToken]] = [:]
    private(set) var documentGeneration = 0
    private(set) var tokenGeneration = 0

    func replace(document: DiffDocument, keepingTokens keep: Bool) {
        self.document = document
        if !keep { tokens = [:] }
        documentGeneration += 1
    }

    func merge(tokens incoming: [String: [DiffToken]]) {
        guard !incoming.isEmpty else { return }
        tokens.merge(incoming) { _, new in new }
        tokenGeneration += 1
    }

    func clearTokens() {
        guard !tokens.isEmpty else { return }
        tokens = [:]
        tokenGeneration += 1
    }
}

/// The floating header for the file the reader is currently inside, and how far the next file's
/// header has pushed it up. Kept out of the body's own state so a scroll redraws the header alone.
@MainActor
@Observable
final class DiffStickyState {
    var file: DiffDocument.File?
    var offset: CGFloat = 0
}

// MARK: - Text view

/// Draws the full-width `+`/`−` tints and turns a click on a file header into a collapse.
final class DiffContentTextView: NSTextView {
    var document = DiffDocument()
    var onToggleCollapse: ((String) -> Void)?

    /// Explicit, because every y in this file is `line × lineHeight` from the top.
    override var isFlipped: Bool { true }

    /// `super` paints the background colour; the tints go on top of it, full width, so a changed
    /// line reads as a band across the pane rather than stopping at the end of its text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let height = DiffMetrics.lineHeight
        let first = max(0, Int(floor(rect.minY / height)))
        let last = min(document.lines.count - 1, Int(ceil(rect.maxY / height)))
        guard first <= last else { return }
        for n in first...last {
            guard let colour = DiffMetrics.band(document.lines[n].kind) else { continue }
            colour.setFill()
            NSRect(x: rect.minX, y: CGFloat(n) * height, width: rect.width, height: height).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let line = Int(floor(point.y / DiffMetrics.lineHeight))
        if document.isHeader(line: line), let file = document.file(atLine: line) {
            onToggleCollapse?(file.path)
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Gutter

/// Line numbers and the `+`/`−` marker, fixed at the left edge so scrolling sideways cannot hide
/// them — which the old in-row gutter could.
final class DiffGutterRuler: NSRulerView {
    var document = DiffDocument()

    /// One attributed string for the whole visible gutter, drawn once. Drawing each number with its
    /// own `NSString.draw(at:)` costs ~1.8 ms a frame at 55 visible lines: every call builds a
    /// layout of its own.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let visible = scrollView?.contentView.documentVisibleRect else { return }
        // The gutter overlays the body's left edge, so it paints its own ground: text scrolled
        // sideways must not show through it. `bounds`, not the rect passed in — that one is not in
        // this view's coordinates, and filling it paints over the whole window.
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let height = DiffMetrics.lineHeight
        let first = max(0, Int(floor(visible.minY / height)))
        let last = min(document.lines.count - 1, Int(ceil(visible.maxY / height)))
        guard first <= last else { return }

        // The band runs under the gutter too, so a changed line is one stripe across both.
        for n in first...last {
            guard let colour = DiffMetrics.band(document.lines[n].kind) else { continue }
            colour.setFill()
            NSRect(x: 0, y: CGFloat(n) * height - visible.minY, width: bounds.width, height: height).fill()
        }

        var text = ""
        for n in first...last {
            let line = document.lines[n]
            text.append("\t")
            text.append(line.oldNumber.map(String.init) ?? "")
            text.append("\t")
            text.append(line.newNumber.map(String.init) ?? "")
            text.append("\t")
            if case .code(let kind) = line.kind { text.append(DiffMetrics.marker(kind)) }
            text.append("\n")
        }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: DiffMetrics.font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: Self.columns,
        ])
        attributed.draw(at: NSPoint(x: 0, y: CGFloat(first) * height - visible.minY))
    }

    /// Right-aligned tab stops are what put the two number columns and the marker in their places
    /// with one draw call instead of three per line.
    private static let columns: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = DiffMetrics.lineHeight
        p.maximumLineHeight = DiffMetrics.lineHeight
        p.tabStops = [NSTextTab(textAlignment: .right, location: DiffMetrics.oldColumnRight),
                      NSTextTab(textAlignment: .right, location: DiffMetrics.newColumnRight),
                      NSTextTab(textAlignment: .right, location: DiffMetrics.markerRight)]
        return p
    }()
}

// MARK: - Attributed text

enum DiffTextRenderer {
    /// The document as attributed text: one base style per line kind, with the highlighter's tokens
    /// laid over the code. Backgrounds are drawn, not attributed, so they can span the full width.
    @MainActor
    static func attributed(_ document: DiffDocument, tokens: [String: [DiffToken]]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: document.text, attributes: [
            .font: DiffMetrics.font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: DiffMetrics.paragraph,
        ])
        out.beginEditing()
        for line in document.lines {
            switch line.kind {
            case .fileHeader:
                out.addAttributes([.font: DiffMetrics.headerFont], range: line.range)
            case .hunk:
                out.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: line.range)
            case .code(let kind):
                if kind == .noNewline {
                    out.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: line.range)
                }
                guard let id = line.rowId, let tokens = tokens[id] else { continue }
                for token in tokens {
                    let range = NSRange(location: line.range.location + token.range.location, length: token.range.length)
                    guard NSMaxRange(range) <= NSMaxRange(line.range) else { continue }
                    out.addAttribute(.foregroundColor, value: token.colour.nsColor, range: range)
                }
            }
        }
        out.endEditing()
        return out
    }
}

// MARK: - Representable

struct DiffTextRepresentable: NSViewRepresentable {
    let source: DiffTextSource
    let sticky: DiffStickyState
    /// Read by the enclosing body so SwiftUI knows when to call `updateNSView`.
    let documentGeneration: Int
    let tokenGeneration: Int
    let colorScheme: ColorScheme
    var onVisibleFileChanged: ((String?) -> Void)?
    var onToggleCollapse: ((String) -> Void)?
    @Binding var scrollTarget: String?

    func makeCoordinator() -> Coordinator { Coordinator(source: source, sticky: sticky) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.onVisibleFileChanged = onVisibleFileChanged
        coordinator.textView.onToggleCollapse = onToggleCollapse
        return coordinator.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onVisibleFileChanged = onVisibleFileChanged
        coordinator.textView.onToggleCollapse = onToggleCollapse
        coordinator.apply(documentGeneration: documentGeneration, tokenGeneration: tokenGeneration,
                          colorScheme: colorScheme)
        if let target = scrollTarget {
            coordinator.scroll(toPath: target)
            DispatchQueue.main.async { scrollTarget = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let scrollView = NSScrollView()
        let textView: DiffContentTextView
        let ruler: DiffGutterRuler
        private let source: DiffTextSource
        private let sticky: DiffStickyState
        var onVisibleFileChanged: ((String?) -> Void)?

        private var appliedDocument = -1
        private var appliedTokens = -1
        private var appliedScheme: ColorScheme?
        private var reportedFile: String?

        init(source: DiffTextSource, sticky: DiffStickyState) {
            self.source = source
            self.sticky = sticky

            // TextKit 2, built by hand: touching `textStorage` or `layoutManager` anywhere drops the
            // view back to TextKit 1.
            let content = NSTextContentStorage()
            let layout = NSTextLayoutManager()
            content.addTextLayoutManager(layout)
            // Finite, so no line ever wraps but no layout arithmetic runs into infinity either.
            let container = NSTextContainer(size: NSSize(width: 1_000_000, height: 1_000_000))
            container.widthTracksTextView = false
            container.lineFragmentPadding = 0
            layout.textContainer = container
            self.contentStorage = content
            textView = DiffContentTextView(frame: .zero, textContainer: container)
            ruler = DiffGutterRuler(scrollView: scrollView, orientation: .verticalRuler)
            super.init()

            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            // The gutter is an overlay — AppKit does not inset the clip view for a ruler — so the
            // text is inset past it instead. `textContainerInset` is the one offset TextKit applies
            // to drawing as well as layout: a paragraph head indent lays out at the right x and then
            // draws the run shifted left underneath the gutter.
            textView.textContainerInset = NSSize(width: DiffMetrics.gutterWidth + DiffMetrics.leftPadding, height: 0)
            // The frame is arithmetic (lines × height, columns × advance). Letting the text view
            // size itself instead forces a full-document layout on every rebuild: 222 ms for 7,580
            // lines against 14 ms with this off.
            textView.isVerticallyResizable = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = []

            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor
            ruler.clientView = textView
            ruler.ruleThickness = DiffMetrics.gutterWidth
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true

            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: scrollView.contentView)
            scrollView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(resized),
                                                   name: NSView.frameDidChangeNotification,
                                                   object: scrollView)
        }

        private let contentStorage: NSTextContentStorage

        deinit { NotificationCenter.default.removeObserver(self) }

        func apply(documentGeneration: Int, tokenGeneration: Int, colorScheme: ColorScheme) {
            let schemeChanged = appliedScheme != colorScheme
            appliedScheme = colorScheme
            if documentGeneration != appliedDocument || schemeChanged {
                appliedDocument = documentGeneration
                appliedTokens = tokenGeneration
                rebuild()
            } else if tokenGeneration != appliedTokens {
                appliedTokens = tokenGeneration
                rebuild()
            }
            resize()
        }

        /// The whole document is re-attributed rather than patched in place: building it is ~20 ms
        /// for 7,500 lines, and a page only changes on a reload, a collapse or a highlight landing.
        private func rebuild() {
            let document = source.document
            textView.document = document
            ruler.document = document
            contentStorage.attributedString = DiffTextRenderer.attributed(document, tokens: source.tokens)
            resize()
            textView.needsDisplay = true
            ruler.needsDisplay = true
            updateSticky()
        }

        /// Height is lines × line height; width is the longest line × advance, never less than the
        /// viewport, so short diffs fill the pane instead of floating in it.
        private func resize() {
            let document = source.document
            let viewport = scrollView.contentSize.width
            // The inset is symmetric, so the content width carries it twice.
            let inset = (DiffMetrics.gutterWidth + DiffMetrics.leftPadding) * 2
            let width = max(viewport, inset + CGFloat(document.columns) * DiffMetrics.advance)
            let height = max(scrollView.contentSize.height, CGFloat(document.lines.count) * DiffMetrics.lineHeight)
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            if textView.frame != frame { textView.frame = frame }
        }

        @objc private func scrolled() {
            updateSticky()
            ruler.needsDisplay = true
        }

        @objc private func resized() {
            resize()
            updateSticky()
        }

        /// The file the reader is inside, and how far the next file's header has pushed its floating
        /// header up. Hidden while the file's own header line is on screen, so it is never doubled.
        private func updateSticky() {
            let document = source.document
            let y = scrollView.contentView.bounds.origin.y
            let topLine = Int(floor(y / DiffMetrics.lineHeight))
            guard let index = document.fileIndex(atLine: topLine) else {
                setSticky(nil, offset: 0)
                report(nil)
                return
            }
            let file = document.files[index]
            report(file.path)
            let headerY = CGFloat(file.headerLine) * DiffMetrics.lineHeight
            guard headerY < y else {
                setSticky(nil, offset: 0)
                return
            }
            let nextHeaderY = CGFloat(file.headerLine + file.lineCount) * DiffMetrics.lineHeight
            setSticky(file, offset: min(0, nextHeaderY - y - DiffMetrics.headerHeight))
        }

        /// Assigning an `@Observable` property notifies whether or not the value changed, and this
        /// runs on every scroll frame — so only real changes are published.
        private func setSticky(_ file: DiffDocument.File?, offset: CGFloat) {
            if sticky.file != file { sticky.file = file }
            if sticky.offset != offset { sticky.offset = offset }
        }

        /// Asynchronously, because a rebuild reports from inside `updateNSView`, and SwiftUI must
        /// not be asked to change state in the middle of its own update.
        private func report(_ path: String?) {
            guard path != reportedFile else { return }
            reportedFile = path
            DispatchQueue.main.async { [weak self] in self?.onVisibleFileChanged?(path) }
        }

        func scroll(toPath path: String) {
            guard let file = source.document.file(path: path) else { return }
            let y = CGFloat(file.headerLine) * DiffMetrics.lineHeight
            let maxY = max(0, textView.frame.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: min(y, maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

// MARK: - The view

/// The diff body plus its floating file header.
struct DiffTextBody: View {
    let source: DiffTextSource
    var onVisibleFileChanged: ((String?) -> Void)? = nil
    var onToggleCollapse: ((String) -> Void)? = nil
    @Binding var scrollTarget: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var sticky = DiffStickyState()

    var body: some View {
        ZStack(alignment: .top) {
            DiffTextRepresentable(source: source,
                                  sticky: sticky,
                                  documentGeneration: source.documentGeneration,
                                  tokenGeneration: source.tokenGeneration,
                                  colorScheme: colorScheme,
                                  onVisibleFileChanged: onVisibleFileChanged,
                                  onToggleCollapse: onToggleCollapse,
                                  scrollTarget: $scrollTarget)
            StickyFileHeader(state: sticky, toggle: onToggleCollapse)
        }
    }
}

/// Stands in for ADR-080's pinned section headers: one floating header for the file at the top of
/// the viewport, pushed up by the next file's header as it arrives.
private struct StickyFileHeader: View {
    let state: DiffStickyState
    let toggle: ((String) -> Void)?

    var body: some View {
        if let file = state.file {
            DiffFileHeader(path: file.path, additions: file.additions, deletions: file.deletions,
                           collapsed: file.isCollapsed) {
                toggle?(file.path)
            }
            .offset(y: state.offset)
            .clipped()
            .allowsHitTesting(state.offset > -DiffMetrics.headerHeight)
        }
    }
}

// MARK: - File header

/// The interactive file header: the floating one above the body, and the PR panel's fixed one.
/// The body's own header *lines* are drawn as text; this is the control.
struct DiffFileHeader: View {
    let path: String
    let additions: Int
    let deletions: Int
    let collapsed: Bool
    var toggle: (() -> Void)? = nil

    init(path: String, additions: Int, deletions: Int, collapsed: Bool, toggle: (() -> Void)? = nil) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.collapsed = collapsed
        self.toggle = toggle
    }

    init(file: UnifiedDiffFile, collapsed: Bool = false, toggle: (() -> Void)? = nil) {
        self.init(path: file.path, additions: file.additions, deletions: file.deletions,
                  collapsed: collapsed, toggle: toggle)
    }

    var body: some View {
        Button { toggle?() } label: {
            HStack(spacing: 6) {
                if toggle != nil {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 10)
                }
                Text(path).font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text("+\(additions)").foregroundStyle(.green).font(.caption.monospacedDigit())
                Text("−\(deletions)").foregroundStyle(.red).font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DiffMetrics.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(toggle == nil)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}
