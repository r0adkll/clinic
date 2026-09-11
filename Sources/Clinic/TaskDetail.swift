import SwiftUI
import WebKit
import ClinicCore

/// One task (ADR-112): a native header with the actions and links, over one web view holding the
/// body and the whole thread.
struct TaskDetailView: View {
    @Environment(TasksStore.self) private var store
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let item: WorkItem
    /// `true` = start now, skipping the composer (ADR-114).
    let onStart: (Bool) -> Void

    var body: some View {
        let detail = store.details[item.id]
        VStack(alignment: .leading, spacing: 0) {
            header(detail)
            Divider()
            thread(detail)
        }
        // Keyed on the store's generation too, so every refresh renews the signed image URLs.
        .task(id: "\(item.id)|\(store.generation)") { await store.loadDetail(item.ref) }
    }

    // MARK: Header

    private func header(_ detail: WorkItemDetail?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TaskStateGlyph(item: item, size: 15)
                Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text(meta).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if !item.labels.isEmpty {
                FlowLayout(spacing: 4) { ForEach(item.labels, id: \.name) { LabelCapsule(label: $0) } }
            }
            if !item.assignees.isEmpty || item.milestone != nil {
                HStack(spacing: 14) {
                    if !item.assignees.isEmpty {
                        Label(item.assignees.joined(separator: ", "), systemImage: "person.crop.circle").help("Assignees")
                    }
                    if let m = item.milestone { Label(m, systemImage: "flag").help("Milestone") }
                }
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            actions
            links(detail)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: String {
        var parts = [item.ref.display, "opened \(TaskRow.age(item.createdAt)) ago by \(item.author)"]
        if item.state == .closed, let closed = item.closedAt { parts.append("closed \(TaskRow.age(closed)) ago") }
        parts.append("\(item.commentCount) comment\(item.commentCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                // ⌥-click starts now, the mouse's ⌘↩ (ADR-114).
                onStart(NSEvent.modifierFlags.contains(.option))
            } label: {
                Label("Start Session", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.projectPath(for: item.ref) == nil)
            .help("Open the new-session screen with this issue as the prompt, in a worktree (↩). ⌥-click or ⌘↩ starts it straight away.")
            Button { TaskActions.open(item) } label: { Label("Open on GitHub", systemImage: "safari") }
                .help("Open in your browser (⌘O)")
            Button { TaskActions.copyLink(item) } label: { Label("Copy Link", systemImage: "link") }
                .help("Copy the issue's URL (⇧⌘C)")
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func links(_ detail: WorkItemDetail?) -> some View {
        let prs = detail?.linkedPullRequests ?? []
        let linked = store.sessionIds(for: item.ref).compactMap { sessions.sessions[$0] }
        if !prs.isEmpty || !linked.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(prs) { pr in
                    LinkChip(symbol: PullRequestMark.symbol, title: "#\(pr.number) \(pr.title)", tint: prTint(pr),
                             help: "Pull request \(pr.state == .merged ? "merged" : pr.state == .closed ? "closed" : pr.isDraft ? "draft" : "open"): \(pr.url.absoluteString)") {
                        NSWorkspace.shared.open(pr.url)
                    }
                }
                ForEach(linked) { s in
                    LinkChip(symbol: "terminal", title: sessions.displayName(for: s), tint: .accentColor,
                             help: "Session started from this task. Click to open it.") {
                        tabs.open(session: s)
                    }
                }
            }
        }
    }

    private func prTint(_ pr: WorkItemDetail.LinkedPullRequest) -> Color {
        switch pr.state {
        case .merged: .purple
        case .closed: .secondary
        case .open: pr.isDraft ? .secondary : .green
        }
    }

    // MARK: Thread

    @ViewBuilder
    private func thread(_ detail: WorkItemDetail?) -> some View {
        if let detail {
            TaskThreadView(html: TaskThreadDocument.html(item: item, detail: detail),
                           key: "\(item.id)|\(item.updatedAt.timeIntervalSince1970)|\(detail.comments.count)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.detailErrors[item.id] {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label("GitHub's rendering didn't load: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(item.body.isEmpty ? "No description provided." : item.body)
                        .font(.body).textSelection(.enabled)
                    Button("Try Again") { Task { await store.loadDetail(item.ref) } }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A linked pull request or session under the task's actions.
private struct LinkChip: View {
    let symbol: String
    let title: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).lineLimit(1).truncationMode(.tail)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 320, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Wraps its children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width && !rows[rows.count - 1].indices.isEmpty { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? min(size.width, width) : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - The thread document

/// The body and every comment as one document (ADR-112), built on ADR-090's page so it inherits the
/// CSP, the palette and the link policy. Only Clinic's own strings are escaped here; GitHub's
/// `bodyHTML` is already HTML.
enum TaskThreadDocument {
    static func html(item: WorkItem, detail: WorkItemDetail) -> String {
        var out = post(author: item.author, avatar: detail.authorAvatarURL, verb: "opened this", date: item.createdAt, url: item.ref.url,
                       body: detail.bodyHTML.flatMap { $0.isEmpty ? nil : $0 } ?? #"<p class="none">No description provided.</p>"#)
        for c in detail.comments {
            out += post(author: c.author, avatar: c.avatarURL, verb: "commented", date: c.createdAt, url: c.url, body: c.bodyHTML)
        }
        let more = detail.totalComments - detail.comments.count
        if more > 0 {
            out += #"<p class="more"><a href="\#(GitHubHTMLDocument.escape(item.ref.url.absoluteString))">\#(more) more comment\#(more == 1 ? "" : "s") on GitHub</a></p>"#
        }
        return out
    }

    private static func post(author: String, avatar: URL?, verb: String, date: Date, url: URL?, body: String) -> String {
        let img = avatar.map { #"<img class="avatar" src="\#(GitHubHTMLDocument.escape($0.absoluteString))" alt="">"# } ?? #"<span class="avatar"></span>"#
        let when = GitHubHTMLDocument.escape(date.formatted(date: .abbreviated, time: .shortened))
        let stamp = url.map { #"<a href="\#(GitHubHTMLDocument.escape($0.absoluteString))">\#(when)</a>"# } ?? when
        return """
        <article class="post"><header>\(img)<strong>\(GitHubHTMLDocument.escape(author))</strong> <span class="muted">\(verb) · \(stamp)</span></header>
        <div class="post-body">\(body)</div></article>
        """
    }

    static func css(dark: Bool) -> String {
        let border = dark ? "#3d444d" : "#d1d9e0"
        let head = dark ? "#151b23" : "#f6f8fa"
        let muted = dark ? "#9198a1" : "#59636e"
        return """
        body { padding: 14px 16px 24px; }
        .post { border: 1px solid \(border); border-radius: 8px; margin: 0 0 14px; overflow: hidden; }
        .post > header { display: flex; align-items: center; gap: 6px; padding: 7px 12px; background: \(head);
          border-bottom: 1px solid \(border); font-size: 12px; }
        .post > header a, .muted { color: \(muted); }
        .avatar { width: 20px; height: 20px; border-radius: 50%; display: inline-block; background: \(border); }
        .post-body { padding: 10px 12px; }
        .none { color: \(muted); font-style: italic; }
        .more { text-align: center; margin: 4px 0 0; }
        """
    }
}

/// A web view that scrolls itself: the thread is the whole pane below the header, so there is
/// nothing to hand scrolling to and nothing to measure (unlike `GitHubHTMLView`, ADR-091).
struct TaskThreadView: NSViewRepresentable {
    let html: String
    /// Reload only when this changes: a refresh renews signed image URLs in `html` every time, and
    /// reloading for that alone would throw the reader back to the top every five minutes.
    let key: String
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(html, key: key, colorScheme: colorScheme, into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html, key: key, colorScheme: colorScheme, into: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded: String?

        func load(_ html: String, key: String, colorScheme: ColorScheme, into view: WKWebView) {
            let full = "\(colorScheme)|\(key)"
            guard loaded != full else { return }
            loaded = full
            let dark = colorScheme == .dark
            view.loadHTMLString(GitHubHTMLDocument.page(body: html, dark: dark, reportsHeight: false, extraCSS: TaskThreadDocument.css(dark: dark)),
                                baseURL: GitHubHTMLNavigation.baseURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(GitHubHTMLNavigation.decide(action))
        }
    }
}
