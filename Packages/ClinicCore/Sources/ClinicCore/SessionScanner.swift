import Foundation

/// Enumerates transcripts under the Claude projects directory and parses them with a (path, mtime, size) cache (ADR-029).
public actor SessionScanner {
    public struct CacheEntry: Codable, Sendable { public var size: Int64; public var mtime: Date; public var summary: SessionSummary }

    private let paths: ClaudePaths
    private let reader: TranscriptReader
    private var cache: [String: CacheEntry] = [:]

    public init(paths: ClaudePaths = ClaudePaths(), reader: TranscriptReader = TranscriptReader()) {
        self.paths = paths; self.reader = reader
    }

    public func loadCache(_ entries: [String: CacheEntry]) { cache = entries }
    public func cacheSnapshot() -> [String: CacheEntry] { cache }

    /// Full scan. Returns summaries for every transcript found.
    public func scanAll() -> [SessionSummary] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: paths.projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [SessionSummary] = []
        var seen = Set<String>()
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let summary = scan(file: file) { result.append(summary); seen.insert(file.path) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return result
    }

    /// Rescan a single transcript (used by the file watcher).
    public func scan(file: URL) -> SessionSummary? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let mtime = values.contentModificationDate else { return nil }
        if let cached = cache[file.path], cached.size == Int64(size), cached.mtime == mtime { return cached.summary }
        guard let summary = try? reader.read(fileAt: file.path) else { return nil }
        cache[file.path] = CacheEntry(size: Int64(size), mtime: mtime, summary: summary)
        return summary
    }
}
