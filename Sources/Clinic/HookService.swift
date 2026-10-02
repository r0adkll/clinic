import Foundation
import os
import ClinicCore

/// Owns the Unix socket server and the hooks settings file passed to every launch (ADR-015, ADR-027).
@MainActor
final class HookService {
    nonisolated private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "hooks")

    let server: HookServer
    private let directory: URL
    private(set) var isRunning = false
    var onEvent: ((HookEvent) -> Void)?
    /// A session started, and the mod it was launched with never said it had loaded (ADR-177).
    var onModUnavailable: ((SessionID) -> Void)?
    private var pumpTask: Task<Void, Never>?
    /// Pairs the Grill pane's answers with the session mod waiting for them (ADR-179).
    let asks = AskBroker()

    /// How the sessions launched from now on report (ADR-177). `.command` until `claude --version` has
    /// answered, which it has long before anyone can start a session.
    private(set) var transport: HookTransport = .command
    private(set) var cliVersion: String?
    /// Sessions the mod has spoken for. A `CommandProbe` whose session is not here ten seconds on
    /// means the mod did not load.
    private var modSessions: Set<SessionID> = []
    static let modAttachGrace: Duration = .seconds(10)

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
        directory = appSupport.appendingPathComponent(ClinicPaths.directoryName, isDirectory: true)
        traceDirectory = directory.appendingPathComponent("trace", isDirectory: true)
        server = HookServer(socketPath: HookServer.defaultSocketPath(appSupport: appSupport, suffix: Self.instanceSuffix))
    }

    /// The `--settings` file for a launch on the current transport: plain `hooks.json`, or for a
    /// worktree launch a twin that also names the CLI's `worktree.baseRef` (ADR-118). A second
    /// `--settings` flag would replace the first, hooks and all, so the base has to ride in the same file.
    var settingsFileURL: URL { settingsFileURL(worktreeBaseRef: nil) }

    func settingsFileURL(worktreeBaseRef: String?) -> URL { settingsFileURL(worktreeBaseRef: worktreeBaseRef, transport: transport) }

    /// The settings-hook file whatever the transport, for launches that do not carry `--plugin-dir`:
    /// automations start detached with `--bg` and stay on settings hooks (ADR-095, ADR-177).
    var commandSettingsFileURL: URL { settingsFileURL(worktreeBaseRef: nil, transport: .command) }

    private func settingsFileURL(worktreeBaseRef: String?, transport: HookTransport) -> URL {
        let mod = transport == .mod ? "-mod" : ""
        let worktree = worktreeBaseRef.map { "-worktree-\($0)" } ?? ""
        return directory.appendingPathComponent("hooks\(Self.instanceSuffix)\(mod)\(worktree).json")
    }

    /// `--plugin-dir` for a launch: the session mod's folder on the mod transport, nil otherwise.
    var pluginDirectory: String? { transport == .mod ? modDirectory.path : nil }

    /// The mod runs from a copy in Clinic's own directory, never from the app bundle: the CLI writes
    /// type declarations beside a mod it loads, which would break the bundle's signature (ADR-177).
    private var modDirectory: URL { directory.appendingPathComponent("mod\(Self.instanceSuffix).plugin", isDirectory: true) }

    static let worktreeBaseRefs = ["fresh", "head"]

    static var helperPath: String {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "clinic-hook") { return url.path }
        if let url = Bundle.main.url(forResource: "clinic-hook", withExtension: nil) { return url.path }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clinic-hook").path
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Both transports' files are written, so a launch can use either the moment it is chosen.
            for transport in HookTransport.allCases {
                for ref in [nil] + Self.worktreeBaseRefs.map(Optional.some) {
                    try HookSettings.json(helperPath: Self.helperPath, socketPath: server.socketPath, worktreeBaseRef: ref, transport: transport)
                        .write(to: settingsFileURL(worktreeBaseRef: ref, transport: transport), options: .atomic)
                }
            }
            let modInstalled = installMod()
            resolveTransport(modInstalled: modInstalled)
            server.onUndecodable = { data, error in
                Self.log.error("undecodable hook payload (\(data.count) bytes): \(error, privacy: .public)")
            }
            // The mod waits here for a dialog's answers: `GET /answer?id=<tool_use_id>` (ADR-179).
            server.onPoll = { [asks] target, poll in
                let request = HookWire.Request(method: "GET", target: target)
                guard request.path == "/answer", let id = request.query["id"], !id.isEmpty else {
                    poll.respond(status: 404)
                    return
                }
                asks.poll(id: id, poll)
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
                    if event.via == "mod" { self.modSessions.insert(event.sessionId) }
                    switch event.hookEventName {
                    case HookEvent.modAttached:
                        Self.log.info("session mod attached to \(event.sessionId.rawValue, privacy: .public)")
                    case HookEvent.commandProbe:
                        self.awaitMod(for: event.sessionId)
                    default:
                        self.onEvent?(event)
                    }
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
        for transport in HookTransport.allCases {
            for ref in [nil] + Self.worktreeBaseRefs.map(Optional.some) {
                try? FileManager.default.removeItem(at: settingsFileURL(worktreeBaseRef: ref, transport: transport))
            }
        }
        try? FileManager.default.removeItem(at: modDirectory)
    }

    // MARK: - The session mod (ADR-177)

    /// Copies the mod out of the bundle, fresh at every launch so it always matches this build.
    private func installMod() -> Bool {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("clinic-mod", isDirectory: true),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("hooks/register.ts").path) else {
            Self.log.error("the session mod is missing from the app bundle; using settings hooks")
            return false
        }
        do {
            try? FileManager.default.removeItem(at: modDirectory)
            try FileManager.default.copyItem(at: source, to: modDirectory)
            return true
        } catch {
            Self.log.error("could not install the session mod: \(error, privacy: .public); using settings hooks")
            return false
        }
    }

    /// `ClinicHookTransport` forces `mod` or `command`; anything else is automatic: the mod on a CLI
    /// that loads mods, unless it failed to load on that very version.
    private func resolveTransport(modInstalled: Bool) {
        guard modInstalled else { return }
        Task { [weak self] in
            let version = await HookTransport.detectCLIVersion()
            guard let self else { return }
            self.cliVersion = version
            self.transport = HookTransport.resolve(preference: UserDefaults.standard.string(forKey: Prefs.hookTransport),
                                                   cliVersion: version,
                                                   failedOnVersion: UserDefaults.standard.string(forKey: Prefs.modFailedOnCLIVersion))
            Self.log.info("hook transport: \(self.transport.rawValue, privacy: .public) (claude \(version ?? "not found", privacy: .public))")
        }
    }

    /// The CLI is up and running hooks. If the mod has not spoken for this session by the end of the
    /// grace, it did not load (a policy, or mods switched off), and later launches go back to settings
    /// hooks until the CLI's version changes.
    private func awaitMod(for sessionId: SessionID) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.modAttachGrace)
            guard let self, !self.modSessions.contains(sessionId), self.transport == .mod else { return }
            Self.log.error("the session mod did not load in \(sessionId.rawValue, privacy: .public); falling back to settings hooks")
            if UserDefaults.standard.string(forKey: Prefs.hookTransport) != HookTransport.mod.rawValue {
                self.transport = .command
                UserDefaults.standard.set(self.cliVersion, forKey: Prefs.modFailedOnCLIVersion)
            }
            self.onModUnavailable?(sessionId)
        }
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
