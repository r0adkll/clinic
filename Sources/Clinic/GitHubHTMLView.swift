import SwiftUI
import WebKit
import ClinicCore

/// Renders GitHub's own HTML for a PR body or comment (ADR-090).
///
/// Clinic does not parse this Markdown. `gh` returns `bodyHTML` already rendered by GitHub, so
/// images, raw `<table>` (which is what Danger and most bots actually emit), `<details>`, alerts,
/// task lists, emoji shortcodes and `@mentions` all arrive correct and need only styling.
///
/// The web view is deliberately inert: a CSP with `default-src 'none'` blocks every subresource
/// except images, and only the height-reporting script — pinned to a per-load nonce — is allowed to
/// run, so nothing in a comment written by a stranger can execute or phone home. Clicks are
/// intercepted and opened in the browser rather than navigated in place.
struct GitHubHTMLView: View {
    let html: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 24

    var body: some View {
        HTMLWebView(html: html, colorScheme: colorScheme, height: $height)
            .frame(height: height)
            // Height arrives from the web view a beat after layout; animating it stops the whole
            // conversation from snapping when an image finishes loading.
            .animation(.easeOut(duration: 0.12), value: height)
    }
}

private struct HTMLWebView: NSViewRepresentable {
    let html: String
    let colorScheme: ColorScheme
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: Coordinator.heightMessage)

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        // The page paints its own background token; without this the web view draws opaque white
        // over the panel in dark mode before the first frame.
        view.setValue(false, forKey: "drawsBackground")
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        context.coordinator.load(html, colorScheme: colorScheme, into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html, colorScheme: colorScheme, into: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.heightMessage)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let heightMessage = "clinicHeight"
        @Binding var height: CGFloat
        /// What is currently loaded, so `updateNSView` does not reload on every layout pass.
        private var loaded: String?

        init(height: Binding<CGFloat>) { _height = height }

        func load(_ html: String, colorScheme: ColorScheme, into view: WKWebView) {
            let key = "\(colorScheme)\n\(html)"
            guard loaded != key else { return }
            loaded = key
            view.loadHTMLString(GitHubHTMLDocument.page(body: html, dark: colorScheme == .dark),
                                baseURL: URL(string: "https://github.com/"))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.heightMessage, let value = message.body as? Double else { return }
            let clamped = max(18, min(CGFloat(value), 20_000))
            if abs(clamped - height) > 0.5 { height = clamped }
        }

        /// Nothing navigates in place. The first `loadHTMLString` is allowed; a click on a link opens
        /// in the user's browser, and anything else — a meta refresh, a form post — is simply refused.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .other, action.request.url?.scheme == "about" || webView.url == nil {
                decisionHandler(.allow); return
            }
            if let url = action.request.url, action.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
