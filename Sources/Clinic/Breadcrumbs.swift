import AppKit
import ClinicCore

/// What the app did lately, for the reports `CrashEvidence` and `LoopWitness` write (ADR-231): hooks, state
/// changes, the terminal's title, directory and progress, selection, and the windows' key, size, sheet and
/// focus changes. The workspace dump says how things stood at the end; this says how they got there.
///
/// Behind a lock rather than on the main actor: an exception on another thread reads it from the uncaught
/// handler.
enum Breadcrumbs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var trail = BreadcrumbTrail()
    @MainActor private static var observers: [NSObjectProtocol] = []
    @MainActor private static var focus: [ObjectIdentifier: NSKeyValueObservation] = [:]

    /// `key` folds a crumb into a recent one with the same key, for things that repeat many times a second.
    static func add(_ category: String, _ message: String, key: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        trail.add(category, message, key: key)
    }

    static var entries: [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return trail.entries
    }

    /// AppKit's own window notifications, for the app's titled windows and sheets (not the status item's, menus'
    /// or tooltips'), and each window's first responder from the first time it becomes key.
    @MainActor
    static func observeWindows() {
        let center = NotificationCenter.default
        let plain: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "key"), (NSWindow.didResignKeyNotification, "resigned key"),
            (NSWindow.willBeginSheetNotification, "sheet begins"), (NSWindow.didEndSheetNotification, "sheet ended"),
            (NSWindow.didEnterFullScreenNotification, "entered full screen"), (NSWindow.didExitFullScreenNotification, "left full screen"),
            (NSWindow.didChangeScreenNotification, "changed screen"), (NSWindow.didMiniaturizeNotification, "minimized"),
            (NSWindow.didDeminiaturizeNotification, "restored"), (NSWindow.willCloseNotification, "closing"),
        ]
        for (name, verb) in plain {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard isWatched(window) else { return }
                    add("window", "\(describe(window)) \(verb)")
                    if name == NSWindow.didBecomeKeyNotification { watchFocus(in: window) }
                    if name == NSWindow.willCloseNotification { focus[ObjectIdentifier(window)] = nil }
                }
            })
        }
        // Live resizing sends one of these per frame: they fold into one crumb per window.
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard isWatched(window) else { return }
                add("window", "\(describe(window)) resized", key: "resize \(window.windowNumber)")
            }
        })
    }

    @MainActor
    private static func isWatched(_ window: NSWindow) -> Bool { window.styleMask.contains(.titled) || window.isSheet }

    /// `firstResponder` is observable by key-value observing. Changes fold per window, so focus bouncing between
    /// two views shows as one crumb with a large repeat count rather than flooding the trail. Session windows are
    /// watched from the moment they are bound, other windows from the first time they become key.
    @MainActor
    static func watchFocus(in window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard focus[id] == nil else { return }
        focus[id] = window.observe(\.firstResponder, options: [.new]) { window, _ in
            MainActor.assumeIsolated {
                add("focus", "\(describe(window)) → \(describe(window.firstResponder))", key: "focus \(window.windowNumber)")
            }
        }
    }

    /// "AppKitWindow #1234 1800x1130": the number is AppKit's, so crumbs and a loop record name the same window.
    @MainActor
    static func describe(_ window: NSWindow) -> String {
        "\(type(of: window)) #\(window.windowNumber) \(Int(window.frame.width))x\(Int(window.frame.height))"
    }

    /// The responder's class and address, so a change of view shows even between two of the same class.
    @MainActor
    static func describe(_ responder: NSResponder?) -> String {
        guard let responder else { return "none" }
        return "\(type(of: responder)) \(Unmanaged.passUnretained(responder).toOpaque())"
    }
}
