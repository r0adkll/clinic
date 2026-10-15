import AppIntents
import AppKit
import Observation
import os

/// Whether a Focus has asked Clinic to keep quiet (ADR-207). Set by Clinic's Focus filter, which the
/// user adds to a Focus in System Settings; no entitlement or permission is involved. While quiet, no
/// pack line and no notification sound plays. Cards, history and banners carry on.
@MainActor
@Observable
final class FocusQuiet {
    static let shared = FocusQuiet()
    nonisolated private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "sounds")

    private(set) var isQuiet: Bool

    private init() {
        // A seam for checks: start as if a Focus had asked for quiet.
        isQuiet = UserDefaults.standard.bool(forKey: "ClinicFocusQuiet")
    }

    func set(quiet: Bool) {
        guard quiet != isQuiet else { return }
        isQuiet = quiet
        Self.log.notice("focus filter: sounds \(quiet ? "quiet" : "on", privacy: .public)")
    }

    /// Reads the filter of the Focus on now, for a launch during one. With no Focus using Clinic's
    /// filter, `current` throws and sounds are on.
    func refresh() async {
        guard !UserDefaults.standard.bool(forKey: "ClinicFocusQuiet") else { return }
        let filter = try? await ClinicFocusFilter.current
        set(quiet: filter.map { !$0.sounds } ?? false)
    }

    /// System Settings ▸ Focus, where a Focus's filters are added.
    static func openFocusSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Clinic's Focus filter: *Sounds* on or off while that Focus is on.
///
/// The system calls `perform` with the user's values when the Focus starts, and with the defaults
/// when it ends, so the default must be the ordinary state: sounds on.
struct ClinicFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Clinic Sounds"
    static let description: IntentDescription? = IntentDescription(
        "Switch Sounds off to keep Clinic's sound pack lines and notification sounds quiet during this Focus. Notifications still arrive.")

    @Parameter(title: "Sounds", default: true)
    var sounds: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: sounds ? "Sounds on" : "Sounds off")
    }

    func perform() async throws -> some IntentResult {
        let quiet = !sounds
        await MainActor.run { FocusQuiet.shared.set(quiet: quiet) }
        return .result()
    }
}
