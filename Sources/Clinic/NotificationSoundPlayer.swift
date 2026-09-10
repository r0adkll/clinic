import AVFoundation
import AppKit
import Observation
import os
import ClinicCore

/// The one place that decides whether a notification makes a noise, and makes it (ADR-097).
///
/// `UNNotificationSound` can only name a file in the app bundle or `~/Library/Sounds`, so a file the
/// user picked anywhere else has to be played by Clinic itself — which it can, since Clinic is by
/// definition running at the moment it posts. The caller then posts the notification silent.
@MainActor
@Observable
final class NotificationSoundPlayer {
    nonisolated private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "notifications")

    /// The rotation, mirrored into `UserDefaults` on every edit.
    var sounds: NotificationSounds {
        didSet { UserDefaults.standard.set(sounds.encoded(), forKey: NotificationSounds.defaultsKey) }
    }

    /// Where the round-robin stands. In memory on purpose: it starts at the top each launch.
    private var cursor = 0
    /// Players are held until they finish; AVAudioPlayer stops the moment it is released.
    private var active: [AVAudioPlayer] = []

    init() {
        sounds = NotificationSounds(json: UserDefaults.standard.data(forKey: NotificationSounds.defaultsKey))
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.notificationSound) }

    /// The in-app card path (ADR-066): play the next file in the rotation, or the Ping Clinic has
    /// always used when there is no list — or when the file it picked would not play.
    func playForCard() {
        guard isEnabled else { return }
        switch sounds.next(cursor: &cursor) {
        case .file(let url):
            if play(url) != nil { playPing() }
        case .systemDefault:
            playPing()
        }
    }

    /// The system-notification path. The return says whether that notification must be posted
    /// silent — either Clinic has already made the noise, or sound is switched off entirely.
    func playForSystemNotification() -> Bool {
        guard isEnabled else { return true }
        switch sounds.next(cursor: &cursor) {
        case .file(let url):
            return play(url) == nil
        case .systemDefault:
            return false
        }
    }

    /// Play one file on demand, for the ▶ beside its row. Returns why it could not, if it could not.
    @discardableResult
    func preview(_ sound: NotificationSounds.Sound) -> String? {
        play(sound.url)
    }

    /// Whether the list's ▶ should be offered at all, and whether the row reads as missing.
    func isReadable(_ sound: NotificationSounds.Sound) -> Bool {
        FileManager.default.isReadableFile(atPath: sound.path)
    }

    private func playPing() {
        NSSound(named: "Ping")?.play()
    }

    private func play(_ url: URL) -> String? {
        active.removeAll { !$0.isPlaying }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            guard player.play() else { return "Could not play \(url.lastPathComponent)." }
            active.append(player)
            Self.log.debug("notification sound played \(url.lastPathComponent, privacy: .public)")
            return nil
        } catch {
            Self.log.error("notification sound \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            return "Could not play \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
