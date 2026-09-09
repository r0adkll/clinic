import Foundation
import ServiceManagement
import os

/// The launchd half of *Run automations when Clinic isn't open* (ADR-095).
///
/// Worth being clear about what this is not: it is **not a second scheduler**. Clinic has one
/// scheduler, in `AutomationsModel`. This registers a bundled `SMAppService.agent` that runs
/// `clinic-wake` every five minutes, which relaunches Clinic hidden, at which point that one
/// scheduler's ordinary catch-up pass does everything.
///
/// A *bundled* agent means a **static** plist, which is the whole reason the interval is a fixed
/// 300 s rather than a `StartCalendarInterval` computed from the automations. The alternative —
/// writing a plist into `~/Library/LaunchAgents` and `launchctl bootstrap`-ing it on every edit —
/// buys minute-accuracy while Clinic is closed and costs a moving part in the user's login session.
/// The price is stated on the preference: in this mode a 09:00 automation may fire as late as 09:04.
@MainActor
enum AutomationWake {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "automations")
    static let plistName = "com.r0adkll.clinic.wake.plist"
    static let defaultsKey = "ClinicWakeForAutomations"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static var status: SMAppService.Status { SMAppService.agent(plistName: plistName).status }

    /// Registering can fail — most often because the user has the login item switched off in System
    /// Settings — so the caller gets the error to show rather than a silent no-op.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        let service = SMAppService.agent(plistName: plistName)
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
                clearQuitSuppression()
            } else if service.status == .enabled {
                try service.unregister()
            }
            UserDefaults.standard.set(enabled, forKey: defaultsKey)
            return nil
        } catch {
            log.error("wake agent \(enabled ? "register" : "unregister", privacy: .public) failed: \(error, privacy: .public)")
            return (error as NSError).localizedDescription
        }
    }

    // MARK: - Quit suppression

    private static var markerURL: URL {
        ClinicPathsShim.directory.appendingPathComponent("wake-suppressed", isDirectory: false)
    }

    /// Called when the user quits Clinic on purpose. Until the next login the wake agent will find
    /// this marker and do nothing — an app that comes back four minutes after you quit it is hostile.
    ///
    /// The marker records the current boot time rather than a date, so it expires exactly when a new
    /// login session begins instead of after some guessed interval.
    static func suppressUntilNextLogin() {
        guard isEnabled else { return }
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? String(Int(bootTime())).write(to: markerURL, atomically: true, encoding: .utf8)
    }

    /// Cleared whenever Clinic starts normally, so a relaunch by hand re-arms the wake.
    static func clearQuitSuppression() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    private static func bootTime() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec)
    }
}

/// `ClinicPaths` lives in ClinicCore; this keeps the wake controller from importing it just for one
/// directory, and honours `CLINIC_APP_SUPPORT` the same way so a smoke instance never writes a marker
/// the real app would then obey.
enum ClinicPathsShim {
    static var directory: URL {
        let base: URL
        if let o = ProcessInfo.processInfo.environment["CLINIC_APP_SUPPORT"], !o.isEmpty {
            base = URL(fileURLWithPath: o, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        return base.appendingPathComponent("Clinic", isDirectory: true)
    }
}

/// Launch at Login (`SMAppService.mainApp`) — the gentler mitigation, and the one most users should
/// take instead of the wake agent: Clinic is designed to stay resident (ADR-067's status item,
/// ADR-069's Keep Running), so having it start with the session is usually enough.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }
}
