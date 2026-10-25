import SwiftUI
import ClinicCore

/// A session's pull requests in one list (ADR-230), opened from the footer's PR chip and from the card's
/// summary row. Each stack with an open layer comes first, headed *Stack of 7 onto main* and drawn top layer
/// first as GitHub draws one, then the open pull requests on their own, then finished stacks, then *Merged
/// and Closed*; newest first within each. A stack keeps its merged layers in place, so it shows how far it
/// has landed. A PR not read yet counts as open, as ADR-228 counts it.
struct PRTray: View {
    @Environment(PRStore.self) private var prs
    let refs: [PullRequestRef]
    /// The PR whose pane is on screen, washed in the accent like the footer chip it replaced.
    var isFront: @MainActor (PullRequestRef) -> Bool = { _ in false }
    let onOpen: (PullRequestRef) -> Void

    private static let width: CGFloat = 440
    private static let maxHeight: CGFloat = 480

    var body: some View {
        // A popover's scroll view takes its whole height whether it needs it or not, so it is only used
        // when the list runs past the cap.
        ViewThatFits(in: .vertical) {
            list
            ScrollView { list }.frame(height: Self.maxHeight)
        }
        .frame(width: Self.width)
        // Its own ink: a popover takes its presenter's environment, and the sidebar row's secondary style greyed every title.
        .foregroundStyle(Color.primary)
        .frame(maxHeight: Self.maxHeight)
        .task(id: refs) { prs.ensureLoaded(refs) }
    }

    private var list: some View {
        let isOpen = { (ref: PullRequestRef) in (prs.mark(for: ref)?.state ?? .open) == .open }
        let groups = Array(prs.groups(refs).reversed())
        let openStacks = groups.filter { $0.isStack && $0.refs.contains(where: isOpen) }
        let open = groups.filter { !$0.isStack && isOpen($0.refs[0]) }.map { $0.refs[0] }
        let finishedStacks = groups.filter { $0.isStack && !$0.refs.contains(where: isOpen) }
        let finished = groups.filter { !$0.isStack && !isOpen($0.refs[0]) }.map { $0.refs[0] }
        let anyStack = !openStacks.isEmpty || !finishedStacks.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(openStacks.enumerated()), id: \.element.id) { i, group in
                if i > 0 { divider }
                stack(group)
            }
            if !open.isEmpty {
                if !openStacks.isEmpty { divider }
                if anyStack || !finished.isEmpty { header("Open") }
                rows(open)
            }
            ForEach(Array(finishedStacks.enumerated()), id: \.element.id) { i, group in
                if i > 0 || !openStacks.isEmpty || !open.isEmpty { divider }
                stack(group)
            }
            if !finished.isEmpty {
                if anyStack || !open.isEmpty { divider }
                header("Merged and Closed")
                rows(finished)
            }
        }
        .padding(8)
    }

    private func stack(_ group: PullRequestGroup) -> some View {
        let layers = Array(group.refs.reversed())
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Stack of \(group.refs.count)").font(.callout.weight(.semibold))
                if let base = group.base { Text("onto \(base)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
            ForEach(Array(layers.enumerated()), id: \.element.id) { i, ref in
                PRTrayRow(ref: ref, front: isFront(ref), above: i > 0, below: i < layers.count - 1) { onOpen(ref) }
            }
        }
    }

    private func rows(_ refs: [PullRequestRef]) -> some View {
        ForEach(refs, id: \.self) { ref in
            PRTrayRow(ref: ref, front: isFront(ref)) { onOpen(ref) }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.callout.weight(.semibold)).padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
    }

    private var divider: some View { Divider().padding(.vertical, 4).padding(.horizontal, 8) }
}

/// One PR in the tray: its state glyph, reference and title, and what its checks say, in the attention's
/// colour. A stack's layers are joined by a hairline through the glyph column.
private struct PRTrayRow: View {
    @Environment(PRStore.self) private var prs
    let ref: PullRequestRef
    let front: Bool
    /// The hairline runs up to the layer above, down to the layer below.
    var above = false
    var below = false
    let action: () -> Void
    @State private var hovering = false

    private static let padding: CGFloat = 4
    private static let column: CGFloat = 18

    var body: some View {
        let host = ref.codeHost
        let mark = prs.mark(for: ref)
        Button(action: action) {
            HStack(spacing: 8) {
                PRGlyph(host: host, mark: mark, size: PRStyle.glyphSize.chip)
                    .frame(height: Self.column)
                    .background {
                        VStack(spacing: 0) {
                            hairline(above)
                            Color.clear.frame(height: PRStyle.glyphSize.chip + 4)
                            hairline(below)
                        }
                        .padding(.vertical, -Self.padding)
                    }
                Text(host.reference(ref.number)).monospacedDigit().foregroundStyle(.secondary)
                Text(prs.pullRequest(for: ref)?.title ?? host.noun).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let detail = Self.detail(mark) {
                    Text(detail).font(.caption).lineLimit(1)
                        .foregroundStyle(mark?.attentionTone.map { AnyShapeStyle(host.art.palette.ink($0)) } ?? AnyShapeStyle(.secondary))
                }
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, Self.padding)
            .background(front ? Color.accent.opacity(0.14) : hovering ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: PaneMetrics.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(mark?.summary ?? "\(host.noun) \(host.reference(ref.number))")
        .contextMenu {
            Button(host.openTitle) { NSWorkspace.shared.open(ref.url) }
            Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref.url.absoluteString, forType: .string) }
            Button("Refresh") { Task { await prs.refresh(ref) } }
        }
    }

    private func hairline(_ shown: Bool) -> some View {
        Rectangle().fill(shown ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear)).frame(width: 1)
    }

    /// "1 check failing" out of "Open · 1 check failing": the state is the glyph's to say.
    static func detail(_ mark: PullRequestMark?) -> String? {
        guard let summary = mark?.summary, let dot = summary.range(of: " · ") else { return nil }
        return String(summary[dot.upperBound...])
    }
}

/// The footer's one chip for a session with several PRs (ADR-230): their strongest state and attention as
/// one glyph, how many there are, and the tray. Accent while one of them is in front, outlined while one is
/// open behind another pane, as the single PR's chip is (ADR-228).
struct PRTrayChip: View {
    @Environment(PRStore.self) private var prs
    let tab: Tab
    let refs: [PullRequestRef]
    let onOpen: (PullRequestRef) -> Void
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        let host = refs[0].codeHost
        let front = refs.contains { tab.isFront(.pr($0)) }
        let open = refs.contains { tab.isOpen(.pr($0)) }
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                PRGlyph(host: host, mark: prs.aggregateMark(for: refs), size: PRStyle.glyphSize.chip)
                Text("\(refs.count) \(host.abbreviation)s").monospacedDigit()
            }
            .modifier(PRChipChrome(active: front || showing, open: open, hovering: hovering))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(help(host))
        .popover(isPresented: $showing, arrowEdge: .top) {
            PRTray(refs: refs, isFront: { tab.isFront(.pr($0)) }) { ref in showing = false; onOpen(ref) }
        }
    }

    /// "8 pull requests: 5 failing · 1 running".
    private func help(_ host: CodeHost) -> String {
        let tally = PullRequestTally(refs.map(prs.mark(for:)))
        var parts = [tally.detail]
        if tally.finished > 0 { parts.append("\(tally.finished) merged or closed") }
        let detail = parts.compactMap { $0 }.joined(separator: " · ")
        return "\(refs.count) \(host.noun.lowercased())s" + (detail.isEmpty ? "" : ": \(detail)")
    }
}
