import SwiftUI
import ClinicCore

/// What a sidebar row knows about its place in the session tree (ADR-181). Empty for a root with
/// nothing under it, which is every row before this ADR.
struct RowLineage: Equatable {
    /// 0 for a root; each level indents once more.
    var depth = 0
    /// Who this session came out of, when that parent is the row above it in the tree or, in
    /// Favorites, simply who it came out of.
    var parent: SessionParent?
    var parentName: String?
    var hasChildren = false
    /// Descendants hidden under this row because it is collapsed.
    var folded: [SessionID] = []
    /// A folded descendant waits for the reader / works: the parent's glyph says so for it.
    var foldedNeedsYou = false
    var foldedRunning = false
    /// The section's project is not this session's own: the row says where it runs.
    var elsewhere: String?

    var isCollapsed: Bool { !folded.isEmpty }

    /// The row's glyph column plus its gap, per level: a child's glyph sits under its parent's title.
    /// Spelled out (10 + 8) because the views that own those metrics are main-actor types.
    static let indent: CGFloat = 18

    var leadingInset: CGFloat { CGFloat(depth) * Self.indent }

    /// Help for the kind glyph: *Forked from X* / *Started by X*.
    var kindHelp: String? {
        guard let parent else { return nil }
        let name = parentName ?? "its parent"
        return parent.kind == .fork ? "Forked from \(name)" : "Started by \(name)"
    }
}

/// The small kind glyph under the status glyph (ADR-181): a branch for a fork, a turn-down arrow for a
/// session another one started. Secondary like the rest of the glyph column; no colour per kind.
struct LineageKindGlyph: View {
    let lineage: RowLineage

    var body: some View {
        if let parent = lineage.parent {
            Image(systemName: parent.kind == .fork ? "arrow.branch" : "arrow.turn.down.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: SessionLeadingGlyph.size, height: 8)
                .help(lineage.kindHelp ?? "")
                .accessibilityLabel(lineage.kindHelp ?? "")
        }
    }
}

/// The fold control at a parent row's trailing edge: a chevron, shown on hover and kept while
/// collapsed, with the number of sessions folded beside it (ADR-181).
struct LineageFoldControl: View {
    @Environment(SessionStore.self) private var sessions
    let id: SessionID
    let lineage: RowLineage
    let hovering: Bool

    var body: some View {
        if lineage.hasChildren, hovering || lineage.isCollapsed {
            Button { sessions.setCollapsed(session: id, !lineage.isCollapsed) } label: {
                HStack(spacing: 3) {
                    if lineage.isCollapsed {
                        Text("\(lineage.folded.count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(lineage.isCollapsed ? 0 : 90))
                }
                .frame(minWidth: 18, minHeight: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(lineage.isCollapsed
                  ? "Show the \(lineage.folded.count == 1 ? "session" : "\(lineage.folded.count) sessions") under this one"
                  : "Hide the sessions under this one")
        }
    }
}

extension View {
    /// Indents a child row under its parent and hangs it off a hairline down from the parent's glyph
    /// column, as a card's children hang (ADR-156, ADR-181). Each row draws its own segment; the list
    /// stacks them into one line.
    func lineageIndent(_ lineage: RowLineage) -> some View {
        padding(.leading, lineage.leadingInset)
            .background(alignment: .leading) {
                if lineage.depth > 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<lineage.depth, id: \.self) { level in
                            Rectangle().fill(.quaternary).frame(width: 1)
                                .padding(.leading, level == 0 ? SessionLeadingGlyph.size / 2 : RowLineage.indent - 1)
                        }
                    }
                    .padding(.vertical, -3)
                }
            }
    }
}
