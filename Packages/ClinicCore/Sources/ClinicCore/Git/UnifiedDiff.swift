import Foundation

/// A parsed `git diff` (possibly spanning many files). The parser is tolerant: unknown header
/// lines are kept verbatim, hunk bodies are bounded by the `@@` counts so a body line that happens
/// to start with `---`/`+++`/`diff` is not mistaken for a header.
public struct UnifiedDiff: Sendable, Equatable {
    public var files: [UnifiedDiffFile]

    public init(files: [UnifiedDiffFile] = []) { self.files = files }

    public static func parse(_ text: String) -> UnifiedDiff {
        var parser = Parser()
        var pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
        if pieces.last?.isEmpty == true { pieces.removeLast() }   // trailing newline, not an empty line
        for raw in pieces {
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            parser.feed(line)
        }
        return UnifiedDiff(files: parser.finish())
    }
}

public struct UnifiedDiffFile: Sendable, Equatable, Identifiable {
    public var oldPath: String?
    public var newPath: String?
    public var isBinary: Bool
    public var isNew: Bool
    public var isDeleted: Bool
    /// Everything before the first `@@` (`diff --git`, `index`, `---`, `+++`, mode/rename lines), verbatim.
    public var headerLines: [String]
    public var hunks: [DiffHunk]

    public init(oldPath: String? = nil, newPath: String? = nil, isBinary: Bool = false, isNew: Bool = false, isDeleted: Bool = false, headerLines: [String] = [], hunks: [DiffHunk] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.isBinary = isBinary
        self.isNew = isNew
        self.isDeleted = isDeleted
        self.headerLines = headerLines
        self.hunks = hunks
    }

    public var path: String { newPath ?? oldPath ?? "" }
    public var id: String { path }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
}

public struct DiffHunk: Sendable, Equatable, Identifiable {
    /// `"\(oldStart)-\(newStart)-\(index)"`, stable within a file.
    public var id: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var heading: String?
    public var lines: [DiffLine]
    /// The original `@@ … @@` line.
    public var headerText: String

    public init(id: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String? = nil, lines: [DiffLine] = [], headerText: String) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.heading = heading
        self.lines = lines
        self.headerText = headerText
    }
}

public struct DiffLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable { case context, addition, deletion, noNewline }
    /// Index within the hunk.
    public var id: Int
    public var kind: Kind
    /// Line content without the leading `+`/`-`/space (for `.noNewline`, the marker text itself).
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public init(id: Int, kind: Kind, text: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }

    /// The line as it appears in a patch (with its prefix character).
    var patchText: String {
        switch kind {
        case .context: return " " + text
        case .addition: return "+" + text
        case .deletion: return "-" + text
        case .noNewline: return "\\ " + text
        }
    }
}

// MARK: - Patch generation

extension UnifiedDiffFile {
    /// A patch containing only this hunk (with the file header lines), suitable for `git apply --cached` / `--reverse`.
    public func patchText(for hunk: DiffHunk) -> String {
        var out = headerLines
        out.append(hunk.headerText)
        out.append(contentsOf: hunk.lines.map(\.patchText))
        return out.joined(separator: "\n") + "\n"
    }

    /// A patch containing only the selected line ids of the hunk, for line-level staging.
    /// Unselected additions are dropped, unselected deletions become context lines, `\ No newline`
    /// markers follow the line they annotate, and the hunk header counts are recomputed.
    public func patchText(for hunk: DiffHunk, selectedLineIds: Set<Int>) -> String {
        var body: [String] = []
        var oldCount = 0
        var newCount = 0
        var keptPrevious = true
        for line in hunk.lines {
            switch line.kind {
            case .context:
                body.append(line.patchText); oldCount += 1; newCount += 1; keptPrevious = true
            case .addition:
                if selectedLineIds.contains(line.id) {
                    body.append(line.patchText); newCount += 1; keptPrevious = true
                } else {
                    keptPrevious = false
                }
            case .deletion:
                if selectedLineIds.contains(line.id) {
                    body.append(line.patchText); oldCount += 1
                } else {
                    body.append(" " + line.text); oldCount += 1; newCount += 1
                }
                keptPrevious = true
            case .noNewline:
                if keptPrevious { body.append(line.patchText) }
            }
        }
        // A zero-count side is conventionally reported one line before the hunk (git's own convention).
        let oldStart = oldCount == 0 && hunk.oldCount != 0 ? max(hunk.oldStart - 1, 0) : hunk.oldStart
        let newStart = newCount == 0 && hunk.newCount != 0 ? max(hunk.newStart - 1, 0) : hunk.newStart
        var header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        if let heading = hunk.heading { header += " " + heading }
        var out = headerLines
        out.append(header)
        out.append(contentsOf: body)
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - Parser

private struct Parser {
    private var files: [UnifiedDiffFile] = []
    private var current: UnifiedDiffFile?
    private var hunk: DiffHunk?
    private var oldRemaining = 0
    private var newRemaining = 0
    private var oldLine = 0
    private var newLine = 0
    private var sawOldHeader = false   // `---` seen for the current file
    private var sawNewHeader = false   // `+++` seen for the current file

    mutating func feed(_ line: String) {
        if hunk != nil && (oldRemaining > 0 || newRemaining > 0) {
            if consumeHunkLine(line) { return }
        }
        if hunk != nil, line.hasPrefix("\\") {
            // `\ No newline at end of file` after the last counted line of a hunk.
            appendLine(kind: .noNewline, text: String(line.dropFirst().drop(while: { $0 == " " })), old: nil, new: nil)
            return
        }
        if line.hasPrefix("diff --git ") || line.hasPrefix("diff -r ") || line.hasPrefix("diff -u ") {
            startFile(headerLine: line)
            return
        }
        if line.hasPrefix("@@") {
            if current == nil { startFile(headerLine: nil) }
            startHunk(line)
            return
        }
        if current == nil {
            // Stray text before the first file (e.g. `git diff --stat` noise); only `---`/`+++` start an implicit file.
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") { startFile(headerLine: nil) } else { return }
        }
        // Header line for the current file (before the first hunk). Lines after the last hunk that are not
        // recognised are dropped, so trailing garbage cannot corrupt the file header used for patches.
        guard hunk == nil, !line.isEmpty else { return }
        current?.headerLines.append(line)
        if line.hasPrefix("--- ") {
            sawOldHeader = true
            let p = Self.headerPath(line.dropFirst(4), stripPrefix: "a/")
            current?.oldPath = p
            if p == nil { current?.isNew = true }
        } else if line.hasPrefix("+++ ") {
            sawNewHeader = true
            let p = Self.headerPath(line.dropFirst(4), stripPrefix: "b/")
            current?.newPath = p
            if p == nil { current?.isDeleted = true }
        } else if line.hasPrefix("new file mode") {
            current?.isNew = true
        } else if line.hasPrefix("deleted file mode") {
            current?.isDeleted = true
        } else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
            current?.oldPath = String(line.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst())
        } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
            current?.newPath = String(line.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst())
        } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            current?.isBinary = true
        }
    }

    mutating func finish() -> [UnifiedDiffFile] {
        closeFile()
        return files
    }

    private mutating func startFile(headerLine: String?) {
        closeFile()
        var file = UnifiedDiffFile()
        if let headerLine {
            file.headerLines = [headerLine]
            if headerLine.hasPrefix("diff --git ") {
                let (a, b) = Self.gitHeaderPaths(headerLine.dropFirst("diff --git ".count))
                file.oldPath = a
                file.newPath = b
            }
        }
        current = file
        sawOldHeader = false
        sawNewHeader = false
    }

    private mutating func closeFile() {
        closeHunk()
        guard var file = current else { return }
        if file.isNew { file.oldPath = nil }
        if file.isDeleted { file.newPath = nil }
        files.append(file)
        current = nil
    }

    private mutating func startHunk(_ line: String) {
        closeHunk()
        // @@ -a[,b] +c[,d] @@[ heading]
        var rest = Substring(line.dropFirst(2))
        rest = rest.drop(while: { $0 == " " })
        func range(_ s: inout Substring, sign: Character) -> (Int, Int) {
            guard s.first == sign else { return (0, 0) }
            s = s.dropFirst()
            let token = s.prefix(while: { $0 != " " })
            s = s.dropFirst(token.count).drop(while: { $0 == " " })
            let parts = token.split(separator: ",", maxSplits: 1)
            let start = Int(parts.first ?? "") ?? 0
            let count = parts.count > 1 ? (Int(parts[1]) ?? 0) : 1
            return (start, count)
        }
        let (os, oc) = range(&rest, sign: "-")
        let (ns, nc) = range(&rest, sign: "+")
        var heading: String?
        if let at = rest.range(of: "@@") {
            let h = rest[at.upperBound...].drop(while: { $0 == " " })
            heading = h.isEmpty ? nil : String(h)
        }
        let index = current?.hunks.count ?? 0
        hunk = DiffHunk(id: "\(os)-\(ns)-\(index)", oldStart: os, oldCount: oc, newStart: ns, newCount: nc, heading: heading, lines: [], headerText: line)
        oldRemaining = oc
        newRemaining = nc
        oldLine = os
        newLine = ns
    }

    private mutating func closeHunk() {
        guard let h = hunk else { return }
        current?.hunks.append(h)
        hunk = nil
        oldRemaining = 0
        newRemaining = 0
    }

    /// Consumes one body line while the hunk still expects lines. Returns false when the line cannot
    /// belong to the hunk (a truncated hunk), so it is re-examined as a header.
    private mutating func consumeHunkLine(_ line: String) -> Bool {
        guard let first = line.first else {
            // Some tools emit a bare empty line for an empty context line.
            appendLine(kind: .context, text: "", old: oldLine, new: newLine)
            oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
            return true
        }
        let text = String(line.dropFirst())
        switch first {
        case " ":
            appendLine(kind: .context, text: text, old: oldLine, new: newLine)
            oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
        case "+":
            appendLine(kind: .addition, text: text, old: nil, new: newLine)
            newLine += 1; newRemaining -= 1
        case "-":
            appendLine(kind: .deletion, text: text, old: oldLine, new: nil)
            oldLine += 1; oldRemaining -= 1
        case "\\":
            appendLine(kind: .noNewline, text: String(text.drop(while: { $0 == " " })), old: nil, new: nil)
        default:
            return false
        }
        return true
    }

    private mutating func appendLine(kind: DiffLine.Kind, text: String, old: Int?, new: Int?) {
        guard hunk != nil else { return }
        let id = hunk!.lines.count
        hunk!.lines.append(DiffLine(id: id, kind: kind, text: text, oldLineNumber: old, newLineNumber: new))
    }

    /// Path from a `---`/`+++` header: strips a trailing tab-separated timestamp, quotes, and the a//b/ prefix; nil for /dev/null.
    private static func headerPath(_ raw: Substring, stripPrefix: String) -> String? {
        var s = Substring(raw)
        if let tab = s.firstIndex(of: "\t") { s = s[..<tab] }
        var p = unquote(String(s))
        if p == "/dev/null" { return nil }
        if p.hasPrefix(stripPrefix) { p.removeFirst(stripPrefix.count) }
        return p
    }

    /// Splits `a/x b/y` from a `diff --git` line. Paths containing spaces are resolved by looking for the ` b/` boundary.
    private static func gitHeaderPaths(_ raw: Substring) -> (String?, String?) {
        let s = String(raw)
        if s.hasPrefix("\"") {
            // Quoted paths: "a/x y" "b/x y"
            let parts = s.split(separator: "\" \"", maxSplits: 1).map { unquote(String($0)) }
            if parts.count == 2 { return (strip(parts[0], "a/"), strip(parts[1], "b/")) }
        }
        if let r = s.range(of: " b/") {
            return (strip(String(s[..<r.lowerBound]), "a/"), strip(String(s[r.upperBound...]), ""))
        }
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (strip(parts[0], "a/"), strip(parts[1], "b/")) }
        return (nil, nil)
    }

    private static func strip(_ p: String, _ prefix: String) -> String? {
        if p == "/dev/null" { return nil }
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
    }

    private static func unquote(_ s: String) -> String {
        var p = s
        if p.hasPrefix("\"") { p.removeFirst() }
        if p.hasSuffix("\"") { p.removeLast() }
        // Minimal C-style unescaping for the common cases git emits.
        if p.contains("\\") {
            p = p.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return p
    }
}
