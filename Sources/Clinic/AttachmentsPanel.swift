import AppKit
import ClinicCore
import Observation
import SwiftUI

/// Images the agent showed with `show_image` (ADR-056). Right column, ⌘⇧I.
///
/// List-then-detail, in the chrome every other browser in the panel uses (ADR-102), around a viewer
/// that zooms and pans (ADR-106). It was a grid of 160 pt thumbnails over a fixed-size sheet, which
/// gave a reader no way to look at an image closely — the one thing the panel exists for.

/// Everything one Images pane remembers: which image is selected, what the list is filtered to, the
/// viewer's zoom, and the decoded images behind all three.
///
/// It lives on the `PanelPane` like the diff and editor models do, so toggling the panel or switching
/// tabs does not drop the reader's selection — or re-decode every thumbnail.
@MainActor
@Observable
final class ImageGallery {
    var filter = ""
    var selectedId: UUID?
    let zoom = ImageZoomModel()

    /// Decoding is cached but deliberately *not* observed: a cache fill is not a change to the
    /// gallery, and making it one would invalidate the view that asked for it mid-body.
    @ObservationIgnored private var thumbs: [String: NSImage?] = [:]
    @ObservationIgnored private var factsByPath: [String: ImageFacts?] = [:]
    /// One slot: the image on screen. A full-size decode of every image a long session showed would
    /// hold tens of megabytes for pictures nobody is looking at.
    @ObservationIgnored private var open: (path: String, image: NSImage?)?

    static let thumbnailPixels: CGFloat = 96

    func thumbnail(_ path: String) -> NSImage? {
        if let cached = thumbs[path] { return cached }
        let image = ImageFile.thumbnail(path, maxPixel: Self.thumbnailPixels)
        thumbs[path] = image
        return image
    }

    func facts(_ path: String) -> ImageFacts? {
        if let cached = factsByPath[path] { return cached }
        let facts = ImageFile.facts(path)
        factsByPath[path] = facts
        return facts
    }

    func image(_ path: String) -> NSImage? {
        if let open, open.path == path { return open.image }
        let image = ImageFile.full(path)
        open = (path, image)
        return image
    }

    /// Newest first, ranked by the same matcher the file browsers use (ADR-102) over the caption and
    /// the file's name — the two things a reader remembers about an image.
    func rows(_ items: [ClinicState.Attachment]) -> [ClinicState.Attachment] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.compactMap { item -> (ClinicState.Attachment, Int)? in
            let name = (item.path as NSString).lastPathComponent
            let best = [name, item.caption ?? ""].compactMap { FuzzyMatcher.match(query, in: $0)?.score }.max()
            return best.map { (item, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// The image on screen: the one selected, or the newest when the selection has gone (removed,
    /// or filtered out from under it). One rule, used by the pane and by ⌘Y.
    func selection(in rows: [ClinicState.Attachment]) -> ClinicState.Attachment? {
        rows.first { $0.id == selectedId } ?? rows.first
    }

    func step(_ delta: Int, in rows: [ClinicState.Attachment]) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedId } ?? 0
        let next = min(max(current + delta, 0), rows.count - 1)
        selectedId = rows[next].id
    }
}

// MARK: - The pane

struct AttachmentsPanel: View {
    @Environment(SessionStore.self) private var sessions
    let tab: Tab
    @Bindable var gallery: ImageGallery

    /// The width on screen while a drag is in flight; the stored width takes over until then. The
    /// column reads *this*, so the seam moves with the pointer rather than when the drag ends
    /// (ADR-102).
    @State private var live: CGFloat = 0

    private var prefs: ImagePrefs { ImagePrefs.shared }
    private var showList: Binding<Bool> {
        Binding(get: { ImagePrefs.shared.showList }, set: { ImagePrefs.shared.showList = $0 })
    }

    /// Newest first: the image the agent just showed is the one you came to look at.
    private var items: [ClinicState.Attachment] {
        guard let id = tab.sessionId else { return [] }
        return (sessions.state.attachments[id] ?? []).reversed()
    }

    private var rows: [ClinicState.Attachment] { gallery.rows(items) }
    private var selected: ClinicState.Attachment? { gallery.selection(in: rows) }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 0) {
                    PaneHeader {
                        Label("Images", systemImage: "photo.on.rectangle")
                            .font(.system(size: PaneMetrics.label, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    Divider()
                    ContentUnavailableView("No images yet", systemImage: "photo",
                                           description: Text("Images the agent shows with show_image appear here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                browser
            }
        }
        // `show_image` opens this pane and means "look at this one", so a new image takes the
        // selection even when the reader had walked back to an older one.
        .onChange(of: items.first?.id) { _, newest in
            if let newest { gallery.selectedId = newest }
        }
    }

    private var browser: some View {
        GeometryReader { geo in
            let width = ImagePrefs.clamp(live > 0 ? live : prefs.listWidth, available: geo.size.width)
            HStack(spacing: 0) {
                if prefs.showList {
                    VStack(spacing: 0) {
                        listHeader
                        Divider()
                        list
                    }
                    .frame(width: width)
                    TreeSplitHandle(width: $live,
                                    base: width,
                                    clamp: { ImagePrefs.clamp($0, available: geo.size.width) },
                                    commit: { ImagePrefs.shared.listWidth = $0 })
                }
                VStack(spacing: 0) {
                    detailHeader
                    Divider()
                    detail
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: List

    private var listHeader: some View {
        PaneHeader {
            TreeToggleButton(isOn: showList, shownHelp: "Hide the image list", hiddenHelp: "Show the image list")
            TreeFilterField(text: $gallery.filter, matches: rows.count, total: items.count)
        }
    }

    @ViewBuilder
    private var list: some View {
        if rows.isEmpty {
            VStack {
                Text("No matching images").font(.system(size: PaneMetrics.label)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { item in
                            ImageRowView(item: item,
                                         thumbnail: gallery.thumbnail(item.path),
                                         facts: gallery.facts(item.path),
                                         isSelected: item.id == selected?.id) {
                                gallery.selectedId = item.id
                                // Clicking a row hands the pane's keyboard to the viewer, so ↑/↓,
                                // space, return, ⌘C and ⌘⌫ answer from either half (ADR-107).
                                gallery.zoom.focusViewer()
                            }
                            .id(item.id)
                            .contextMenu { verbs(for: item) }
                        }
                    }
                    .padding(.horizontal, FileTreeMetrics.listInset)
                    .padding(.vertical, 4)
                }
                .onChange(of: selected?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    /// Every verb, from wherever it was asked for: the list's keys, the viewer's keys, the context
    /// menus and the header.
    private func run(_ command: ImageCommand) {
        switch command {
        case .step(let delta): gallery.step(delta, in: rows)
        case .quickLook: ImageQuickLook.shared.toggle(paths: rows.map(\.path), showing: selected?.path)
        case .openWindow: if let item = selected { ImageWindowController.show(item) }
        case .copy: if let item = selected { ImageClipboard.copy(item.path) }
        case .remove:
            guard let item = selected, let id = tab.sessionId else { return }
            sessions.update { state in state.attachments[id]?.removeAll { $0.id == item.id } }
            // Removing a row rebuilds the pane's subtree and the window drops the first responder
            // with it, so the next keystroke went to the session tab behind the panel. Asking for the
            // keyboard back on the next turn — after the rebuild — keeps ⌘⌫ repeatable.
            Task { gallery.zoom.focusViewer() }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailHeader: some View {
        PaneHeader {
            if !prefs.showList {
                TreeToggleButton(isOn: showList, shownHelp: "Hide the image list", hiddenHelp: "Show the image list")
            }
            if let item = selected {
                // The name only: the pixel dimensions and the file size live in the viewer's own
                // footer, beside the zoom they explain.
                Text((item.path as NSString).lastPathComponent)
                    .font(.system(size: PaneMetrics.label, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(item.path)
                Spacer(minLength: 4)
                let index = rows.firstIndex { $0.id == item.id } ?? 0
                PaneIconButton(symbol: "chevron.up", help: "Previous image (↑)") { run(.step(-1)) }
                    .disabled(index == 0)
                PaneIconButton(symbol: "chevron.down", help: "Next image (↓)") { run(.step(1)) }
                    .disabled(index >= rows.count - 1)
                PaneIconButton(symbol: "eye", help: "Quick Look (space)") { run(.quickLook) }
                PaneIconButton(symbol: "macwindow.badge.plus", help: "Open in a window (return)") {
                    ImageWindowController.show(item)
                }
                PaneIconMenu(symbol: "ellipsis.circle", help: "More actions") { verbs(for: item) }
            } else {
                Text("Select an image").font(.system(size: PaneMetrics.label)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selected {
            ImageDetailView(path: item.path,
                            caption: item.caption,
                            image: gallery.image(item.path),
                            facts: gallery.facts(item.path),
                            model: gallery.zoom,
                            onCommand: run)
                .contextMenu { verbs(for: item) }
        } else {
            Color(nsColor: .underPageBackgroundColor)
        }
    }

    // MARK: Verbs

    /// One menu, used by the row's context menu, the viewer's, and the header's overflow — so an
    /// image's actions are the same wherever you reach for them.
    @ViewBuilder
    private func verbs(for item: ClinicState.Attachment) -> some View {
        // The keys are spelled out in the titles rather than attached with `.keyboardShortcut`: a
        // bare space or return registered as a menu equivalent would be a key equivalent for the
        // whole window, and the terminal one keystroke away needs both of them.
        Button("Quick Look  ·  Space") { ImageQuickLook.shared.show(paths: rows.map(\.path), showing: item.path) }
        Button("Open in Window  ·  Return") { ImageWindowController.show(item) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
        Divider()
        Button("Copy Image  ·  ⌘C") { ImageClipboard.copy(item.path) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        Divider()
        Button("Remove  ·  ⌘⌫", role: .destructive) {
            guard let id = tab.sessionId else { return }
            sessions.update { state in state.attachments[id]?.removeAll { $0.id == item.id } }
        }
    }
}

enum ImageClipboard {
    /// The image *and* its URL, so the clipboard works both in an editor that wants pixels and in
    /// Finder, which wants a file.
    static func copy(_ path: String) {
        let board = NSPasteboard.general
        board.clearContents()
        var objects: [NSPasteboardWriting] = [URL(fileURLWithPath: path) as NSURL]
        if let image = NSImage(contentsOfFile: path) { objects.insert(image, at: 0) }
        board.writeObjects(objects)
    }
}

// MARK: - A row

/// One image in the list: a thumbnail, its caption or name, and its size and age.
///
/// A dedicated row rather than `FileTreeRowView` because an image's identity *is* its thumbnail, and
/// the thumbnail needs a row two and a half times the height of a file name. It borrows the rest —
/// full-width `Button`, the same selection and hover fills, the same corner radius (ADR-099).
private struct ImageRowView: View {
    let item: ClinicState.Attachment
    let thumbnail: NSImage?
    let facts: ImageFacts?
    let isSelected: Bool
    let activate: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(hovering ? 0.26 : 0.20) }
        if hovering { return Color.primary.opacity(0.09) }
        return .clear
    }

    private var title: String {
        if let caption = item.caption, !caption.isEmpty { return caption }
        return (item.path as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 8) {
                thumb
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: FileTreeMetrics.nameSize, weight: isSelected ? .semibold : .regular))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        if let facts {
                            Text(facts.dimensions).monospacedDigit()
                            Text("·")
                        }
                        Text(item.addedAt, format: .relative(presentation: .named))
                    }
                    .font(.system(size: FileTreeMetrics.subtitleSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(fill, in: RoundedRectangle(cornerRadius: FileTreeMetrics.radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(item.caption ?? item.path)
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    // A 4 × 4 image scaled up to a 48 pt box is a smear under any smoothing; a
                    // photo scaled down needs it. The image's own size decides.
                    .interpolation((facts?.pixels.width ?? 999) < 48 ? .none : .medium)
                    .scaledToFit()
                    .padding(1)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 38)
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.10)) }
    }
}
