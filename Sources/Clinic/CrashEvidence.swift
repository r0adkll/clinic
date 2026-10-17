import AppKit
import ClinicCore
import MetricKit
import OSLog

/// What a crash leaves behind (ADR-225): the exception and the workspace as it stood, written to
/// `diagnostics/`, with the crash and hang diagnostics MetricKit delivers on a later launch beside them.
///
/// An exception AppKit catches during a display cycle (the layout loop of 2026-10-17) is logged and the process
/// then ends with `exit(6)`. That is not a signal, so no crash report is written, and nothing on the way out
/// runs: not the uncaught-exception handler, not `atexit`, not a wrapped `reportException(_:)`, and
/// `NSApplicationCrashOnExceptions` changes nothing (all tried, 2026-10-17). The one place that sees it is the
/// throw itself. So an exception thrown on the main thread is written at once, provisionally, and the file
/// is deleted if the app is still running a few seconds later, when it was caught and handled after all.
enum CrashEvidence {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "crash")
    /// How long a provisional report waits for the process to die before it counts as handled.
    private static let grace: TimeInterval = 10
    private static let lock = NSLock()
    // Set at launch, or under `lock`; read by the C callbacks, which cannot capture.
    nonisolated(unsafe) private static var pending: URL?
    nonisolated(unsafe) private static var busy = false
    nonisolated(unsafe) private static var previousPreprocessor: objc_exception_preprocessor?
    nonisolated(unsafe) private static var dump: (@MainActor () -> WorkspaceDump)?
    nonisolated(unsafe) private static var archiver: DiagnosticArchiver?

    @MainActor
    static func install(dump: @escaping @MainActor () -> WorkspaceDump) {
        self.dump = dump
        previousPreprocessor = objc_setExceptionPreprocessor { object in
            if Thread.isMainThread, let exception = object as? NSException { CrashEvidence.thrown(exception) }
            return CrashEvidence.previousPreprocessor?(object) ?? object
        }
        // An exception no one catches, on any thread, does reach this.
        NSSetUncaughtExceptionHandler { exception in CrashEvidence.thrown(exception) }
        let archiver = DiagnosticArchiver()
        MXMetricManager.shared.add(archiver)
        self.archiver = archiver
        raiseInLayoutIfAsked()
    }

    /// Writes the report, once per grace period. The exception goes to disk before the workspace is read, so a
    /// dump that itself fails still leaves the reason and the stack.
    private static func thrown(_ exception: NSException) {
        lock.lock()
        let free = !busy
        busy = true
        lock.unlock()
        guard free else { return }
        let info = ProcessInfo.processInfo
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
            + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")"
        // From the throw down: the frames above `objc_exception_throw` are this recorder's own.
        var stack = exception.callStackSymbols.isEmpty ? Thread.callStackSymbols : exception.callStackSymbols
        if let throwFrame = stack.firstIndex(where: { $0.contains("objc_exception_throw") }) { stack.removeFirst(throwFrame) }
        var report = ExceptionReport(name: exception.name.rawValue, reason: exception.reason, callStack: stack,
                                     date: Date(), appVersion: version, osVersion: info.operatingSystemVersionString)
        let archive = DiagnosticsArchive.standard
        guard let data = try? report.encoded(), let url = try? archive.write(data, kind: "exception", at: report.date) else {
            lock.lock(); busy = false; lock.unlock()
            return
        }
        lock.lock(); pending = url; lock.unlock()
        if Thread.isMainThread, let dump {
            report.workspace = MainActor.assumeIsolated { dump() }
            if let data = try? report.encoded() { try? archive.write(data, kind: "exception", at: report.date) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { survived(url) }
    }

    /// Still running: the exception was caught and handled, so its provisional report goes.
    private static func survived(_ url: URL) {
        lock.lock()
        let mine = pending == url
        if mine { pending = nil; busy = false }
        lock.unlock()
        guard mine else { return }
        try? FileManager.default.removeItem(at: url)
        log.debug("an exception was handled; its provisional report is gone")
    }

    /// `-ClinicRaiseInLayoutAfter <seconds>`: throws from inside a window layout pass, the path an AppKit layout
    /// exception takes, to check that a report and its workspace are written (ADR-225).
    @MainActor
    private static func raiseInLayoutIfAsked() {
        let after = UserDefaults.standard.double(forKey: "ClinicRaiseInLayoutAfter")
        guard after > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            MainActor.assumeIsolated {
                guard let frame = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView?.superview else { return }
                let probe = RaisingView(frame: .zero)
                frame.addSubview(probe)
                probe.needsLayout = true
            }
        }
    }

    private final class RaisingView: NSView {
        override func layout() {
            super.layout()
            NSException(name: .internalInconsistencyException, reason: "ClinicRaiseInLayoutAfter", userInfo: nil).raise()
        }
    }
}

/// Keeps every diagnostic payload MetricKit delivers (crashes, hangs, CPU and disk-write exceptions) as
/// its own JSON, in the archive the exception reports go to (ADR-225).
private final class DiagnosticArchiver: NSObject, MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            try? DiagnosticsArchive.standard.write(payload.jsonRepresentation(), kind: "metrickit", at: payload.timeStampEnd)
        }
    }
}

extension TabStore {
    /// Every window and every open session's tabs, for an exception report (ADR-225).
    func workspaceDump() -> WorkspaceDump {
        func describe(_ r: NSRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
        func area(_ group: SidePanel, claude: Bool, frame: NSRect?) -> WorkspaceDump.Area {
            var panes = group.panes.map { pane -> String in
                let kind = String(String(describing: pane.kind).prefix { $0 != "(" })
                return pane.id == group.selectedId ? kind + "*" : kind
            }
            if claude { panes.insert(group.selectedId == nil ? "claude*" : "claude", at: 0) }
            return .init(panes: panes, visible: claude || group.isVisible, frame: frame.map(describe) ?? "hidden")
        }
        let windows = windows.map { w -> WorkspaceDump.Window in
            let ns = w.nsWindow
            let tab = selectedTab(in: w)
            // The toolbar's per-session controls, decided as `RootToolbar` decides them.
            var toolbar: [String] = []
            if let tab, tab.replay == nil, !w.isShowingScreen {
                toolbar.append("run")
                toolbar += devicePlatforms(for: tab).map { "device:" + $0.rawValue }
                toolbar.append("open-in")
            }
            return .init(id: w.id.uuidString, frame: ns.map { describe($0.frame) } ?? "none",
                         fullScreen: ns?.styleMask.contains(.fullScreen) ?? false, isKey: ns?.isKeyWindow ?? false,
                         selectedTab: w.selectedTabId?.uuidString,
                         showing: w.screen?.title ?? (w.editingDraft != nil ? "New session" : nil), toolbar: toolbar)
        }
        let tabs = tabs.map { t -> WorkspaceDump.Tab in
            let frames = t.contentView.areaFrames
            return .init(id: t.id.uuidString, window: t.windowId.uuidString, session: t.sessionId?.rawValue,
                         title: t.title, project: t.projectPath, state: t.state?.rawValue, replay: t.isReplay,
                         focusedArea: "\(t.focusedArea)",
                         main: area(t.main, claude: true, frame: frames.main), panel: area(t.panel, claude: false, frame: frames.panel))
        }
        return WorkspaceDump(windows: windows, tabs: tabs)
    }
}
