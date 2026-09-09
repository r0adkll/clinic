import SwiftUI
import ClinicCore

/// A whole scope in one virtualised scroll (ADR-080).
///
/// Every rendered line is its own row of one `LazyVStack`, so SwiftUI builds only what is on screen.
/// The earlier shape — a non-lazy stack per file, each inside its own horizontal `ScrollView` —
/// stopped virtualisation at the file boundary and made a large diff unscrollable.
struct DiffScrollView: View {
    /// The model is passed by reference on purpose. `DiffPage` and the highlight dictionary are
    /// `Equatable` and enormous — handing them to a view by value makes SwiftUI deep-compare tens
    /// of thousands of rows and strings on every single update.
    let model: DiffPanelModel
    /// Reported as the reader scrolls, so the rail above can follow along.
    var onVisibleFileChanged: ((String?) -> Void)? = nil
    /// Set to a path to jump there; cleared by the view once it has scrolled.
    @Binding var scrollTarget: String?

    @State private var viewport: CGSize = .zero

    /// Gutter is two line-number columns plus the +/− marker.
    private static let gutter: CGFloat = 42 + 42 + 16 + 10

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.page.files) { file in
                        Section {
                            ForEach(file.rows) { row in DiffRowView(row: row, attributed: model.highlights[row.id]) }
                        } header: {
                            DiffFileHeader(file: file.file, collapsed: model.isCollapsed(file.path)) {
                                model.toggleCollapsed(file.path)
                            }
                            .id(file.path)
                        }
                    }
                    if model.page.hasMore { showMoreRow }
                }
                // A two-axis ScrollView centres content smaller than its viewport, which left a
                // one-file diff floating in the middle of the panel. Filling the viewport and
                // aligning top-leading puts short diffs where a reader expects them.
                .frame(width: contentWidth, alignment: .topLeading)
                .frame(minHeight: viewport.height, alignment: .topLeading)
                .scrollTargetLayout()
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
            .onScrollTargetVisibilityChange(idType: String.self) { visible in
                guard let first = visible.compactMap({ DiffPage.fileIndex(ofRowId: $0) }).min(),
                      let file = model.page.files.first(where: { $0.index == first }) else { return }
                onVisibleFileChanged?(file.path)
            }
            .onChange(of: scrollTarget) {
                guard let target = scrollTarget else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// The font is monospaced, so the widest line is arithmetic rather than a measurement pass over
    /// every row — which is also what keeps the content width from jumping as rows come and go.
    private var contentWidth: CGFloat {
        max(viewport.width, CGFloat(model.page.columns) * DiffMetrics.advance + Self.gutter)
    }

    private var showMoreRow: some View {
        Button { model.showMoreFiles() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down.circle")
                Text("Show \(model.page.remainingFiles) more file\(model.page.remainingFiles == 1 ? "" : "s")")
                Text("of \(model.page.totalFiles)").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
    }
}

@MainActor
enum DiffMetrics {
    /// Width of one character in the diff font. Measured once: the font is monospaced, so this is
    /// all the geometry the content width needs.
    static let advance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()
}

struct DiffFileHeader: View {
    let file: UnifiedDiffFile
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 10)
                Text(file.path).font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1).truncationMode(.head)
                if file.isNew { DiffTag("new", .green) } else if file.isDeleted { DiffTag("deleted", .red) }
                if let old = file.oldPath, let new = file.newPath, old != new { DiffTag("renamed", .blue) }
                Spacer(minLength: 8)
                Text("+\(file.additions)").foregroundStyle(.green).font(.caption.monospacedDigit())
                Text("−\(file.deletions)").foregroundStyle(.red).font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }
}

private struct DiffTag: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// One row: a hunk header or a line. Deliberately cheap — it is built and thrown away as the reader
/// scrolls, so it holds no state and does no measuring.
struct DiffRowView: View {
    let row: DiffRow
    let attributed: AttributedString?

    var body: some View {
        switch row.kind {
        case .hunk(let header):
            Text(header)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
        case .line(let line):
            DiffLineView(line: line, attributed: attributed)
        }
    }
}

struct DiffLineView: View {
    let line: DiffLine
    var attributed: AttributedString? = nil

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newLineNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(marker).frame(width: 16).foregroundStyle(.secondary)
            if let attributed {
                Text(attributed)
            } else {
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
            }
            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(.callout, design: .monospaced))
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

/// A single file, read-only, for the PR page's per-file rendering (ADR-053).
struct DiffView: View {
    let file: UnifiedDiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DiffFileHeader(file: file, collapsed: false) {}.allowsHitTesting(false)
            ForEach(DiffPage.rows(for: file, index: 0)) { row in DiffRowView(row: row, attributed: nil) }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
