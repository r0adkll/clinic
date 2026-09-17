import SwiftUI
import ClinicCore

/// The stack a pull request is in, drawn the way GitHub draws it: the top layer first, down to the
/// branch the stack lands on (ADR-163). Each layer wears the same glyph and attention dot as its own
/// pane, the one on screen is marked, and any other opens its pane in this tab.
struct PRStackMap: View {
    let stack: PullRequestStack
    let current: PullRequestRef
    let open: (PullRequestRef) -> Void
    /// Stacks of four or fewer start open; a taller one starts on the layers either side of this one.
    @State private var expanded: Bool?

    /// Top of the stack first.
    private var rows: [PullRequestStack.Entry] { stack.entries.reversed() }
    private var host: CodeHost { current.codeHost }
    private var isExpanded: Bool { expanded ?? (stack.entries.count <= 4) }

    private var shown: [PullRequestStack.Entry] {
        guard !isExpanded else { return rows }
        return rows.filter { abs($0.position - stack.position) <= 1 }
    }

    var body: some View {
        let p = host.art.palette
        VStack(spacing: 0) {
            header
            ForEach(shown) { entry in
                Rectangle().fill(p.border).frame(height: 1)
                row(entry)
            }
            Rectangle().fill(p.border).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                Text("onto").font(.caption).foregroundStyle(.secondary)
                BranchPill(name: stack.baseRefName, host: host)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 12)).foregroundStyle(.secondary)
            (Text("Stack").fontWeight(.semibold) + Text("  \(stack.position) of \(stack.size)").foregroundStyle(.secondary))
                .font(.callout)
            Spacer(minLength: 4)
            if stack.entries.count > 3 {
                Button(isExpanded ? "Show fewer" : "Show all \(stack.entries.count)") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded = !isExpanded }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(host.art.palette.link)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(host.art.palette.muted)
    }

    private func row(_ entry: PullRequestStack.Entry) -> some View {
        let isCurrent = entry.ref == current
        let p = host.art.palette
        return Button { if !isCurrent { open(entry.ref) } } label: {
            HStack(spacing: 8) {
                Text("\(entry.position)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, alignment: .trailing)
                PRGlyph(host: host, mark: entry.mark, size: PRStyle.glyphSize.chip)
                Text(host.reference(entry.ref.number))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(entry.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if isCurrent {
                    Text("This \(host.abbreviation)").font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? p.linkWash : .clear)
            .overlay(alignment: .leading) {
                if isCurrent { Rectangle().fill(p.link).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCurrent ? entry.mark.summary : "\(entry.mark.summary) · \(entry.headRefName) — open its \(host.abbreviation)")
    }
}
