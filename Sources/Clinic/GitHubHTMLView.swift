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

/// A web view that does not steal the panel's scrolling (ADR-091).
///
/// Each of these is sized to its own content, so it never needs to scroll vertically — but WKWebView
/// consumes the wheel event anyway, which made the whole PR panel refuse to scroll whenever the
/// pointer happened to be over a body. Vertical gestures are handed to the enclosing scroll view;
/// horizontal ones are kept, because a wide `<table>` genuinely does scroll sideways in place.
///
/// The direction is decided once when the gesture begins and held for its duration, including
/// momentum: deciding per event let a flick that drifted a few degrees off-axis switch owners
/// halfway through and stall.
final class PassThroughScrollWebView: WKWebView {
    private var forwardsToPanel = true

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            forwardsToPanel = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        }
        if forwardsToPanel {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private struct HTMLWebView: NSViewRepresentable {
    let html: String
    let colorScheme: ColorScheme
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassThroughScrollWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: Coordinator.heightMessage)

        let view = PassThroughScrollWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        // The page paints its own background token; without this the web view draws opaque white
        // over the panel in dark mode before the first frame.
        view.setValue(false, forKey: "drawsBackground")
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        context.coordinator.load(html, colorScheme: colorScheme, into: view)
        return view
    }

    func updateNSView(_ view: PassThroughScrollWebView, context: Context) {
        context.coordinator.load(html, colorScheme: colorScheme, into: view)
    }

    static func dismantleNSView(_ view: PassThroughScrollWebView, coordinator: Coordinator) {
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
                                baseURL: GitHubHTMLNavigation.baseURL)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.heightMessage, let value = message.body as? Double else { return }
            let clamped = max(18, min(CGFloat(value), 20_000))
            if abs(clamped - height) > 0.5 { height = clamped }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(GitHubHTMLNavigation.decide(action))
        }
    }
}

/// ADR-090's navigation policy, shared by every view of GitHub's HTML (the PR panel's bodies and the
/// Tasks thread, ADR-112): nothing navigates in place.
///
/// The delegate method this backs went uncalled until 2026-09-10. It was declared with a
/// `decisionHandler` that only *nearly matched* WebKit's `@MainActor @Sendable` requirement, and
/// under Swift 6 a near miss is a different method, so WebKit fell back to allowing everything and a
/// clicked link loaded inside the body. Declare it with the exact signature, or it is dead again.
enum GitHubHTMLNavigation {
    static let baseURL = URL(string: "https://github.com/")!

    @MainActor
    static func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        switch action.navigationType {
        case .other:
            // `loadHTMLString` itself. It arrives *after* the web view has adopted the base URL, so
            // "the view has no URL yet" is not a test for it.
            return url.scheme == "about" || url == baseURL ? .allow : .cancel
        case .linkActivated:
            // A footnote or heading anchor (`#user-content-…`) scrolls the body; anything else is
            // somewhere else and opens in the browser.
            if url.fragment != nil, url.withoutFragment == baseURL { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        default:
            // A form post, a reload, a scripted or meta-refresh navigation: refused.
            return .cancel
        }
    }
}

private extension URL {
    var withoutFragment: URL? {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        return c.url
    }
}
