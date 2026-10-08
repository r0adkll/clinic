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
        case .hunk: Appearance.shared.nsAccentColor.withAlphaComponent(0.08)
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

    /// Behind the part of a changed line that differs from its counterpart (ADR-188): the line's own
    /// tint again, stronger, so the edit inside a line stands out from the line.
    static func emphasis(_ kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: NSColor.systemGreen.withAlphaComponent(0.30)
        case .deletion: NSColor.systemRed.withAlphaComponent(0.30)
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
    /// Bumped when a *different file* comes on screen, which is the one time the body goes back to
    /// the top (ADR-186). The same file arriving with new contents keeps the reader's line.
    private(set) var fileGeneration = 0
    /// A line the body has been asked to bring into view, and the request's number (ADR-188).
    private(set) var revealLine = 0
    private(set) var revealGeneration = 0

    /// Where the body is scrolled to, written by the view as it scrolls. Not observed: nothing draws
    /// from these, and a scroll must not invalidate a SwiftUI body sixty times a second.
    @ObservationIgnored var topLine = 0
    @ObservationIgnored var isScrolled = false

    func replace(document: DiffDocument, keepingTokens keep: Bool, newFile: Bool) {
        self.document = document
        if !keep { tokens = [:] }
        if newFile { fileGeneration += 1; topLine = 0; isScrolled = false }
        documentGeneration += 1
    }

    /// The colours for the document on screen, replacing whatever was there.
    func replace(tokens incoming: [String: [DiffToken]]) {
        guard incoming != tokens else { return }
        tokens = incoming
        tokenGeneration += 1
    }

    func reveal(line: Int) {
        revealLine = line
        revealGeneration += 1
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

    /// ⌘F and ⌘G, while the body has the keyboard (ADR-188). The find bar is AppKit's own; the app's
    /// Edit menu has no Find item to reach it through, so the chords are taken here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let action: NSTextFinder.Action
        switch key {
        case "f": action = .showFindInterface
        case "g": action = .nextMatch
        case "e": action = .setSearchString
        default: return super.performKeyEquivalent(with: event)
        }
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
        return true
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
    /// What covers the top of the body — the find bar, when it is showing. The body's scroll position
    /// already accounts for it; the gutter only has to not draw numbers beside it.
    var topInset: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        if topInset > 0 { NSBezierPath(rect: NSRect(x: 0, y: topInset, width: bounds.width, height: bounds.height - topInset)).addClip() }
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

    @MainActor
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: DiffMetrics.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: DiffMetrics.paragraph]
    }

    /// The document as attributed text: one base style per line kind, with the highlighter's tokens
    /// laid over the code. Line backgrounds are drawn, not attributed, so they can span the full width.
    @MainActor
    static func attributed(_ document: DiffDocument, tokens: [String: [DiffToken]]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: document.text, attributes: baseAttributes)
        out.beginEditing()
        colour(out, document: document, tokens: tokens)
        out.endEditing()
        return out
    }

    /// Lays the colours over text that is already there (ADR-186). Colour is not geometry: no glyph
    /// moves, so the text view keeps its layout and its scroll position, and highlighting that lands
    /// a moment after the text no longer throws the reader back to the top.
    @MainActor
    static func recolour(_ storage: NSMutableAttributedString, document: DiffDocument, tokens: [String: [DiffToken]]) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        storage.removeAttribute(.backgroundColor, range: whole)
        colour(storage, document: document, tokens: tokens)
    }

    @MainActor
    private static func colour(_ out: NSMutableAttributedString, document: DiffDocument, tokens: [String: [DiffToken]]) {
        let end = out.length
        for line in document.lines where NSMaxRange(line.range) <= end {
            switch line.kind {
            case .hunk:
                out.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line.range)
            case .code(let kind):
                if kind == .noNewline {
                    out.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line.range)
                }
                if let emphasis = line.emphasis, let colour = DiffMetrics.emphasis(kind) {
                    let range = NSRange(location: line.range.location + emphasis.location, length: emphasis.length)
                    if NSMaxRange(range) <= NSMaxRange(line.range) { out.addAttribute(.backgroundColor, value: colour, range: range) }
                }
                guard let tokens = tokens[line.rowId] else { continue }
                for token in tokens {
                    let range = NSRange(location: line.range.location + token.range.location, length: token.range.length)
                    guard NSMaxRange(range) <= NSMaxRange(line.range) else { continue }
                    out.addAttribute(.foregroundColor, value: token.colour.nsColor, range: range)
                }
            }
        }
    }
}

// MARK: - Representable

struct DiffTextRepresentable: NSViewRepresentable {
    let source: DiffTextSource
    /// Read by the enclosing body so SwiftUI knows when to call `updateNSView`.
    let documentGeneration: Int
    let tokenGeneration: Int
    let revealGeneration: Int
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator(source: source) }

    func makeNSView(context: Context) -> NSView { context.coordinator.body }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.apply(documentGeneration: documentGeneration, tokenGeneration: tokenGeneration,
                                  revealGeneration: revealGeneration, colorScheme: colorScheme)
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
        private var appliedFile = -1
        private var appliedReveal: Int
        private var appliedScheme: ColorScheme?

        init(source: DiffTextSource) {
            self.source = source
            appliedReveal = source.revealGeneration

            // TextKit 2, built by hand: touching the text view's `textStorage` or `layoutManager`
            // anywhere drops the view back to TextKit 1. The content storage's own `textStorage` is
            // the backing store and is safe to edit inside an editing transaction.
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
            // AppKit's find bar, opened with ⌘F while the body has the keyboard (ADR-188).
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
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

        func apply(documentGeneration: Int, tokenGeneration: Int, revealGeneration: Int, colorScheme: ColorScheme) {
            let schemeChanged = appliedScheme != colorScheme
            appliedScheme = colorScheme
            if documentGeneration != appliedDocument || schemeChanged {
                let newFile = source.fileGeneration != appliedFile
                appliedDocument = documentGeneration
                appliedTokens = tokenGeneration
                appliedFile = source.fileGeneration
                rebuild(keepingPosition: !newFile)
            } else if tokenGeneration != appliedTokens {
                appliedTokens = tokenGeneration
                recolour()
            }
            resize()
            if revealGeneration != appliedReveal {
                appliedReveal = revealGeneration
                reveal(line: source.revealLine)
            }
        }

        /// The whole document is re-attributed rather than patched in place: building it is ~20 ms
        /// for 7,500 lines, and it happens when the file on screen changes or its contents do.
        ///
        /// Only a *different file* starts at the top (ADR-186). The same file with new contents — a
        /// working tree moving under the reader — keeps the line that was at the top of the viewport,
        /// found again by its line number, and the offset into it.
        private func rebuild(keepingPosition: Bool) {
            let previous = textView.document
            let clip = scrollView.contentView
            // In the document's own coordinates: the clip view's origin is negative by the height of
            // whatever covers its top (the find bar).
            let origin = NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + clip.contentInsets.top)
            let height = DiffMetrics.lineHeight
            let topLine = max(0, Int(floor(origin.y / height)))

            let document = source.document
            textWidth = DiffTextRenderer.width(of: document)
            textView.document = document
            gutter.document = document
            // The gutter is only as wide as this file's line numbers, so the body re-lays out.
            body.needsLayout = true
            body.layoutSubtreeIfNeeded()
            let attributed = DiffTextRenderer.attributed(document, tokens: source.tokens)
            contentStorage.performEditingTransaction {
                if let storage = contentStorage.textStorage { storage.setAttributedString(attributed) }
                else { contentStorage.attributedString = attributed }
            }
            resize()
            textView.needsDisplay = true
            gutter.needsDisplay = true

            var target = NSPoint.zero
            if keepingPosition, origin.y > 0, let line = document.line(matching: topLine, of: previous) {
                target = NSPoint(x: origin.x, y: CGFloat(line) * height + (origin.y - CGFloat(topLine) * height))
            } else if keepingPosition, origin.y > 0 {
                target = origin
            }
            scroll(to: target)
        }

        /// Highlighting that arrived for the text already on screen: colour only, in place.
        private func recolour() {
            guard let storage = contentStorage.textStorage, storage.length == (source.document.text as NSString).length else {
                rebuild(keepingPosition: true)
                return
            }
            let document = source.document, tokens = source.tokens
            contentStorage.performEditingTransaction {
                storage.beginEditing()
                DiffTextRenderer.recolour(storage, document: document, tokens: tokens)
                storage.endEditing()
            }
        }

        /// Brings a line into view a few lines below the top, so the reader sees what leads up to it.
        private func reveal(line: Int) {
            let y = CGFloat(max(0, line - 3)) * DiffMetrics.lineHeight
            scroll(to: NSPoint(x: 0, y: y))
        }

        private func scroll(to point: NSPoint) {
            let clip = scrollView.contentView
            let top = -clip.contentInsets.top
            let limitY = max(top, textView.frame.height - clip.bounds.height)
            let limitX = max(0, textView.frame.width - clip.bounds.width)
            let clamped = NSPoint(x: min(max(0, point.x), limitX), y: min(max(top, point.y + top), limitY))
            clip.scroll(to: clamped)
            scrollView.reflectScrolledClipView(clip)
            scrolled()
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
            let clip = scrollView.contentView
            let y = clip.bounds.origin.y
            gutter.scrollY = y
            gutter.topInset = clip.contentInsets.top
            gutter.needsDisplay = true
            // For the browser: which change is "next", and whether the reader has moved (ADR-187).
            source.topLine = max(0, Int(floor((y + clip.contentInsets.top) / DiffMetrics.lineHeight)))
            source.isScrolled = y + clip.contentInsets.top > 1
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
                              revealGeneration: source.revealGeneration,
                              colorScheme: colorScheme)
    }
}
