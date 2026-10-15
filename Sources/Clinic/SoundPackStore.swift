import AVFoundation
import AppKit
import Observation
import os
import ClinicCore

/// OpenPeon sound packs (ADR-199): the registry, the packs on this Mac, what the user chose, and the
/// one decision every moment goes through — whether a pack line sounds for it.
///
/// `TabStore.notify` asks `voice` first; a `true` answer means a pack line covers the moment and the
/// notification is posted silent, the way ADR-097 already does for a user's own file.
@MainActor
@Observable
final class SoundPackStore {
    nonisolated private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "sounds")

    enum Section: String, CaseIterable, Identifiable {
        case browse, installed, events
        var id: String { rawValue }
        var label: String {
            switch self {
            case .browse: "Browse"
            case .installed: "Installed"
            case .events: "Events"
            }
        }
    }

    /// What the footer says about the last thing the screen did.
    enum Message: Equatable {
        case done(String)
        case failed(String)
    }

    // MARK: Screen state

    var section: Section = .browse
    /// Browse's filter column, search and sort (ADR-200). The search also narrows Installed.
    var filter = SoundPackFilter()
    var selectedId: String?
    var message: Message?

    // MARK: Packs

    private(set) var registry: [SoundRegistry.Entry] = [] {
        didSet { rebuildCatalog() }
    }
    /// The registry with franchises and spoken lines, ready to filter (ADR-200).
    private(set) var catalog = SoundCatalog(entries: [])
    private(set) var isLoading = false
    private(set) var loadError: String?
    @ObservationIgnored private var fetchedAt: Date?

    /// Every pack Clinic can play, one per name: Clinic's own first, then what other players installed.
    private(set) var installed: [InstalledSoundPack] = []
    private(set) var installing: Set<String> = []
    /// Manifests read from the registry's host, so a pack's every line can be heard before installing.
    private(set) var remoteManifests: [String: CESPManifest] = [:]
    @ObservationIgnored private var manifestTasks: Set<String> = []
    @ObservationIgnored private var prefetching = false

    var settings: SoundSettings {
        didSet { UserDefaults.standard.set(settings.encoded(), forKey: SoundSettings.defaultsKey) }
    }

    // MARK: Playing

    /// The line the screen's ▶ is playing, as `pack/path`, so that button can read ■ until it stops.
    private(set) var previewing: String?
    @ObservationIgnored private var previewURL: URL?
    @ObservationIgnored private let player = LinePlayer()
    @ObservationIgnored private var router = SoundRouter()

    init() {
        settings = SoundSettings(json: UserDefaults.standard.data(forKey: SoundSettings.defaultsKey))
        player.onFinish = { [weak self] url in
            guard let self, self.previewURL == url else { return }
            self.previewing = nil
            self.previewURL = nil
        }
        rescan()
    }

    // MARK: Folders

    /// Clinic's own packs, in this build's data folder, so Clinic Dev keeps its own (ADR-176).
    static var packsDirectory: URL { ClinicPaths.directory.appendingPathComponent("SoundPacks", isDirectory: true) }

    /// Folders other CESP players install into. Clinic reads them and never writes (ADR-018).
    private static var foundDirectories: [(URL, InstalledSoundPack.Origin)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent(".openpeon/packs", isDirectory: true), .openPeon),
            (ClaudePaths().configDirectory.appendingPathComponent("hooks/peon-ping/packs", isDirectory: true), .peonPing),
        ]
    }

    private static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "com.r0adkll.clinic"
        return caches.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("SoundPacks", isDirectory: true)
    }

    func rescan() {
        var seen = Set<String>()
        var packs: [InstalledSoundPack] = []
        for (directory, origin) in [(Self.packsDirectory, InstalledSoundPack.Origin.clinic)] + Self.foundDirectories {
            for pack in SoundPackInstaller.scan(directory, origin: origin) where seen.insert(pack.id).inserted {
                packs.append(pack)
            }
        }
        installed = packs.sorted { $0.manifest.displayName.localizedCaseInsensitiveCompare($1.manifest.displayName) == .orderedAscending }
        if let name = settings.defaultPack, !seen.contains(name) {
            Self.log.notice("default sound pack \(name, privacy: .public) is no longer on disk")
        }
        rebuildCatalog()
    }

    func installedPack(_ name: String) -> InstalledSoundPack? { installed.first { $0.id == name } }
    func entry(_ name: String) -> SoundRegistry.Entry? { registry.first { $0.name == name } }

    /// The registry entry that would update a pack Clinic installed, if the registry has a newer version.
    func update(for pack: InstalledSoundPack) -> SoundRegistry.Entry? {
        guard pack.origin == .clinic, let entry = entry(pack.id),
              PackVersion.isNewer(entry.version, than: pack.manifest.version) else { return nil }
        return entry
    }

    var updateCount: Int { installed.filter { update(for: $0) != nil }.count }

    // MARK: Registry

    /// The cached index straight away, then the network when the cache is over an hour old.
    func loadIfNeeded() {
        if registry.isEmpty, let data = try? Data(contentsOf: Self.cacheDirectory.appendingPathComponent("index.json")),
           let cached = try? SoundRegistry(json: data) {
            registry = cached.packs
            Task { await prefetchManifests() }
        }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 3600 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await Self.download(SoundRegistry.indexURL, limit: 20_000_000)
            registry = try SoundRegistry(json: data).packs
            fetchedAt = Date()
            loadError = nil
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: Self.cacheDirectory.appendingPathComponent("index.json"))
        } catch {
            loadError = "The OpenPeon registry could not be read: \(error.localizedDescription)"
            Self.log.error("registry: \(error, privacy: .public)")
        }
        rescan()
        await prefetchManifests()
    }

    private func rebuildCatalog() {
        var lines: [String: [String]] = [:]
        for (name, manifest) in remoteManifests { lines[name] = manifest.allLines.map(\.label) }
        for pack in installed { lines[pack.id] = pack.manifest.allLines.map(\.label) }
        catalog = SoundCatalog(entries: registry, lines: lines)
    }

    /// Reads every pack's `openpeon.json`, from the cache when this version's is there, so the search
    /// can find a pack by what it says and a pack's page opens with its lines (ADR-200). A few at a time:
    /// the host is shared with everyone, and the list is usable long before this finishes.
    func prefetchManifests() async {
        guard !prefetching else { return }
        prefetching = true
        defer { prefetching = false }
        let folder = Self.cacheDirectory.appendingPathComponent("manifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wanted = registry.filter { remoteManifests[$0.name] == nil && installedPack($0.name) == nil }
        for start in stride(from: 0, to: wanted.count, by: 8) {
            let chunk = Array(wanted[start..<min(start + 8, wanted.count)])
            let read = await withTaskGroup(of: (String, CESPManifest?).self) { group in
                for entry in chunk {
                    let cached = folder.appendingPathComponent("\(entry.name)@\(entry.version).json")
                    group.addTask {
                        if let data = try? Data(contentsOf: cached), let manifest = try? SoundPackInstaller.checkedManifest(data) {
                            return (entry.name, manifest)
                        }
                        guard let data = try? await Self.download(entry.manifestURL, limit: 1_000_000),
                              let manifest = try? SoundPackInstaller.checkedManifest(data) else { return (entry.name, nil) }
                        try? data.write(to: cached)
                        return (entry.name, manifest)
                    }
                }
                var out: [(String, CESPManifest?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for case let (name, manifest?) in read { remoteManifests[name] = manifest }
            if start % 80 == 0 { rebuildCatalog() }
        }
        rebuildCatalog()
        Self.log.info("sound pack manifests: \(self.remoteManifests.count, privacy: .public) of \(self.registry.count, privacy: .public)")
    }

    /// Browse's list, filtered and sorted.
    var visible: [SoundCatalog.Pack] { catalog.visible(filter) }

    var visibleInstalled: [InstalledSoundPack] {
        let q = filter.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return installed }
        return installed.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
    }

    /// The manifest to list a pack's lines from: the installed copy, or the registry host's.
    func manifest(for name: String) -> CESPManifest? {
        installedPack(name)?.manifest ?? remoteManifests[name]
    }

    func loadManifest(for entry: SoundRegistry.Entry) {
        guard installedPack(entry.name) == nil, remoteManifests[entry.name] == nil,
              manifestTasks.insert(entry.name).inserted else { return }
        Task {
            defer { manifestTasks.remove(entry.name) }
            guard let data = try? await Self.download(entry.manifestURL, limit: 1_000_000),
                  let manifest = try? SoundPackInstaller.checkedManifest(data) else { return }
            remoteManifests[entry.name] = manifest
        }
    }

    // MARK: Installing

    func install(_ entry: SoundRegistry.Entry) {
        guard installing.insert(entry.name).inserted else { return }
        let verb = installedPack(entry.name) == nil ? "Installed" : "Updated"
        Task {
            defer { installing.remove(entry.name) }
            do {
                let result = try await SoundPackInstaller.install(entry, into: Self.packsDirectory) { path in
                    try await Self.download(entry.rawURL(path), limit: SoundPackInstaller.maxFileBytes + 1)
                }
                rescan()
                // The first pack is the one the user meant to hear.
                if settings.defaultPack == nil || installedPack(settings.defaultPack!) == nil { settings.defaultPack = entry.name }
                let skipped = result.skippedLines == 0 ? "" : " (\(result.skippedLines) line\(result.skippedLines == 1 ? "" : "s") left out for failing a check)"
                message = .done("\(verb) \(entry.displayName)\(skipped).")
                Self.log.notice("sound pack \(entry.name, privacy: .public) \(verb.lowercased(), privacy: .public) \(entry.version, privacy: .public)")
            } catch {
                message = .failed("\(entry.displayName): \(error)")
                Self.log.error("sound pack \(entry.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    func uninstall(_ pack: InstalledSoundPack) {
        do {
            try SoundPackInstaller.uninstall(pack)
            rescan()
            if settings.defaultPack == pack.id { settings.defaultPack = installed.first?.id }
            message = .done("Removed \(pack.manifest.displayName).")
        } catch {
            message = .failed("\(pack.manifest.displayName) could not be removed: \(error.localizedDescription)")
        }
    }

    /// One file from the registry's host, refused when it is not a 200 or larger than `limit`.
    nonisolated static func download(_ url: URL, limit: Int) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    // MARK: Which pack (ADR-201)

    /// Set by the app: the sessions and projects packs are assigned to, kept in `state.json`.
    @ObservationIgnored weak var sessions: SessionStore?
    /// Set by the app: sessions with a live tab, whose packs a rotation draw spreads across.
    @ObservationIgnored var liveSessions: () -> [SessionID] = { [] }

    private func projectPath(of session: SessionID) -> String? {
        sessions?.sessions[session].flatMap(ProjectGrouping.project(for:))?.path
    }

    /// The pack a session speaks with and why: its own, its family's, its project's, its draw from the
    /// rotation, or the default. A session that has to draw does so here, once, and keeps it; a view
    /// asking only to show the answer passes `draw: false` and gets nil instead.
    func choice(for session: SessionID?, draw: Bool = true) -> SoundPackAssignments.Choice? {
        let assignments = sessions?.state.soundPacks ?? SoundPackAssignments()
        let installedNames = Set(installed.map(\.id))
        func resolve(_ a: SoundPackAssignments) -> SoundPackAssignments.Resolution {
            a.resolve(session, project: session.flatMap(projectPath(of:)), parent: { [sessions] in sessions?.parent(of: $0)?.id },
                      projectOf: { self.projectPath(of: $0) }, rotation: settings.rotation, defaultPack: settings.defaultPack,
                      installed: installedNames)
        }
        switch resolve(assignments) {
        case .choice(let choice): return choice
        case .none: return nil
        case .draw(let who):
            guard draw else { return nil }
            let inUse = liveSessions().filter { $0 != who }.compactMap { assignments.drawn[$0] }
            guard let pick = SoundPackAssignments.draw(rotation: settings.rotation, installed: installedNames, inUse: inUse) else { return nil }
            let live = Set(sessions?.sessions.keys.map { $0 } ?? [])
            sessions?.update { state in
                state.soundPacks.drawn[who] = pick
                state.soundPacks.pruneDraws(keeping: live)
            }
            Self.log.info("session \(who.rawValue, privacy: .public) drew \(pick, privacy: .public) from the rotation")
            var drawn = assignments
            drawn.drawn[who] = pick
            if case .choice(let choice) = resolve(drawn) { return choice }
            return nil
        }
    }

    func pack(for session: SessionID?) -> InstalledSoundPack? {
        choice(for: session).flatMap { installedPack($0.pack) }
    }

    func setPack(_ name: String?, forProject path: String) {
        sessions?.update { $0.soundPacks.byProject[path] = name }
    }

    func setPack(_ name: String?, forSession id: SessionID) {
        sessions?.update { $0.soundPacks.bySession[id] = name }
    }

    func isInRotation(_ name: String) -> Bool { settings.rotation.contains(name) }

    func toggleRotation(_ name: String) {
        if let i = settings.rotation.firstIndex(of: name) { settings.rotation.remove(at: i) } else { settings.rotation.append(name) }
    }

    /// The projects that speak with a pack of their own choosing.
    func projects(using name: String) -> [String] {
        (sessions?.state.soundPacks.byProject ?? [:]).filter { $0.value == name }.map(\.key).sorted()
    }

    /// Words for where a session's pack comes from, for menus: "Orc Peon, from clinic".
    func describe(_ choice: SoundPackAssignments.Choice) -> String {
        let name = installedPack(choice.pack)?.manifest.displayName ?? choice.pack
        switch choice.source {
        case .session: return name
        case .parent(let id):
            let parent = sessions?.sessions[id].map { sessions?.displayName(for: $0) ?? "" } ?? "its parent"
            return "\(name), from \(parent)"
        case .project(let path): return "\(name), from \((path as NSString).lastPathComponent)"
        case .rotation: return "\(name), from the rotation"
        case .defaultPack: return "\(name), the default"
        }
    }

    // MARK: Voicing (ADR-199)

    /// What a moment sounded like: whether a pack voice covers it, and the line, for the card's caption.
    struct Spoken {
        var covered: Bool
        var caption: String?
        static let none = Spoken(covered: false, caption: nil)
    }

    /// Plays the line a witness calls for, if the pack has one and the user has not switched it off.
    /// `covered` means a pack voice has the moment, so whatever would have sounded before stays quiet.
    func voice(_ witness: SoundWitness, session: SessionID?, onScreen: Bool) -> Spoken {
        let pack = pack(for: session)
        let decision = router.decide(witness, session: session?.rawValue, manifest: pack?.manifest, settings: settings,
                                     onScreen: onScreen, playing: player.playingCategory)
        switch decision {
        case .pass: return .none
        case .hold: return Spoken(covered: true, caption: nil)
        case .play(let cue):
            guard let pack else { return .none }
            let url = pack.url(of: cue.line)
            // A line that will not play is a line that does not exist: the old sound takes the moment.
            guard player.play(url, volume: settings.volume, category: cue.category) else { return .none }
            Self.log.debug("\(witness.rawValue, privacy: .public) → \(cue.category.rawValue, privacy: .public) [\(pack.id, privacy: .public) for \(session?.rawValue ?? "-", privacy: .public)]: \(cue.line.label, privacy: .public)")
            let label = cue.line.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return Spoken(covered: true, caption: label.isEmpty ? nil : "\(pack.manifest.displayName): “\(label)”")
        }
    }

    func forget(session: SessionID) { router.forget(session: session.rawValue) }

    // MARK: Previews

    /// Plays, or stops, one line of a pack: from disk when installed, otherwise fetched once into the
    /// cache and checked like an installed file would be.
    func togglePreview(_ path: String, of name: String) {
        let key = name + "/" + path
        if previewing == key { player.stop(); return }
        if let pack = installedPack(name) {
            togglePreview(pack.directory.appendingPathComponent(path), key: key)
            return
        }
        guard let entry = entry(name), CESPManifest.isSafeRelativePath(path) else { return }
        let cached = Self.cacheDirectory.appendingPathComponent("previews/\(entry.name)/\(entry.version)/\(path)")
        if FileManager.default.fileExists(atPath: cached.path) { togglePreview(cached, key: key); return }
        Task {
            do {
                let data = try await Self.download(entry.rawURL(path), limit: SoundPackInstaller.maxFileBytes)
                guard AudioMagic.matches(data, path: path) else { throw URLError(.cannotDecodeContentData) }
                try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cached)
                togglePreview(cached, key: key)
            } catch {
                message = .failed("\((path as NSString).lastPathComponent) could not be played: \(error.localizedDescription)")
            }
        }
    }

    private func togglePreview(_ url: URL, key: String) {
        if player.play(url, volume: settings.volume, category: nil) {
            previewing = key
            previewURL = url
        } else {
            message = .failed("\(url.lastPathComponent) could not be played.")
        }
    }

    func isPreviewing(_ path: String, of name: String) -> Bool { previewing == name + "/" + path }

    /// A line of the default pack at the volume just chosen, so the slider can be judged by ear.
    func sampleVolume() {
        guard let pack = pack(for: nil) else { return }
        let lines = pack.manifest.lines(for: .taskComplete) + pack.manifest.lines(for: .sessionStart)
        guard let line = lines.randomElement() else { return }
        togglePreview(pack.url(of: line), key: pack.id + "/" + line.path)
    }
}

/// One `AVAudioPlayer` at a time: a new line stops the last (ADR-199).
@MainActor
private final class LinePlayer: NSObject, AVAudioPlayerDelegate {
    private var current: AVAudioPlayer?
    private var currentCategory: CESPCategory?
    private var currentURL: URL?
    var onFinish: ((URL) -> Void)?

    /// The category of the line still playing, so the router can rank what arrives against it.
    var playingCategory: CESPCategory? { current?.isPlaying == true ? currentCategory : nil }

    func play(_ url: URL, volume: Double, category: CESPCategory?) -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.volume = Float(volume)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else { return false }
        current = player
        currentCategory = category
        currentURL = url
        return true
    }

    func stop() {
        current?.stop()
        if let url = currentURL { onFinish?(url) }
        current = nil; currentCategory = nil; currentURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.current, ObjectIdentifier(current) == id else { return }
            self.stop()
        }
    }
}
