import Foundation
import CodeEditLanguages
@preconcurrency import CodeEditSourceEditor
import CodeEditTextView
import ClinicCore

/// Colours markdown, which the tree-sitter path cannot (ADR-081).
///
/// The grammar parses markdown fine; the problem is downstream. Its captures are `text.title`,
/// `text.literal`, `punctuation.special` and friends, none of which exist in
/// `CodeEditSourceEditor.CaptureName`, so every one resolves to nil and the file renders as plain
/// text. A highlight provider can only speak in that same small vocabulary, so this one scans the
/// document itself (`MarkdownSyntax`, in ClinicCore, where it is tested) and maps what it finds onto
/// the captures the theme actually paints.
@MainActor
final class MarkdownHighlighter: @preconcurrency HighlightProviding {
    private var spans: [MarkdownSpan] = []

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        rescan(textView)
    }

    /// A fence or a front-matter delimiter changes the meaning of everything after it, so an edit
    /// invalidates the whole document rather than the edited range.
    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        rescan(textView)
        completion(.success(IndexSet(integersIn: 0..<max(textView.documentRange.length, 0))))
    }

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        if spans.isEmpty, textView.documentRange.length > 0 { rescan(textView) }
        let document = textView.documentRange
        let highlights = spans.compactMap { span -> HighlightRange? in
            guard NSIntersectionRange(span.range, range).length > 0 else { return nil }
            guard NSIntersectionRange(span.range, document) == span.range else { return nil }
            return HighlightRange(range: span.range, capture: Self.capture(for: span.kind))
        }
        completion(.success(highlights))
    }

    private func rescan(_ textView: TextView) {
        spans = MarkdownSyntax.spans(in: textView.string)
    }

    /// Markdown's roles, expressed in the seven colours the theme actually has: headings and bold take
    /// the keyword colour, code the string colour, link text the type colour, destinations the
    /// attribute colour, quotes the comment colour, and bullets the number colour.
    private static func capture(for kind: MarkdownSpanKind) -> CaptureName {
        switch kind {
        case .heading, .strong: .keyword
        case .emphasis: .variable
        case .code, .codeBlock: .string
        case .linkText: .type
        case .url: .typeAlternate
        case .quote, .comment: .comment
        case .marker: .number
        }
    }
}
