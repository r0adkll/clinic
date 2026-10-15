import CryptoKit
import Foundation

/// A pack on disk that Clinic can play (ADR-199).
public struct InstalledSoundPack: Sendable, Hashable, Identifiable {
    /// Where it was found. Only `.clinic` packs are Clinic's to update or remove.
    public enum Origin: String, Sendable, Hashable, CaseIterable {
        case clinic
        /// `~/.openpeon/packs`, the folder CESP players share.
        case openPeon
        /// peon-ping's own folder under `~/.claude`, which is read-only to Clinic (ADR-018).
        case peonPing

        public var label: String {
            switch self {
            case .clinic: "Clinic"
            case .openPeon: "~/.openpeon"
            case .peonPing: "peon-ping"
            }
        }
    }

    /// The folder's name, which is the pack's identity: a registry entry with the same name is this pack.
    public var id: String
    public var directory: URL
    public var manifest: CESPManifest
    public var origin: Origin

    public var isReadOnly: Bool { origin != .clinic }

    public init(id: String, directory: URL, manifest: CESPManifest, origin: Origin) {
        self.id = id; self.directory = directory; self.manifest = manifest; self.origin = origin
    }

    public func url(of line: CESPManifest.Line) -> URL {
        directory.appendingPathComponent(line.path)
    }
}

public enum SoundPackInstaller {
    public static let maxFileBytes = 1_000_000
    public static let maxPackBytes = 50_000_000

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noManifest(String)
        case manifestChecksum
        case manifest(String)
        case lineChecksum(String)
        case tooLarge
        case nothingPlayable

        public var description: String {
            switch self {
            case .noManifest(let detail): "openpeon.json could not be downloaded: \(detail)"
            case .manifestChecksum: "openpeon.json does not match the checksum the registry published."
            case .manifest(let detail): "openpeon.json is not a CESP 1.0 manifest: \(detail)"
            case .lineChecksum(let file): "\(file) does not match the checksum in openpeon.json."
            case .tooLarge: "The pack is larger than CESP's 50 MB limit."
            case .nothingPlayable: "None of the pack's sounds passed the checks."
            }
        }
    }

    /// Reads one file of a pack by its path inside the pack.
    public typealias Fetch = @Sendable (String) async throws -> Data

    // MARK: Finding packs

    /// Every pack folder directly inside `directory` whose manifest reads. Packs found here are trusted
    /// as far as reading their manifest; a line that will not play is skipped when it is chosen.
    public static func scan(_ directory: URL, origin: InstalledSoundPack.Origin) -> [InstalledSoundPack] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("openpeon.json")),
                  let manifest = try? JSONDecoder().decode(CESPManifest.self, from: data) else { return nil }
            return InstalledSoundPack(id: name, directory: folder, manifest: manifest, origin: origin)
        }
    }

    // MARK: Installing

    /// The outcome of an install: the pack, and how many of its lines were left out for failing a check.
    public struct Installed: Sendable {
        public var pack: InstalledSoundPack
        public var skippedLines: Int
    }

    /// Downloads one registry entry into `packsDirectory/<name>`, replacing any earlier version only
    /// once the new one has passed every check.
    ///
    /// File by file rather than from the tag's tarball: the official packs share one repository, whose
    /// tarball is 62 MB for a pack of under 1 MB. And only the manifest and the audio it names are ever
    /// requested, so nothing else a repository carries (scripts, links, other packs) can reach the disk.
    ///
    /// A line whose file will not download, is misnamed, oversized or not the audio its extension claims
    /// is left out and counted; a pack with no line left is refused. A line whose `sha256` disagrees
    /// refuses the whole pack, because that is not a mistake but a file other than the one published.
    public static func install(_ entry: SoundRegistry.Entry, into packsDirectory: URL, fetch: @escaping Fetch) async throws -> Installed {
        let manifestData: Data
        do { manifestData = try await fetch("openpeon.json") } catch { throw Failure.noManifest(error.localizedDescription) }
        if let expected = entry.manifestSHA256, sha256(manifestData) != expected.lowercased() { throw Failure.manifestChecksum }
        let manifest = try checkedManifest(manifestData)

        let paths = manifest.allLines.map(\.path)
        // Every checksum any line gives for a file, not just the first line's: one file can be named by
        // several categories, and only some of them may carry a `sha256`.
        var expected: [String: Set<String>] = [:]
        for line in manifest.categories.values.flatMap(\.sounds) {
            if let sha = line.sha256, !sha.isEmpty { expected[line.path, default: []].insert(sha.lowercased()) }
        }
        // A few at a time: a pack is a few dozen small files, and the host is shared with everyone.
        var files: [String: Data] = [:]
        var skipped = 0
        for chunk in stride(from: 0, to: paths.count, by: 6).map({ Array(paths[$0..<min($0 + 6, paths.count)]) }) {
            let fetched = await withTaskGroup(of: (String, Data?).self) { group in
                for path in chunk where CESPManifest.isSafeRelativePath(path) {
                    group.addTask { (path, try? await fetch(path)) }
                }
                var out: [(String, Data?)] = []
                for await result in group { out.append(result) }
                return out
            }
            skipped += chunk.count - fetched.count
            for (path, data) in fetched {
                guard let data, data.count <= maxFileBytes, AudioMagic.matches(data, path: path) else { skipped += 1; continue }
                if let shas = expected[path], shas != [sha256(data)] { throw Failure.lineChecksum(path) }
                files[path] = data
            }
        }
        guard files.values.reduce(manifestData.count, { $0 + $1.count }) <= maxPackBytes else { throw Failure.tooLarge }
        guard !files.isEmpty else { throw Failure.nothingPlayable }

        let fm = FileManager.default
        try fm.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        let staging = packsDirectory.appendingPathComponent(".staging-\(entry.name)-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try manifestData.write(to: staging.appendingPathComponent("openpeon.json"))
            for (path, data) in files {
                let target = staging.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
            }
            let destination = packsDirectory.appendingPathComponent(entry.name, isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            return Installed(pack: InstalledSoundPack(id: entry.name, directory: destination, manifest: manifest, origin: .clinic),
                             skippedLines: skipped)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// A manifest Clinic will install: it decodes, says CESP 1.x, and has a name the spec allows.
    public static func checkedManifest(_ data: Data) throws -> CESPManifest {
        let manifest: CESPManifest
        do { manifest = try JSONDecoder().decode(CESPManifest.self, from: data) } catch {
            throw Failure.manifest("it does not decode")
        }
        guard manifest.cespVersion == "1.0" || manifest.cespVersion.hasPrefix("1.") else {
            throw Failure.manifest("cesp_version is \(manifest.cespVersion)")
        }
        guard CESPManifest.isValidName(manifest.name) else { throw Failure.manifest("name \"\(manifest.name)\" is not allowed") }
        return manifest
    }

    /// Removes a pack Clinic installed. Packs found elsewhere are not Clinic's to delete.
    public static func uninstall(_ pack: InstalledSoundPack) throws {
        guard pack.origin == .clinic else { return }
        try FileManager.default.removeItem(at: pack.directory)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// CESP's magic-byte rule: an audio file must start the way its format does.
public enum AudioMagic {
    public static func matches(_ data: Data, path: String) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count >= 4 else { return false }
        switch (path as NSString).pathExtension.lowercased() {
        case "wav": return bytes == Array("RIFF".utf8)
        case "ogg": return bytes == Array("OggS".utf8)
        // An ID3 tag, or an MPEG frame sync. The spec names only `FF FB`, but `FF F3` and `FF F2`
        // (MPEG-2 and 2.5) are the same format at lower sample rates and appear in real packs.
        case "mp3": return Array(bytes.prefix(3)) == Array("ID3".utf8) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
        default: return false
        }
    }
}
