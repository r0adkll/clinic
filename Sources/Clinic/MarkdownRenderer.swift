import Foundation
import cmark_gfm
import cmark_gfm_extensions
import ClinicCore

/// Markdown to HTML for the Files pane's preview (ADR-191), by cmark-gfm — GitHub's own fork of the
/// CommonMark reference parser, so a README reads here as it reads on GitHub: tables, task lists,
/// strikethrough, autolinks, footnotes, and the raw HTML READMEs lean on (`<p align="center">`,
/// `<details>`, `<img width>`).
///
/// Raw HTML is let through (`CMARK_OPT_UNSAFE`) because the page it lands in is inert: GFM's
/// `tagfilter` neuters `<script>`, `<iframe>`, `<style>` and the rest as GitHub does, and the page's
/// CSP refuses any script but Clinic's own (ADR-090).
///
/// Every block carries `data-sourcepos`, which is how the split view finds the paragraph the editor
/// is looking at.
enum MarkdownRenderer {
    /// Registering the extensions is a one-time global write in cmark-gfm; after it, parsers on any
    /// thread only read the registry.
    private static let registered: Void = { cmark_gfm_core_extensions_ensure_registered() }()
    private static let extensions = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]

    /// Front matter becomes a muted block above the document rather than a rule and a heading, which
    /// is what CommonMark makes of it.
    static func html(_ markdown: String) -> String {
        _ = registered
        let (frontMatter, body) = MarkdownDocument.split(markdown)
        let options = CMARK_OPT_SOURCEPOS | CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        body.utf8CString.withUnsafeBufferPointer { buffer in
            // The buffer ends in the NUL `utf8CString` adds; cmark is given the bytes before it.
            cmark_parser_feed(parser, buffer.baseAddress, buffer.count - 1)
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(rendered) }
        let html = String(cString: rendered)
        guard let frontMatter, !frontMatter.isEmpty else { return html }
        return "<pre class=\"front-matter\"><code>\(GitHubHTMLDocument.escape(frontMatter))</code></pre>\n" + html
    }
}
