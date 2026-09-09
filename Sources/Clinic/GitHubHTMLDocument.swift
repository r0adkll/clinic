import Foundation

/// Wraps GitHub's `bodyHTML` fragment in a document Clinic can style and measure (ADR-090).
///
/// The CSS is deliberately small: GitHub's HTML is semantic (`<table>`, `<blockquote>`,
/// `<div class="markdown-alert">`), so this only has to supply a palette, the system font, and the
/// handful of rules that make tables and code blocks look native. The GitHub custom properties are
/// defined because GitHub inlines `style="background-color: var(--bgColor-muted)"` on images.
enum GitHubHTMLDocument {
    static func page(body: String, dark: Bool) -> String {
        let nonce = UUID().uuidString
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(csp(nonce: nonce))">
        <style>\(css(dark: dark))</style>
        </head><body>\(body)
        <script nonce="\(nonce)">\(heightScript)</script>
        </body></html>
        """
    }

    /// Images (and the media a comment may embed) load; everything else is refused. Scripts are
    /// limited to the nonce below, so even if a comment smuggled in a `<script>` it would not run.
    static func csp(nonce: String) -> String {
        "default-src 'none'; img-src https: data: blob:; media-src https: data:; "
        + "style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; frame-src 'none'; connect-src 'none'"
    }

    /// Reports document height to the host so SwiftUI can size the view. A `ResizeObserver` covers
    /// the case that actually matters: an image finishing its download and reflowing the body.
    static let heightScript = """
    (function () {
      var post = function () {
        var h = Math.ceil(document.documentElement.getBoundingClientRect().height);
        window.webkit.messageHandlers.clinicHeight.postMessage(h);
      };
      new ResizeObserver(post).observe(document.documentElement);
      window.addEventListener('load', post);
      Array.prototype.forEach.call(document.images, function (i) {
        i.addEventListener('load', post); i.addEventListener('error', post);
      });
      post();
    })();
    """

    static func css(dark: Bool) -> String {
        let fg = dark ? "#e6edf3" : "#1f2328"
        let muted = dark ? "#9198a1" : "#59636e"
        let border = dark ? "#3d444d" : "#d1d9e0"
        let subtle = dark ? "#151b23" : "#f6f8fa"
        let link = dark ? "#4493f8" : "#0969da"
        let quote = dark ? "#3d444d" : "#d1d9e0"
        return """
        :root {
          color-scheme: \(dark ? "dark" : "light");
          --fgColor-default: \(fg); --fgColor-muted: \(muted); --fgColor-accent: \(link);
          --bgColor-default: transparent; --bgColor-muted: \(subtle); --borderColor-default: \(border);
        }
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
          color: \(fg);
          font: 13px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
          overflow-wrap: anywhere; word-break: break-word;
        }
        body > *:first-child { margin-top: 0 !important; }
        body > *:last-child { margin-bottom: 0 !important; }
        p, ul, ol, blockquote, table, pre, .markdown-alert { margin: 0 0 10px; }
        h1, h2, h3, h4, h5, h6 { margin: 16px 0 8px; line-height: 1.3; font-weight: 600; }
        h1 { font-size: 1.5em; } h2 { font-size: 1.3em; } h3 { font-size: 1.12em; }
        h1, h2 { padding-bottom: .25em; border-bottom: 1px solid \(border); }
        a { color: \(link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        ul, ol { padding-left: 1.5em; }
        li { margin: 2px 0; }
        li.task-list-item { list-style: none; margin-left: -1.3em; }
        li.task-list-item input { margin-right: .5em; }
        code {
          font: 11.5px/1.45 ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
          background: \(subtle); padding: .15em .4em; border-radius: 5px;
        }
        pre { background: \(subtle); padding: 10px 12px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote {
          margin-left: 0; padding: 0 1em; color: \(muted); border-left: .25em solid \(quote);
        }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        hr { height: 1px; border: 0; background: \(border); margin: 16px 0; }
        table { border-collapse: collapse; display: block; width: max-content; max-width: 100%; overflow: auto; }
        th, td { border: 1px solid \(border); padding: 5px 12px; text-align: left; vertical-align: top; }
        th { font-weight: 600; background: \(subtle); }
        tr:nth-child(2n) td { background: \(dark ? "#0f1419" : "#f6f8fa"); }
        /* GitHub's `> [!NOTE]` blocks. */
        .markdown-alert { padding: 6px 12px; border-left: .25em solid \(border); }
        .markdown-alert-title { display: flex; align-items: center; gap: .4em; font-weight: 600; }
        .markdown-alert-note { border-left-color: \(link); }
        .markdown-alert-tip { border-left-color: #3fb950; }
        .markdown-alert-important { border-left-color: #ab7df8; }
        .markdown-alert-warning { border-left-color: #d29922; }
        .markdown-alert-caution { border-left-color: #f85149; }
        details { margin: 0 0 10px; }
        summary { cursor: default; font-weight: 600; }
        .octicon { vertical-align: text-bottom; fill: currentColor; }
        g-emoji, .emoji { font-size: 1.05em; }
        """
    }
}
