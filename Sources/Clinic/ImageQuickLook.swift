import AppKit
import QuickLookUI

/// Space bar in the Images pane (ADR-107): the system's own Quick Look panel, over the pane's images.
///
/// `QLPreviewPanel` rather than a window Clinic draws itself. It *is* the thing the user asked for —
/// the panel Finder opens on space — and it arrives with the parts that would otherwise all be work:
/// the zoom animation, ← / → between items, "Open with Preview", the share menu, Escape and a second
/// space to dismiss. Clinic supplies a list of URLs and the index to start on.
///
/// The panel is a system singleton driven through the responder chain, so the data source is handed
/// over in `AppDelegate.beginPreviewPanelControl` — the app delegate is the last link of that chain
/// and therefore the one link that is there no matter which half of the pane has focus.
@MainActor
final class ImageQuickLook: NSObject {
    static let shared = ImageQuickLook()

    private var urls: [URL] = []
    /// Where to open. Applied after the panel exists, because setting it needs the data source in place.
    private var startIndex = 0

    private var panelIsUp: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Space: opens the panel on `path`, and closes it if it is already up — Finder's own behaviour,
    /// and the reason space is worth binding at all rather than a second keystroke to dismiss.
    func toggle(paths: [String], showing path: String?) {
        if panelIsUp {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            show(paths: paths, showing: path)
        }
    }

    func show(paths: [String], showing path: String?) {
        guard !paths.isEmpty else { return }
        urls = paths.map { URL(fileURLWithPath: $0) }
        startIndex = path.flatMap { paths.firstIndex(of: $0) } ?? 0
        NSApp.activate()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
        // After ordering front: `beginPreviewPanelControl` runs inside that call, and the index means
        // nothing until the data source behind it is this object's.
        panel.reloadData()
        panel.currentPreviewItemIndex = startIndex
    }

    /// Called from the app delegate when the panel takes control.
    func take(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func release(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }
}

// `@preconcurrency` because QuickLookUI's protocols are not main-actor annotated (the same hatch
// `MarkdownHighlighter` uses for CodeEditSourceEditor's). The panel calls both on the main thread.
extension ImageQuickLook: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    /// The panel swallows key events while it is up; forwarding the ones it does not use keeps the
    /// pane's own keys (the zoom verbs) from going dead behind it.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        // Space closes it, matching the way it opened.
        if event.charactersIgnoringModifiers == " " {
            panel.orderOut(nil)
            return true
        }
        return false
    }
}
