import AppKit
import ClinicCore

/// Close-window and quit behaviour (ADR-069), one per window (ADR-072).
@MainActor
final class WindowLifecycle: NSObject, NSWindowDelegate {
    private let tabs: TabStore
    private let state: WindowState
    private weak var original: NSWindowDelegate?
    private weak var window: NSWindow?

    init(tabs: TabStore, window: WindowState) { self.tabs = tabs; self.state = window }

    /// Wraps the main window's existing delegate so only `windowShouldClose` is intercepted.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        original = window.delegate
        window.delegate = self
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Not the last window: its tabs move elsewhere, nothing is stopped (ADR-072).
        if tabs.windows.count > 1 { tabs.windowWillClose(state); return true }
        guard tabs.runningCount > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep sessions running?"
        alert.informativeText = "\(tabs.runningCount) session(s) are running. Keep Running hides the window and leaves them exactly as they are; Quit stops them cleanly."
        let statusItemOn = UserDefaults.standard.object(forKey: "ClinicShowStatusItem") as? Bool ?? true
        if statusItemOn { alert.addButton(withTitle: "Keep Running"); alert.addButton(withTitle: "Quit") }
        else { alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Keep Running") }
        alert.addButton(withTitle: "Cancel")
        let r = alert.runModal()
        let keep = statusItemOn ? (r == .alertFirstButtonReturn) : (r == .alertSecondButtonReturn)
        let quit = statusItemOn ? (r == .alertSecondButtonReturn) : (r == .alertFirstButtonReturn)
        if keep { return true }                      // window hides; sessions untouched
        if quit { NSApp.terminate(nil); return false }
        return false
    }

    static func showMainWindow() {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) { w.makeKeyAndOrderFront(nil) }
    }

    enum QuitChoice { case quit, backgroundAll, hide, cancel }

    /// Quit with running sessions, per the preference (ADR-069).
    /// Runs alone (ADR-122): they die with the app, so say so once.
    static func confirmQuit(runningRuns: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = runningRuns == 1 ? "Quit with a run still going?" : "Quit with \(runningRuns) runs still going?"
        alert.informativeText = "Quitting stops them. Hide Window keeps them running."
        alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Hide Window"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: NSApp.windows.forEach { if $0.canBecomeMain { $0.orderOut(nil) } }; return false
        default: return false
        }
    }

    static func quitChoice(runningCount: Int, runningRuns: Int = 0) -> QuitChoice {
        switch UserDefaults.standard.string(forKey: "ClinicQuitBehaviour") ?? "ask" {
        case "quit": return .quit
        case "background": return .backgroundAll
        case "hide": return .hide
        default:
            let alert = NSAlert()
            alert.messageText = "Quit with \(runningCount) running session(s)?"
            alert.informativeText = "Quit stops them cleanly (resume later). Background All detaches idle sessions so they keep working (attach later). Hide Window keeps everything as it is."
                + (runningRuns > 0 ? " \(runningRuns == 1 ? "A run is" : "\(runningRuns) runs are") going too; quitting or backgrounding stops \(runningRuns == 1 ? "it" : "them")." : "")
            alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Background All"); alert.addButton(withTitle: "Hide Window"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .quit
            case .alertSecondButtonReturn: return .backgroundAll
            case .alertThirdButtonReturn: return .hide
            default: return .cancel
            }
        }
    }
}
