import Foundation

/// Files under a root for the editor's tree and quick open (ADR-057). Honours .gitignore via `git ls-files` inside work trees.
public actor FileIndex {
    public let root: String
    private var cached: [String]?
    public static let skippedDirectories: Set<String> = [".git", "node_modules", "build", ".build", "DerivedData", "Pods", "target", "dist", ".gradle", ".idea", ".swiftpm"]
    public static let maxEntries = 50_000

    public struct Entry: Sendable, Hashable, Identifiable {
        public var relativePath: String
        public var name: String
        public var isDirectory: Bool
        public var id: String { relativePath }
        public init(relativePath: String, name: String, isDirectory: Bool) { self.relativePath = relativePath; self.name = name; self.isDirectory = isDirectory }
    }

    public init(root: String) { self.root = root }

    public func invalidate() { cached = nil }

    public func files() async -> [String] {
        if let cached { return cached }
        let list = await gitFiles() ?? walk()
        cached = list
        return list
    }

    public func children(of relativeDirectory: String, showHidden: Bool) async -> [Entry] {
        let all = await files()
        let prefix = relativeDirectory.isEmpty ? "" : relativeDirectory + "/"
        var dirs = Set<String>(); var files: [String] = []
        for f in all where f.hasPrefix(prefix) {
            let rest = f.dropFirst(prefix.count)
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") { dirs.insert(String(rest[..<slash])) } else { files.append(String(rest)) }
        }
        func visible(_ name: String) -> Bool { showHidden || !name.hasPrefix(".") }
        let d = dirs.filter(visible).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { Entry(relativePath: prefix + $0, name: $0, isDirectory: true) }
        let f = files.filter(visible).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { Entry(relativePath: prefix + $0, name: $0, isDirectory: false) }
        return d + f
    }

    private func gitFiles() async -> [String]? {
        let output = await Self.run(["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        guard let output, !output.isEmpty else { return nil }
        var seen = Set<String>(); var result: [String] = []
        for chunk in output.split(separator: 0, omittingEmptySubsequences: true) {
            let s = String(decoding: chunk, as: UTF8.self)
            if seen.insert(s).inserted { result.append(s) }
            if result.count >= Self.maxEntries { break }
        }
        return result
    }

    private func walk() -> [String] {
        var out: [String] = []
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey], options: []) else { return [] }
        let rootLen = rootURL.path.count + 1
        while let url = e.nextObject() as? URL {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if Self.skippedDirectories.contains(name) || (name.hasPrefix(".") && name != ".") { e.skipDescendants() }
                continue
            }
            out.append(String(url.resolvingSymlinksInPath().path.dropFirst(rootLen)))
            if out.count >= Self.maxEntries { break }
        }
        return out
    }

    private static func run(_ argv: [String]) async -> Data? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = argv
                p.environment = ProcessEnvironment.withToolPaths()
                let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
