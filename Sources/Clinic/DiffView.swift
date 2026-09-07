import SwiftUI
import ClinicCore

/// Reusable unified diff renderer (ADR-052). Read-only when no callbacks are given.
struct DiffView: View {
    let file: UnifiedDiffFile
    var onStageHunk: ((DiffHunk) -> Void)? = nil
    var onUnstageHunk: ((DiffHunk) -> Void)? = nil
    var onDiscardHunk: ((DiffHunk) -> Void)? = nil

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(file.path).font(.system(.callout, design: .monospaced).weight(.semibold))
                    if file.isNew { Tag("new", .green) } else if file.isDeleted { Tag("deleted", .red) }
                    if let old = file.oldPath, let new = file.newPath, old != new { Tag("renamed from \(old)", .secondary) }
                    Spacer()
                    Text("+\(file.additions)").foregroundStyle(.green).font(.caption.monospacedDigit())
                    Text("−\(file.deletions)").foregroundStyle(.red).font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                if file.isBinary {
                    Text("Binary file").foregroundStyle(.secondary).padding(10)
                } else if file.hunks.isEmpty {
                    Text("No textual changes").foregroundStyle(.secondary).padding(10)
                }
                ForEach(file.hunks) { hunk in
                    hunkHeader(hunk)
                    ForEach(hunk.lines) { line in DiffLineView(line: line) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        HStack(spacing: 6) {
            Text(hunk.headerText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 20)
            if let onStageHunk { Button("Stage") { onStageHunk(hunk) } }
            if let onUnstageHunk { Button("Unstage") { onUnstageHunk(hunk) } }
            if let onDiscardHunk { Button("Discard", role: .destructive) { onDiscardHunk(hunk) } }
        }
        .controlSize(.mini)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
    }

    private func Tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).foregroundStyle(color).padding(.horizontal, 5).padding(.vertical, 1).background(color.opacity(0.12), in: Capsule())
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
            Text(line.newLineNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
            Text(marker).frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text).lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
        .padding(.trailing, 10)
        .background(background)
        .textSelection(.enabled)
    }

    private var marker: String {
        switch line.kind { case .addition: "+"; case .deletion: "−"; case .context: " "; case .noNewline: "\\" }
    }

    private var background: Color {
        switch line.kind {
        case .addition: Color.green.opacity(0.14)
        case .deletion: Color.red.opacity(0.14)
        case .context, .noNewline: .clear
        }
    }
}
