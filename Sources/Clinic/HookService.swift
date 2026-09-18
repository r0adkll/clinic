import Foundation
import os
import ClinicCore

/// Owns the Unix socket server and the hooks settings file passed to every launch (ADR-015, ADR-027).
@MainActor
final class HookService {
    nonisolated private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "hooks")

    let server: HookServer
    let settingsFileURL: URL
    private(set) var isRunning = false
    var onEvent: ((HookEvent) -> Void)?
    private var pumpTask: Task<Void, Never>?
    /// ADR-027 / ADR-038: hidden `defaults write com.r0adkll.clinic ClinicHookTrace -bool YES` appends every payload to trace/<session>.jsonl.
    let traceDirectory: URL
    var traceEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.hookTrace) }

    /// Empty for the first Clinic on this Application Support directory, `-<pid>` for any other, which
    /// then keeps sockets and settings files of its own and leaves the first one's alone (ADR-167).
    /// Decided once, before either server binds.
    static let instanceSuffix: String = {
        SocketClaim.sweepStale(in: ClinicPaths.directory)
        return SocketClaim.instanceSuffix(appSupport: ClinicPaths.appSupport)
    }()

    init(appSupport: URL = ClinicPaths.appSupport) {
        let dir = appSupport.appendingPathComponent("Clinic", isDirectory: true)
        let suffix = Self.instanceSuffix
        settingsFileURL = dir.appendingPathComponent("hooks\(suffix).json")
        traceDirectory = dir.appendingPathComponent("trace", isDirectory: true)
        server = HookServer(socketPath: HookServer.defaultSocketPath(appSupport: appSupport, suffix: suffix))
    }

    /// The `--settings` file for a launch: plain `hooks.json`, or for a worktree launch a twin that also
    /// names the CLI's `worktree.baseRef` (ADR-118). A second `--settings` flag would replace the first,
    /// hooks and all, so the base has to ride in the same file.
    func settingsFileURL(worktreeBaseRef: String?) -> URL {
        guard let worktreeBaseRef else { return settingsFileURL }
        return settingsFileURL.deletingLastPathComponent().appendingPathComponent("hooks\(Self.instanceSuffix)-worktree-\(worktreeBaseRef).json")
    }

    static let worktreeBaseRefs = ["fresh", "head"]

    static var helperPath: String {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "clinic-hook") { return url.path }
        if let url = Bundle.main.url(forResource: "clinic-hook", withExtension: nil) { return url.path }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clinic-hook").path
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: settingsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HookSettings.json(helperPath: Self.helperPath, socketPath: server.socketPath).write(to: settingsFileURL, options: .atomic)
            for ref in Self.worktreeBaseRefs {
                try HookSettings.json(helperPath: Self.helperPath, socketPath: server.socketPath, worktreeBaseRef: ref)
                    .write(to: settingsFileURL(worktreeBaseRef: ref), options: .atomic)
            }
            server.onUndecodable = { data, error in
                Self.log.error("undecodable hook payload (\(data.count) bytes): \(error, privacy: .public)")
            }
            server.onRebind = { why in
                Self.log.error("hook socket was \(why, privacy: .public); bound again. Hooks sent in between were lost.")
            }
            try server.start()
            isRunning = true
            if !Self.instanceSuffix.isEmpty {
                Self.log.notice("another Clinic owns hook.sock; this instance uses \(self.server.socketPath, privacy: .public)")
            }
            let events = server.events
            pumpTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    // The status line fires on every token update; the trace is for hook sequences (ADR-157).
                    if self.traceEnabled, event.hookEventName != StatusLineReport.eventName { self.trace(event) }
                    self.onEvent?(event)
                }
            }
            Self.log.info("hook server listening at \(self.server.socketPath, privacy: .public)")
        } catch {
            Self.log.error("hook service failed to start: \(error, privacy: .public)")
        }
    }

    func stop() {
        pumpTask?.cancel(); server.stop()
        guard !Self.instanceSuffix.isEmpty else { return }
        for url in [settingsFileURL] + Self.worktreeBaseRefs.map({ settingsFileURL(worktreeBaseRef: $0) }) { try? FileManager.default.removeItem(at: url) }
    }

    private func trace(_ event: HookEvent) {
        do {
            try FileManager.default.createDirectory(at: traceDirectory, withIntermediateDirectories: true)
            let url = traceDirectory.appendingPathComponent("\(event.sessionId.rawValue).jsonl")
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            var line = try enc.encode(event); line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: url) { try h.seekToEnd(); try h.write(contentsOf: line); try h.close() }
            else { try line.write(to: url) }
        } catch { Self.log.error("trace write failed: \(error, privacy: .public)") }
    }
}
