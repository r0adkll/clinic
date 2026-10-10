import Foundation

/// A file a terminal link names, and the place in it, when the link says (ADR-192).
///
/// libghostty hands Clinic every ⌘-clicked link as a URL. Claude Code writes its paths as OSC 8
/// hyperlinks to `file:///absolute/path`; a path Ghostty found in the text itself arrives as whatever
/// was printed — relative to the shell's directory, often with `:line` or `:line:column` after it.
public struct FileLink: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    /// The file `url` names, resolved against `cwd` when it is relative, or nil when it names no
    /// regular file — a web address, a folder, a path that is not there. `isFile` is the file
    /// system's answer, passed in so the rules can be tested without one.
    public static func resolve(_ url: URL, cwd: String?, isFile: (String) -> Bool) -> FileLink? {
        guard let raw = rawPath(of: url) else { return nil }
        var path = raw
        if !path.hasPrefix("/") {
            guard let cwd else { return nil }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath
        let anchor = url.isFileURL ? fragmentLine(url.fragment) : nil

        if isFile(path) { return FileLink(path: path, line: anchor) }
        // `Sources/App.swift:42` or `:42:7`: what compilers, grep and the CLI print.
        let (base, line, column) = splitPosition(path)
        if let line, isFile(base) { return FileLink(path: base, line: line, column: column) }
        return nil
    }

    /// The path a URL stands for, before resolving: a `file:` URL's path; a relative one's as
    /// written; and, because `README.md:12` parses as a URL whose *scheme* is `README.md`, the whole
    /// of anything whose scheme has a dot in it. Every other scheme is somewhere else.
    private static func rawPath(of url: URL) -> String? {
        if url.isFileURL {
            // `URL(filePath:)` on a relative path keeps it relative to the process's directory, which
            // for an app is `/`; the shell's directory is the one the text was printed in.
            if url.baseURL != nil { return url.relativePath }
            // Decoded: the CLI percent-encodes spaces and anything else a URL cannot carry.
            return url.path(percentEncoded: false)
        }
        if let scheme = url.scheme, scheme.contains(".") { return url.absoluteString.removingPercentEncoding }
        return nil
    }

    /// `#L42`, `#42` or `#L42C7` on a `file:` URL, the forms editors and Kitty use.
    private static func fragmentLine(_ fragment: String?) -> Int? {
        guard var f = fragment, !f.isEmpty else { return nil }
        if f.first == "L" { f.removeFirst() }
        let digits = f.prefix { $0.isNumber }
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func splitPosition(_ path: String) -> (String, Int?, Int?) {
        let parts = path.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (path, nil, nil) }
        if parts.count >= 3, let line = Int(parts[parts.count - 2]), let column = Int(parts[parts.count - 1]), line > 0 {
            return (parts.dropLast(2).joined(separator: ":"), line, column > 0 ? column : nil)
        }
        if let line = Int(parts[parts.count - 1]), line > 0 {
            return (parts.dropLast().joined(separator: ":"), line, nil)
        }
        return (path, nil, nil)
    }
}
