import Foundation

/// The OpenPeon registry's index (ADR-199): what can be installed, and where each pack's files live.
public struct SoundRegistry: Sendable, Hashable {
    public static let indexURL = URL(string: "https://peonping.github.io/registry/index.json")!

    public var packs: [Entry]

    public init(packs: [Entry]) { self.packs = packs }

    /// Decodes the index, dropping entries that cannot be installed rather than failing the whole list.
    /// Flagged entries are dropped too: the registry's own reviewers marked them, and Clinic has no
    /// reason to second-guess that in the user's favour.
    public init(json: Data) throws {
        struct Index: Decodable { let packs: [Lossy<Entry>] }
        let index = try JSONDecoder().decode(Index.self, from: json)
        packs = index.packs.compactMap(\.value).filter { $0.quality != "flagged" }
    }

    /// One installable pack.
    public struct Entry: Decodable, Sendable, Hashable, Identifiable {
        public var name: String
        public var displayName: String
        public var version: String
        public var description: String
        public var authorName: String?
        public var authorGitHub: String?
        public var trustTier: String?
        public var quality: String?
        public var categories: [String]
        public var language: String?
        public var license: String?
        public var soundCount: Int?
        public var totalSizeBytes: Int?
        public var sourceRepo: String
        public var sourceRef: String
        public var sourcePath: String
        public var manifestSHA256: String?
        public var tags: [String]
        /// The lines the registry suggests trying first, as paths inside the pack.
        public var previews: [Preview]
        public var added: String?
        public var updated: String?
        /// The registry's own franchise, once it serves one (openpeon.com's source has a TODO for it).
        /// Until then `SoundFranchises` names it (ADR-200).
        public var franchise: String?

        public var id: String { name }

        public struct Preview: Sendable, Hashable {
            public var path: String
            public var label: String?
        }

        enum CodingKeys: String, CodingKey {
            case name, displayName = "display_name", version, description, author, trustTier = "trust_tier", quality
            case categories, language, license, soundCount = "sound_count", totalSizeBytes = "total_size_bytes"
            case sourceRepo = "source_repo", sourceRef = "source_ref", sourcePath = "source_path"
            case manifestSHA256 = "manifest_sha256", tags, previews = "preview_sounds", added, updated, franchise
        }

        public init(name: String, displayName: String, version: String = "1.0.0", description: String = "",
                    sourceRepo: String, sourceRef: String, sourcePath: String = ".", manifestSHA256: String? = nil,
                    categories: [String] = [], tags: [String] = [], previews: [Preview] = []) {
            self.name = name; self.displayName = displayName; self.version = version; self.description = description
            self.sourceRepo = sourceRepo; self.sourceRef = sourceRef; self.sourcePath = sourcePath
            self.manifestSHA256 = manifestSHA256; self.categories = categories; self.tags = tags; self.previews = previews
        }

        public init(from decoder: Decoder) throws {
            struct Author: Decodable { let name: String?; let github: String? }
            /// `preview_sounds` is a list of bare file names in most entries and of `{file, label}` in some.
            struct RawPreview: Decodable {
                let file: String; let label: String?
                init(from decoder: Decoder) throws {
                    if let s = try? decoder.singleValueContainer().decode(String.self) { file = s; label = nil; return }
                    struct Object: Decodable { let file: String; let label: String? }
                    let o = try Object(from: decoder)
                    file = o.file; label = o.label
                }
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            guard CESPManifest.isValidName(name) else {
                throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "not a CESP pack name")
            }
            displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? name
            version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? "0.0.0"
            description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
            let author = try? c.decodeIfPresent(Author.self, forKey: .author)
            authorName = author?.name; authorGitHub = author?.github
            trustTier = try? c.decodeIfPresent(String.self, forKey: .trustTier)
            quality = try? c.decodeIfPresent(String.self, forKey: .quality)
            categories = (try? c.decodeIfPresent([String].self, forKey: .categories)) ?? []
            language = try? c.decodeIfPresent(String.self, forKey: .language)
            license = try? c.decodeIfPresent(String.self, forKey: .license)
            soundCount = try? c.decodeIfPresent(Int.self, forKey: .soundCount)
            totalSizeBytes = try? c.decodeIfPresent(Int.self, forKey: .totalSizeBytes)
            sourceRepo = try c.decode(String.self, forKey: .sourceRepo)
            sourceRef = try c.decode(String.self, forKey: .sourceRef)
            // Some entries leave the path empty for a pack at the repository's root.
            let path = ((try? c.decodeIfPresent(String.self, forKey: .sourcePath)) ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            sourcePath = path.isEmpty ? "." : path
            manifestSHA256 = try? c.decodeIfPresent(String.self, forKey: .manifestSHA256)
            tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
            added = try? c.decodeIfPresent(String.self, forKey: .added)
            updated = try? c.decodeIfPresent(String.self, forKey: .updated)
            struct Named: Decodable { let name: String }
            franchise = (try? c.decodeIfPresent(String.self, forKey: .franchise))
                ?? (try? c.decodeIfPresent(Named.self, forKey: .franchise))?.name
            let raw = ((try? c.decodeIfPresent([Lossy<RawPreview>].self, forKey: .previews)) ?? []).compactMap(\.value)
            previews = raw.compactMap { p in
                let path = p.file.contains("/") ? p.file : "sounds/" + p.file
                return CESPManifest.isSafeRelativePath(path) ? Preview(path: path, label: p.label) : nil
            }
            // Everything a URL is built from must stay inside its own path segment.
            let repoParts = sourceRepo.split(separator: "/")
            guard repoParts.count == 2, repoParts.allSatisfy({ CESPManifest.isSafeRelativePath(String($0)) }),
                  CESPManifest.isSafeRelativePath(sourceRef),
                  sourcePath == "." || CESPManifest.isSafeRelativePath(sourcePath) else {
                throw DecodingError.dataCorruptedError(forKey: .sourceRepo, in: c, debugDescription: "unsafe source")
            }
        }

        /// The tag's source tarball. Packs that share a repository and tag share one download.
        public var tarballURL: URL {
            URL(string: "https://github.com/\(sourceRepo)/archive/refs/tags/\(sourceRef).tar.gz")!
        }

        /// A file inside the pack, served raw, so a line can be heard before anything is installed.
        public func rawURL(_ path: String) -> URL {
            let folder = sourcePath == "." ? "" : sourcePath + "/"
            return URL(string: "https://raw.githubusercontent.com/\(sourceRepo)/\(sourceRef)/\(folder)\(path)")!
        }

        public var manifestURL: URL { rawURL("openpeon.json") }

        /// Base language codes, lower case: `zh-CN` is `zh`, and `en,ru` is both. Empty when unknown.
        public var languages: [String] {
            var seen = Set<String>()
            return (language ?? "").split(separator: ",").compactMap { part in
                let code = part.trimmingCharacters(in: .whitespaces).split(separator: "-").first.map { $0.lowercased() } ?? ""
                return code.isEmpty || !seen.insert(code).inserted ? nil : code
            }
        }
    }
}

/// Semantic versions compared the way an update check needs: numerically, part by part, ignoring any
/// pre-release or build suffix. A version that does not parse never reads as newer.
public enum PackVersion {
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
            let numbers = core.split(separator: ".").map { Int($0) }
            return numbers.contains(nil) || numbers.isEmpty ? nil : numbers.compactMap { $0 }
        }
        guard let a = parts(candidate), let b = parts(installed) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
