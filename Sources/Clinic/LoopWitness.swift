import AppKit
import ClinicCore
import OSLog

/// Watches for the layout loop that has ended Clinic five times since 2026-10-17 (ADR-225), and writes down what
/// it can see while the loop runs (ADR-231).
///
/// The loop happens inside one turn of the main run loop: AppKit's display cycle lays the window out, SwiftUI
/// renders, the toolbar comes out changed and marks the window dirty again, until AppKit gives up after as many
/// passes as the window has views and throws. Every frame on the stack is AppKit's or SwiftUI's, so the report
/// `CrashEvidence` writes says that it looped but not which of Clinic's values kept changing.
///
/// A pass is one call of `-[NSWindow updateConstraintsIfNeeded]`, which the display cycle makes once per pass and
/// which `install` swaps for a counting version. The count starts again each time the run loop turns over. At
/// `tripPasses` passes in one turn the witness trips:
/// - it arms an observation tracker on each value the window's views read, one per value, so a change names it
///   (a value written back unchanged notifies no tracker, and so no SwiftUI view either);
/// - it records each following pass in full, up to `recordedPasses`: the values written and the Clinic views that
///   ran since the pass before, the first responder, each toolbar item's width, the window's frame;
/// - it writes `diagnostics/loop-<time>.json` once those are in, and again when the run loop turns over, with
///   the breadcrumbs and the workspace. A loop AppKit lives through leaves a file too.
@MainActor
enum LoopWitness {
    /// A display cycle that settles takes up to about 25 passes in one turn (measured in Clinic Dev, 2026-10-25);
    /// the loop of 2026-10-24 took about 550, AppKit's limit being the window's view count. 100 leaves room both ways.
    static let tripPasses = 100
    static let recordedPasses = 60
    /// Loop files one launch may write, so a window that loops and recovers over and over cannot push the crash
    /// reports out of the archive's 30.
    static let filesPerLaunch = 5

    /// A value a window's views read, by name, and how to read it under an observation tracker.
    struct Probe {
        let name: String
        let read: @MainActor () -> Void
        init(_ name: String, _ read: @escaping @MainActor () -> Void) { self.name = name; self.read = read }
    }

    /// What is known about a window when it trips: its name in the report and its probes.
    struct Subject {
        let name: String
        let probes: [Probe]
    }

    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "loop")
    private static var subject: (@MainActor (NSWindow) -> Subject)?
    private static var dump: (@MainActor () -> WorkspaceDump)?
    /// Passes per window in the current turn of the run loop.
    private static var passes: [ObjectIdentifier: Int] = [:]
    private static var quietMax = 0
    private static var burst: Burst?
    private static var filesWritten = 0

    static func install(subject: @escaping @MainActor (NSWindow) -> Subject, dump: @escaping @MainActor () -> WorkspaceDump) {
        self.subject = subject
        self.dump = dump
        if let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.updateConstraintsIfNeeded)),
           let counting = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.clinic_countedUpdateConstraintsIfNeeded)) {
            method_exchangeImplementations(original, counting)
        }
        // Before sources and before sleeping: a turn that runs its sources and goes straight round again still
        // turns over, so a main thread that is merely busy never adds up to a trip.
        let activities = CFRunLoopActivity.beforeSources.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, _ in
            MainActor.assumeIsolated { LoopWitness.turnedOver() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        loopIfAsked()
    }

    /// One pass of `window`'s layout, from the swapped `updateConstraintsIfNeeded`.
    fileprivate static func pass(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        let count = (passes[id] ?? 0) + 1
        passes[id] = count
        if let burst {
            if burst.window === window { record(burst, pass: count) }
        } else if count == tripPasses {
            trip(window, passes: count)
        }
    }

    /// A Clinic view's body or update ran. Free until the witness trips; then counted against the pass.
    static func rendered(_ name: String) {
        burst?.rendered[name, default: 0] += 1
    }

    /// The loop running now, for an exception report.
    static var current: LoopRecord? { burst?.record }

    /// An exception was thrown on the main thread: the loop's file is brought up to date in case it is the last
    /// chance. A loop that goes on rewrites it.
    static func exceptionThrown() {
        guard let burst else { return }
        burst.record.survived = false
        write(burst)
    }

    private static func turnedOver() {
        for count in passes.values where count < tripPasses { quietMax = max(quietMax, count) }
        passes.removeAll(keepingCapacity: true)
        guard let burst else { return }
        self.burst = nil
        burst.record.ended = true
        burst.record.survived = true
        burst.record.seconds = CFAbsoluteTimeGetCurrent() - burst.started
        write(burst)
        let top = burst.record.changedTotals.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)×\($0.value)" }
        log.error("layout loop in \(burst.record.window, privacy: .public) ended after \(burst.record.passes) passes; written: \(top.joined(separator: ", "), privacy: .public)")
        Breadcrumbs.add("loop", "ended after \(burst.record.passes) passes")
    }

    private static func trip(_ window: NSWindow, passes count: Int) {
        let subject = subject?(window) ?? Subject(name: Breadcrumbs.describe(window), probes: [])
        let burst = Burst(window: window, record: LoopRecord(window: subject.name, trippedAt: Date(), tripPasses: count,
                                                             quietMax: quietMax, probes: subject.probes.map(\.name)))
        burst.arm(subject.probes)
        self.burst = burst
        log.error("layout loop: \(subject.name, privacy: .public) laid out \(count) times in one turn of the run loop; recording")
        Breadcrumbs.add("loop", "tripped in \(subject.name) at \(count) passes")
    }

    private static func record(_ burst: Burst, pass count: Int) {
        burst.record.passes = count
        let changed = burst.takeChanged()
        for name in changed { burst.record.changedTotals[name, default: 0] += 1 }
        for (name, n) in burst.rendered { burst.record.renderedTotals[name, default: 0] += n }
        defer { burst.rendered.removeAll(keepingCapacity: true) }
        guard burst.record.recorded.count < recordedPasses, let window = burst.window else { return }
        let f = window.frame
        burst.record.recorded.append(LoopRecord.Pass(
            index: count, millis: Int((CFAbsoluteTimeGetCurrent() - burst.started) * 1000),
            changed: changed.sorted(),
            rendered: burst.rendered.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" },
            firstResponder: Breadcrumbs.describe(window.firstResponder),
            toolbar: toolbarItems(window),
            frame: "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"))
        if burst.record.recorded.count == recordedPasses { write(burst) }
    }

    /// Each item's identifier and width, read from the item's view without asking the toolbar to lay anything
    /// out: an item that went into the » menu has a view out of the window.
    private static func toolbarItems(_ window: NSWindow) -> [String] {
        (window.toolbar?.items ?? []).map { item in
            let id = item.itemIdentifier.rawValue.replacingOccurrences(of: "com.apple.SwiftUI.", with: "")
            guard let view = item.view else { return "\(id) no view" }
            return view.window == nil ? "\(id) hidden" : "\(id) \(Int(view.frame.width))"
        }
    }

    private static func write(_ burst: Burst) {
        if !burst.counted {
            guard filesWritten < filesPerLaunch else { return }
            filesWritten += 1
            burst.counted = true
        }
        burst.record.seconds = CFAbsoluteTimeGetCurrent() - burst.started
        let info = ProcessInfo.processInfo
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
            + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")"
        let report = LoopReport(date: burst.record.trippedAt, appVersion: version, osVersion: info.operatingSystemVersionString,
                                loop: burst.record, breadcrumbs: Breadcrumbs.entries, workspace: dump?())
        // Same time, same name: each write replaces the loop's last.
        if let data = try? report.encoded() { try? DiagnosticsArchive.standard.write(data, kind: "loop", at: burst.record.trippedAt) }
    }

    /// One tripped loop: its record so far, and the trackers on its window's values.
    @MainActor private final class Burst {
        weak var window: NSWindow?
        var record: LoopRecord
        let started = CFAbsoluteTimeGetCurrent()
        var rendered: [String: Int] = [:]
        var counted = false
        private var probes: [String: Probe] = [:]
        private let changes = Changes()

        init(window: NSWindow, record: LoopRecord) { self.window = window; self.record = record }

        func arm(_ probes: [Probe]) {
            for probe in probes {
                self.probes[probe.name] = probe
                track(probe)
            }
        }

        /// The probes written since the last call, re-armed: a tracker fires once and is spent.
        func takeChanged() -> [String] {
            let names = changes.take()
            for name in names { if let probe = probes[name] { track(probe) } }
            return names
        }

        private func track(_ probe: Probe) {
            let changes = changes, name = probe.name
            // The change handler runs inside the write, on the writer's thread, before the new value lands.
            withObservationTracking { probe.read() } onChange: { changes.insert(name) }
        }
    }

    /// The names of probes written, filled from whichever thread wrote.
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        func insert(_ name: String) { lock.lock(); names.insert(name); lock.unlock() }
        func take() -> [String] { lock.lock(); defer { names.removeAll(); lock.unlock() }; return Array(names) }
    }

    // MARK: Checking it end to end

    /// `-ClinicLoopProbe <passes>`: five seconds after launch, loops the key window's layout for that many passes
    /// the way the real loop does, a layout pass leaving the constraints dirty, and writes values the probes watch
    /// on each. 100 passes is a loop AppKit lives through; 10000 is one it ends the app over.
    private static func loopIfAsked() {
        let wanted = UserDefaults.standard.integer(forKey: "ClinicLoopProbe")
        guard wanted > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let frame = window.contentView?.superview else { return }
                let probe = LoopingView(passes: wanted)
                probe.write = loopProbeWrite
                frame.addSubview(probe)
                probe.needsLayout = true
            }
        }
    }

    /// What the probe view writes on each pass; set by the app to values the probes watch.
    static var loopProbeWrite: (@MainActor () -> Void)?

    @MainActor private final class LoopingView: NSView {
        private var left: Int
        var write: (@MainActor () -> Void)?
        init(passes: Int) { left = passes; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        // What SwiftUI's render does in the real loop: a layout pass that leaves the constraints dirty, whose
        // update then asks for another layout.
        override func layout() {
            super.layout()
            guard left > 0 else { return }
            left -= 1
            write?()
            needsUpdateConstraints = true
        }

        override func updateConstraints() {
            super.updateConstraints()
            if left > 0 { needsLayout = true }
        }
    }
}

extension NSWindow {
    /// Swapped with `updateConstraintsIfNeeded` by `LoopWitness.install`: after the swap this name runs AppKit's.
    @objc fileprivate func clinic_countedUpdateConstraintsIfNeeded() {
        LoopWitness.pass(self)
        clinic_countedUpdateConstraintsIfNeeded()
    }
}

extension AppDelegate {
    /// What the loop witness watches in a window (ADR-231): each observed value the window's views read on a pass
    /// (the toolbar's above all, since the loop runs through the toolbar), one tracker each.
    func loopSubject(for nsWindow: NSWindow) -> LoopWitness.Subject {
        typealias P = LoopWitness.Probe
        var probes: [P] = [
            P("tabs.tabs") { _ = self.tabs.tabs },
            P("tabs.windows") { _ = self.tabs.windows },
            P("tabs.activeWindowId") { _ = self.tabs.activeWindowId },
            P("sessions.sessions") { _ = self.sessions.sessions },
            P("sessions.state") { _ = self.sessions.state },
            P("sessions.projects") { _ = self.sessions.projects },
            P("activities") { _ = self.activities.activities },
            P("runs.runs") { _ = self.tabs.runs.runs },
            P("runs.files") { _ = self.tabs.runs.files },
            P("runs.detected") { _ = self.tabs.runs.detected },
            P("caffeine.isHolding") { _ = self.caffeine.isHolding },
            P("caffeine.workingCount") { _ = self.caffeine.workingCount },
            P("soundPacks.installed") { _ = self.soundPacks.installed },
            P("history.entries") { _ = self.history.entries },
            P("history.card") { _ = self.history.card },
            P("prs.pullRequests") { _ = self.prs.pullRequests },
            P("usage.live") { _ = self.usage.live },
            P("usage.fetched") { _ = self.usage.fetched },
        ]
        guard let window = tabs.windows.first(where: { $0.nsWindow === nsWindow }) else {
            return .init(name: "\(type(of: nsWindow)) \"\(nsWindow.title)\"", probes: probes)
        }
        probes += [
            P("window.selectedTabId") { _ = window.selectedTabId },
            P("window.screen") { _ = window.screen },
            P("window.editingDraft") { _ = window.editingDraft },
            P("window.selectMode") { _ = window.selectMode },
        ]
        if let tab = tabs.selectedTab(in: window) {
            probes += [
                P("tab.state") { _ = tab.state },
                P("tab.waitingOn") { _ = tab.waitingOn },
                P("tab.unread") { _ = tab.unread },
                P("tab.errorBadge") { _ = tab.errorBadge },
                P("tab.pwd") { _ = tab.pwd },
                P("tab.kind") { _ = tab.kind },
                P("tab.replay") { _ = tab.replay },
                P("tab.openedTitle") { _ = tab.openedTitle },
                P("tab.childExited") { _ = tab.childExited },
                P("tab.isAttached") { _ = tab.isAttached },
                P("tab.gitBranch") { _ = tab.gitBranch },
                P("tab.model") { _ = tab.model },
                P("tab.effort") { _ = tab.effort },
                P("tab.statusLine") { _ = tab.statusLine },
                P("tab.focusedArea") { _ = tab.focusedArea },
                P("tab.main.panes") { _ = tab.main.panes },
                P("tab.main.selectedId") { _ = tab.main.selectedId },
                P("tab.panel.panes") { _ = tab.panel.panes },
                P("tab.panel.selectedId") { _ = tab.panel.selectedId },
                P("tab.panel.isVisible") { _ = tab.panel.isVisible },
            ]
        }
        return .init(name: "main \(window.id.uuidString.prefix(8))", probes: probes)
    }
}
