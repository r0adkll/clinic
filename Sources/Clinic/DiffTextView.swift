import AppKit
import SwiftUI
import ClinicCore

/// The diff body: one read-only text view showing one file's diff (ADR-100, ADR-101).
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
    /// Space either side of the gutter's contents, and between its columns.
    static let gutterPadding: CGFloat = 6
    static let gutterGap: CGFloat = 8

    /// Two line-number columns plus the `+`/`−` marker, sized to the digits this file actually needs.
    /// A fixed width wastes a third of a 380 pt panel on a file whose line numbers are two digits —
    /// and reads as the code being pushed away from the left rather than as a column of its own.
    static func gutterWidth(digits: Int) -> CGFloat {
        let column = CGFloat(max(digits, 2)) * advance
        return gutterPadding + column + gutterGap + column + gutterGap + advance + gutterPadding
    }

    /// Where each of the gutter's three columns ends, for right-aligned tab stops.
    static func gutterStops(digits: Int) -> [CGFloat] {
        let column = CGFloat(max(digits, 2)) * advance
        let old = gutterPadding + column
        let new = old + gutterGap + column
        return [old, new, new + gutterGap + advance]
    }
    /// Between the gutter's right edge and the first character.
    static let leftPadding: CGFloat = 6
    /// After the longest line, so it is not flush against the edge. Deliberately small: this is the
    /// only thing past the text, and anything larger reads as a void to scroll into.
    static let trailingPadding: CGFloat = 12
    /// What the text is inset by on the left. The gutter is a view of its own beside the body, so
    /// this is breathing room, not room for the numbers.
    static var textInset: CGFloat { leftPadding }

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

// MARK: - Text view

/// Draws the full-width `+`/`−` tints.
final class DiffContentTextView: NSTextView {
    var document = DiffDocument()

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

}

// MARK: - Gutter

/// Line numbers and the `+`/`−` marker, in a column of their own beside the scroll view.
///
/// It was an `NSRulerView` overlaying the text's left edge, which put the gutter *on top of* the
/// scrollable area: scrolling sideways slid the code underneath it and chopped lines mid-character,
/// and the document carried a gutter-wide dead margin on its left that the scroll ran through. A
/// sibling view is what an editor actually does — the code's scrollable area simply begins where the
/// gutter ends, so there is nothing to slide under and nothing dead to scroll past.
final class DiffGutterView: NSView {
    var document = DiffDocument() {
        didSet {
            digits = Self.digits(in: document)
            columns = Self.paragraph(digits: digits)
        }
    }
    /// How many digits the widest line number in this file needs; the column is sized to it.
    private(set) var digits = 2
    private var columns = DiffGutterView.paragraph(digits: 2)

    var preferredWidth: CGFloat { DiffMetrics.gutterWidth(digits: digits) }

    private static func digits(in document: DiffDocument) -> Int {
        var highest = 0
        for line in document.lines {
            highest = max(highest, line.oldNumber ?? 0, line.newNumber ?? 0)
        }
        return max(2, String(highest).count)
    }
    /// The body's scroll position, pushed in on every scroll: the gutter follows vertically and
    /// ignores horizontal scrolling entirely.
    var scrollY: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let height = DiffMetrics.lineHeight
        let first = max(0, Int(floor(scrollY / height)))
        let last = min(document.lines.count - 1, Int(ceil((scrollY + bounds.height) / height)))
        guard first <= last else { return }

        // The band runs under the gutter too, so a changed line is one stripe across both.
        for n in first...last {
            guard let colour = DiffMetrics.band(document.lines[n].kind) else { continue }
            colour.setFill()
            NSRect(x: 0, y: CGFloat(n) * height - scrollY, width: bounds.width, height: height).fill()
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
        // One attributed string for the whole visible gutter, drawn once. Drawing each number with
        // its own `NSString.draw(at:)` costs ~1.8 ms a frame at 55 visible lines: every call builds
        // a layout of its own.
        let attributed = NSAttributedString(string: text, attributes: [
            .font: DiffMetrics.font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: columns,
        ])
        attributed.draw(at: NSPoint(x: 0, y: CGFloat(first) * height - scrollY))
    }

    /// Right-aligned tab stops are what put the two number columns and the marker in their places
    /// with one draw call instead of three per line.
    private static func paragraph(digits: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = DiffMetrics.lineHeight
        p.maximumLineHeight = DiffMetrics.lineHeight
        p.tabStops = DiffMetrics.gutterStops(digits: digits).map { NSTextTab(textAlignment: .right, location: $0) }
        return p
    }
}

/// Holds the gutter and the body side by side: the gutter's width, then everything else.
final class DiffBodyView: NSView {
    let gutter: DiffGutterView
    let scrollView: NSScrollView

    init(gutter: DiffGutterView, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = gutter.preferredWidth
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}

// MARK: - Attributed text

enum DiffTextRenderer {
    /// The widest rendered line, in points.
    ///
    /// `columns × advance` is a guess that holds only for plain ASCII: a tab, a CJK character or an
    /// emoji renders wider than one advance, and any line the guess underestimates becomes
    /// unreachable — it extends past the scrollable width and cannot be scrolled to. The font is
    /// monospaced, so character count still *ranks* the lines correctly enough to pick candidates;
    /// only the widest few are measured, which keeps this a handful of measurements per document
    /// rather than one per line.
    @MainActor
    static func width(of document: DiffDocument) -> CGFloat {
        guard !document.lines.isEmpty else { return 0 }
        var widest: [DiffDocument.Line] = []
        for line in document.lines {
            if widest.count < 4 {
                widest.append(line)
                widest.sort { $0.range.length > $1.range.length }
            } else if line.range.length > widest[3].range.length {
                widest[3] = line
                widest.sort { $0.range.length > $1.range.length }
            }
        }
        let ns = document.text as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: DiffMetrics.font, .paragraphStyle: DiffMetrics.paragraph]
        return widest.reduce(0) { longest, line in
            max(longest, ceil((ns.substring(with: line.range) as NSString).size(withAttributes: attributes).width))
        }
    }

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
            case .hunk:
                out.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: line.range)
            case .code(let kind):
                if kind == .noNewline {
                    out.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: line.range)
                }
                guard let tokens = tokens[line.rowId] else { continue }
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
    /// Read by the enclosing body so SwiftUI knows when to call `updateNSView`.
    let documentGeneration: Int
    let tokenGeneration: Int
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator(source: source) }

    func makeNSView(context: Context) -> NSView { context.coordinator.body }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.apply(documentGeneration: documentGeneration, tokenGeneration: tokenGeneration,
                                  colorScheme: colorScheme)
    }

    @MainActor
    final class Coordinator: NSObject {
        let scrollView = NSScrollView()
        let textView: DiffContentTextView
        let gutter = DiffGutterView()
        let body: DiffBodyView
        private let source: DiffTextSource

        /// The widest line, measured once per document rather than guessed per resize.
        private var textWidth: CGFloat = 0
        private var appliedDocument = -1
        private var appliedTokens = -1
        private var appliedScheme: ColorScheme?

        init(source: DiffTextSource) {
            self.source = source

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
            body = DiffBodyView(gutter: gutter, scrollView: scrollView)
            super.init()

            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            // `textContainerInset` is the one offset TextKit applies to drawing as well as layout;
            // a paragraph head indent lays out at the right x and then draws the run shifted left.
            textView.textContainerInset = NSSize(width: DiffMetrics.textInset, height: 0)
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
            // Overscrolling sideways pulls the code away from the line numbers and springs back —
            // physics that reads as a glitch in a column of code, so the body simply stops at its
            // bounds. Vertical elasticity is untouched: a long file bouncing at its end is normal.
            scrollView.horizontalScrollElasticity = .none
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor
            gutter.clipsToBounds = true

            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: scrollView.contentView)
            body.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(resized),
                                                   name: NSView.frameDidChangeNotification,
                                                   object: body)
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
        /// for 7,500 lines, and it only changes when another file is selected or highlighting lands.
        private func rebuild() {
            let document = source.document
            textWidth = DiffTextRenderer.width(of: document)
            textView.document = document
            gutter.document = document
            // The gutter is only as wide as this file's line numbers, so the body re-lays out.
            body.needsLayout = true
            body.layoutSubtreeIfNeeded()
            contentStorage.attributedString = DiffTextRenderer.attributed(document, tokens: source.tokens)
            resize()
            textView.needsDisplay = true
            gutter.needsDisplay = true
            // A new file starts at the top left, never where the last one was left.
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            gutter.scrollY = 0
        }

        /// Height is lines × line height; width is the longest line × advance, never less than the
        /// viewport, so short diffs fill the pane instead of floating in it.
        ///
        /// The width is the measured widest line plus a small margin — no gutter in it at all, now
        /// that the gutter is a view beside the scroll view rather than an inset inside it.
        private func resize() {
            let document = source.document
            let viewport = scrollView.contentSize.width
            let width = max(viewport, DiffMetrics.textInset + textWidth + DiffMetrics.trailingPadding)
            let height = max(scrollView.contentSize.height, CGFloat(document.lines.count) * DiffMetrics.lineHeight)
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            if textView.frame != frame { textView.frame = frame }
        }

        @objc private func scrolled() {
            gutter.scrollY = scrollView.contentView.bounds.origin.y
            gutter.needsDisplay = true
        }

        @objc private func resized() {
            body.needsLayout = true
            resize()
        }

    }
}

// MARK: - The view

/// The diff body. One file, so it needs nothing but what to draw (ADR-101).
struct DiffTextBody: View {
    let source: DiffTextSource

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        DiffTextRepresentable(source: source,
                              documentGeneration: source.documentGeneration,
                              tokenGeneration: source.tokenGeneration,
                              colorScheme: colorScheme)
    }
}
