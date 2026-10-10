import Foundation

/// What the Files pane's Markdown preview needs to know about a document before and after the
/// renderer has seen it (ADR-191). The renderer itself is cmark-gfm in the app target; this is the
/// part that is plain text and can be tested here.
public enum MarkdownDocument {
    /// YAML front matter, split from the body. The body keeps a blank line for every line the front
    /// matter took, so the renderer's source positions are still the editor's line numbers — which is
    /// what the split view scrolls by.
    public static func split(_ text: String) -> (frontMatter: String?, body: String) {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, trimmed(first) == "---" else { return (nil, text) }
        guard let close = lines.dropFirst().firstIndex(where: { trimmed($0) == "---" || trimmed($0) == "..." }) else {
            return (nil, text)
        }
        let yaml = lines[1..<close].joined(separator: "\n")
        let body = Array(repeating: "", count: close + 1) + lines[(close + 1)...]
        return (yaml, body.joined(separator: "\n"))
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file an Obsidian `[[wiki link]]` points at, among `paths` (relative to the same root as
    /// `from`, the document holding the link).
    ///
    /// The target may carry a heading (`#…`) or block (`^…`) after the name, and names a Markdown note
    /// unless it has an extension of its own. A bare name matches any file of that name in the tree,
    /// as Obsidian's shortest-path links do; when several do, the one beside the document wins, then
    /// the shallowest.
    public static func resolveWikiLink(_ target: String, from: String, in paths: [String]) -> String? {
        var name = target
        if let cut = name.firstIndex(where: { $0 == "#" || $0 == "^" }) { name = String(name[..<cut]) }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("/") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        if (name as NSString).pathExtension.isEmpty { name += ".md" }

        let needle = name.lowercased()
        let matches = paths.filter {
            let p = $0.lowercased()
            return p == needle || p.hasSuffix("/" + needle)
        }
        guard !matches.isEmpty else { return nil }
        let here = (from as NSString).deletingLastPathComponent
        return matches.min { a, b in
            let aHere = (a as NSString).deletingLastPathComponent == here
            let bHere = (b as NSString).deletingLastPathComponent == here
            if aHere != bHere { return aHere }
            let aDepth = a.split(separator: "/").count, bDepth = b.split(separator: "/").count
            if aDepth != bDepth { return aDepth < bDepth }
            return a < b
        }
    }
}
