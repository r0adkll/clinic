import SwiftUI
import ClinicCore

/// The PR panel's Files tab: a tree of changed files beside one file's diff (ADR-091).
///
/// The browsing itself is `DiffBrowserView`, shared with the Diff panel (ADR-101); what belongs to
/// this tab is where the diff comes from and what to say while it is not here yet.
struct PRFilesView: View {
    @Environment(PRStore.self) private var prs
    let ref: PullRequestRef
    let browser: DiffBrowser
    @AppStorage("ClinicPRTreeWidth") private var treeWidth: Double = 210
    /// Separate from the editor panel's `ClinicEditorShowTree` and the Diff panel's own key: these
    /// are different surfaces, and a reader who wants one file list open does not necessarily want
    /// another's.
    @AppStorage("ClinicPRShowTree") private var showTree = true

    var body: some View {
        Group {
            if let diff = prs.diffs[ref.id] {
                if diff.files.isEmpty {
                    ContentUnavailableView("No file changes", systemImage: "doc",
                                           description: Text("This pull request changes nothing."))
                } else {
                    DiffBrowserView(browser: browser, showTree: $showTree, treeWidth: $treeWidth)
                        .task(id: diff.files.map(\.path)) { browser.show(diff.files) }
                }
            } else if let error = prs.errors[ref.id], prs.diffs[ref.id] == nil {
                ContentUnavailableView("Could not load the diff", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await prs.loadDiff(ref) }
            }
        }
    }
}
