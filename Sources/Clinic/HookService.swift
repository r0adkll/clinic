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

    init(appSupport: URL = ClinicPaths.appSupport) {
        let dir = appSupport.appendingPathComponent("Clinic", isDirectory: true)
        settingsFileURL = dir.appendingPathComponent("hooks.json")
        traceDirectory = dir.appendingPathComponent("trace", isDirectory: true)
        server = HookServer(socketPath: HookServer.defaultSocketPath(appSupport: appSupport))
    }

    static var helperPath: String {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "clinic-hook") { return url.path }
        if let url = Bundle.main.url(forResource: "clinic-hook", withExtension: nil) { return url.path }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clinic-hook").path
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: settingsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HookSettings.json(helperPath: Self.helperPath, socketPath: server.socketPath).write(to: settingsFileURL, options: .atomic)
            server.onUndecodable = { data, error in
                Self.log.error("undecodable hook payload (\(data.count) bytes): \(error, privacy: .public)")
            }
            try server.start()
            isRunning = true
            let events = server.events
            pumpTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    if self.traceEnabled { self.trace(event) }
                    self.onEvent?(event)
                }
            }
            Self.log.info("hook server listening at \(self.server.socketPath, privacy: .public)")
        } catch {
            Self.log.error("hook service failed to start: \(error, privacy: .public)")
        }
    }

    func stop() { pumpTask?.cancel(); server.stop() }

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
