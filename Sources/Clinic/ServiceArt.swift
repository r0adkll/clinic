import AppKit
import SwiftUI
import ClinicCore

/// A code host's own glyphs and colours (ADR-116): Octicons and Primer's palette for GitHub, GitLab's
/// icon set and Pajamas palette for GitLab. The words live in ClinicCore's `CodeHost`; this is the half
/// that is SwiftUI.
///
/// The rule the panel follows: facts about the PR (its state, its CI, merging it) wear the service's
/// colours, and anything that types into the session wears Clinic's accent, so the two are never
/// confused. Colour carries information here, like the Tasks label capsules, which is why it is
/// allowed to vary by service where Clinic's tiles never do.
///
/// Every glyph is a template SVG vendored by `scripts/vendor-service-icons.sh`.
struct ServiceArt {
    struct Palette {
        /// Fills: state pills, merge-box discs, reviewer badges.
        var open, draft, merged, closed, attention: Color
        /// The same hues tuned to read as text or glyph on the window.
        var openInk, draftInk, mergedInk, closedInk, attentionInk: Color
        /// Branch names and the author's comment box.
        var link, linkWash: Color
        var border: Color
        /// Box header strips and the merge-box footer.
        var muted: Color
        var counter: Color
        var tabIndicator: Color
        var mergeButton: Color
        /// The service mark's own colour, or nil to draw it in the text colour (GitHub's is monochrome).
        var markTint: Color?

        func fill(_ tone: PullRequestStatus.Tone) -> Color {
            switch tone { case .blocking: closed; case .waiting: attention; case .good: open; case .neutral: draft }
        }
        func ink(_ tone: PullRequestStatus.Tone) -> Color {
            switch tone { case .blocking: closedInk; case .waiting: attentionInk; case .good: openInk; case .neutral: draftInk }
        }
    }

    let kind: CodeHost.Kind
    let palette: Palette
    /// GitHub fills its state pill and puts white on it; GitLab uses a soft wash with a dark label.
    let filledPills: Bool

    // MARK: Glyphs (asset names)

    let mark, open, draft, merged, closed: String
    let check, cross, alert, pending, comment, eye, pencil, changesRequested, approved, behind, autoMerge, external: String
    let conversation, checks, files: String

    func stateGlyph(_ state: PullRequest.State, isDraft: Bool) -> String {
        switch state {
        case .merged: merged
        case .closed: closed
        case .open: isDraft ? draft : open
        }
    }

    func stateFill(_ state: PullRequest.State, isDraft: Bool) -> Color {
        switch state {
        case .merged: palette.merged
        case .closed: palette.closed
        case .open: isDraft ? palette.draft : palette.open
        }
    }

    func stateInk(_ state: PullRequest.State, isDraft: Bool) -> Color {
        switch state {
        case .merged: palette.mergedInk
        case .closed: palette.closedInk
        case .open: isDraft ? palette.draftInk : palette.openInk
        }
    }

    func paneGlyph(_ pane: CodeHost.Pane) -> String {
        switch pane { case .conversation: conversation; case .checks: checks; case .files: files }
    }

    /// The glyph for a `PullRequestStatus` line in the merge box, by what the line is about.
    func glyph(for line: PullRequestStatus.Line, state: PullRequest.State) -> String {
        switch (line.id, line.tone) {
        case ("draft", _): draft
        case ("state", _): state == .merged ? merged : closed
        case ("checks", .blocking): cross
        case ("checks", _): check
        case ("pending", _): pending
        case ("merge", .blocking): alert
        case ("merge", .waiting): behind
        case ("merge", _): check
        case ("review", .blocking): changesRequested
        case ("review", .good): approved
        case ("review", _): eye
        case ("comments", _): comment
        case ("auto", _): autoMerge
        default: pending
        }
    }

    /// The disc behind a merge-box line. Merged and closed keep their state colour rather than
    /// the neutral grey their tone would give them.
    func discFill(for line: PullRequestStatus.Line, state: PullRequest.State) -> Color {
        if line.id == "state" { return state == .merged ? palette.merged : palette.closed }
        return palette.fill(line.tone)
    }

    func checkGlyph(_ status: PullRequest.Check.Status) -> String {
        let github = kind == .github
        switch status {
        case .success: return github ? "octicon.check-circle-fill" : "gitlab.status_success_borderless"
        case .failure: return github ? "octicon.x-circle-fill" : "gitlab.status_failed_borderless"
        case .pending: return github ? "octicon.dot-fill" : "gitlab.status_running_borderless"
        case .skipped, .neutral: return github ? "octicon.skip" : "gitlab.status_skipped_borderless"
        case .cancelled: return github ? "octicon.stop" : "gitlab.status_canceled_borderless"
        case .unknown: return github ? "octicon.question" : "gitlab.status_notfound_borderless"
        }
    }

    func checkInk(_ status: PullRequest.Check.Status) -> Color {
        switch status {
        case .success: palette.openInk
        case .failure: palette.closedInk
        case .pending: palette.attentionInk
        default: palette.draftInk
        }
    }

    /// The CI provider's mark, or nil for an unrecognised one.
    static func providerGlyph(_ provider: CheckProvider) -> String? {
        switch provider {
        case .githubActions: "brand.githubactions"
        case .gitlabCI: "brand.gitlab"
        case .codecov: "brand.codecov"
        case .circleCI: "brand.circleci"
        case .buildkite: "brand.buildkite"
        case .vercel: "brand.vercel"
        case .netlify: "brand.netlify"
        case .travisCI: "brand.travisci"
        case .bitrise: "brand.bitrise"
        case .jenkins: "brand.jenkins"
        case .sonarCloud: "brand.sonarqubecloud"
        case .other: nil
        }
    }

    // MARK: The two services

    static let github = ServiceArt(
        kind: .github,
        palette: Palette(
            open: .dynamic(0x1f883d, 0x238636), draft: .dynamic(0x59636e, 0x656c76),
            merged: .dynamic(0x8250df, 0x8957e5), closed: .dynamic(0xcf222e, 0xda3633),
            attention: .dynamic(0xbf8700, 0x9e6a03),
            openInk: .dynamic(0x1a7f37, 0x3fb950), draftInk: .dynamic(0x59636e, 0x9198a1),
            mergedInk: .dynamic(0x8250df, 0xab7df8), closedInk: .dynamic(0xd1242f, 0xf85149),
            attentionInk: .dynamic(0x9a6700, 0xd29922),
            link: .dynamic(0x0969da, 0x4493f8), linkWash: .dynamic(0xddf4ff, 0x388bfd, darkAlpha: 0.16),
            border: .dynamic(0xd1d9e0, 0x3d444d), muted: .dynamic(0xf6f8fa, 0xffffff, darkAlpha: 0.035),
            counter: .dynamic(0x818b98, 0x656c76, lightAlpha: 0.2, darkAlpha: 0.4),
            tabIndicator: .dynamic(0xfd8c73, 0xf78166), mergeButton: .dynamic(0x1f883d, 0x238636),
            markTint: nil),
        filledPills: true,
        mark: "octicon.mark-github", open: "octicon.git-pull-request", draft: "octicon.git-pull-request-draft",
        merged: "octicon.git-merge", closed: "octicon.git-pull-request-closed",
        check: "octicon.check", cross: "octicon.x", alert: "octicon.alert", pending: "octicon.dot-fill",
        comment: "octicon.comment", eye: "octicon.eye", pencil: "octicon.pencil",
        changesRequested: "octicon.file-diff", approved: "octicon.check", behind: "octicon.git-compare",
        autoMerge: "octicon.git-merge-queue", external: "octicon.link-external",
        conversation: "octicon.comment-discussion", checks: "octicon.checklist", files: "octicon.file-diff")

    static let gitlab = ServiceArt(
        kind: .gitlab,
        palette: Palette(
            open: .dynamic(0x108548, 0x2da160), draft: .dynamic(0x737278, 0x89888d),
            merged: .dynamic(0x1f75cb, 0x428fdc), closed: .dynamic(0xdd2b0e, 0xec5941),
            attention: .dynamic(0xc17d10, 0xd99530),
            openInk: .dynamic(0x108548, 0x52b87a), draftInk: .dynamic(0x626168, 0xbfbfc3),
            mergedInk: .dynamic(0x1f75cb, 0x63a6e9), closedInk: .dynamic(0xdd2b0e, 0xec5941),
            attentionInk: .dynamic(0xab6100, 0xd99530),
            link: .dynamic(0x1f75cb, 0x63a6e9), linkWash: .dynamic(0xcbe2f9, 0x428fdc, darkAlpha: 0.22),
            border: .dynamic(0xdcdcde, 0x4c4b51), muted: .dynamic(0xfbfafd, 0xffffff, darkAlpha: 0.035),
            counter: .dynamic(0xececef, 0x3a383f), tabIndicator: .dynamic(0x1f75cb, 0x428fdc),
            mergeButton: .dynamic(0x1f75cb, 0x1f75cb), markTint: .dynamic(0xfc6d26, 0xfc6d26)),
        filledPills: false,
        mark: "brand.gitlab", open: "gitlab.merge-request-open", draft: "gitlab.merge-request",
        merged: "gitlab.merge", closed: "gitlab.merge-request-close",
        check: "gitlab.check", cross: "gitlab.close", alert: "gitlab.warning", pending: "gitlab.status_running_borderless",
        comment: "gitlab.comment", eye: "gitlab.eye", pencil: "gitlab.pencil",
        changesRequested: "gitlab.warning", approved: "gitlab.approval", behind: "gitlab.branch",
        autoMerge: "gitlab.clock", external: "gitlab.external-link",
        conversation: "gitlab.overview", checks: "gitlab.pipeline", files: "gitlab.doc-changes")
}

extension CodeHost {
    var art: ServiceArt { kind == .gitlab ? .gitlab : .github }
}

extension Color {
    /// One colour per appearance, resolved by AppKit each time it draws, so a palette follows the
    /// system's light/dark switch without the views re-reading anything.
    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func color(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark, darkAlpha) : color(light, lightAlpha)
        })
    }
}

// MARK: - Views

/// A vendored service glyph at an explicit point size. Octicons and GitLab's icons are drawn on a
/// 16 pt grid and fill it, so unlike `arrow.trianglehead.pull` they need no optical compensation (ADR-089).
struct ServiceIcon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The service's mark: the GitHub Invertocat in the text colour, GitLab's tanuki in its orange.
struct ServiceMark: View {
    let host: CodeHost
    var size: CGFloat = 16

    var body: some View {
        let art = host.art
        ServiceIcon(art.mark, size: size)
            .foregroundStyle(art.palette.markTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            .help(host.name)
    }
}

/// A PR's state in the service's own glyph and colour, with a corner dot for whatever wants attention
/// (ADR-116): an open PR with failing CI still reads as an open PR, with a red flag on it. Replaces the
/// per-attention SF Symbols of ADR-089 in the sidebar, the footer chip and the panel tab.
///
/// The dot is cut out of the glyph rather than ringed in a background colour, so it reads the same on
/// the sidebar, the footer's bar and a selected chip.
struct PRGlyph: View {
    let host: CodeHost
    /// Nil while the PR loads: the open glyph, in tertiary.
    let mark: PullRequestMark?
    var size: CGFloat = 14

    var body: some View {
        let art = host.art
        let dot = (size * 0.44).rounded()
        let glyph = ServiceIcon(mark.map { art.stateGlyph($0.state, isDraft: $0.isDraft) } ?? art.open, size: size)
            .foregroundStyle(mark.map { AnyShapeStyle(art.stateInk($0.state, isDraft: $0.isDraft)) } ?? AnyShapeStyle(.tertiary))
        if let tone = mark?.attentionTone {
            glyph
                .mask {
                    Rectangle()
                        .overlay(alignment: .topTrailing) {
                            Circle().frame(width: dot + 3, height: dot + 3).offset(x: 2.5, y: -2.5).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .overlay(alignment: .topTrailing) {
                    Circle().fill(art.palette.fill(tone)).frame(width: dot, height: dot).offset(x: 1, y: -1)
                }
        } else {
            glyph
        }
    }
}

/// The state pill beside the title, drawn the way the service draws it.
struct ServiceStatePill: View {
    let state: PullRequest.State
    let isDraft: Bool
    let host: CodeHost

    var body: some View {
        let art = host.art
        let fill = art.stateFill(state, isDraft: isDraft)
        HStack(spacing: 4) {
            ServiceIcon(art.stateGlyph(state, isDraft: isDraft), size: 12)
            Text(title)
        }
        .font(.callout.weight(.medium))
        .padding(.leading, 7).padding(.trailing, 9).padding(.vertical, 3)
        .foregroundStyle(art.filledPills ? AnyShapeStyle(.white) : AnyShapeStyle(art.stateInk(state, isDraft: isDraft)))
        .background(art.filledPills ? fill : fill.opacity(0.18), in: Capsule())
        .fixedSize()
    }

    private var title: String {
        switch state {
        case .merged: "Merged"
        case .closed: "Closed"
        case .open: isDraft ? "Draft" : "Open"
        }
    }
}

/// A branch name as the service draws one: monospaced, in its link colour on a wash of it.
struct BranchPill: View {
    let name: String
    let host: CodeHost

    var body: some View {
        let p = host.art.palette
        Text(name)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
            .foregroundStyle(p.link)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(p.linkWash, in: RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
