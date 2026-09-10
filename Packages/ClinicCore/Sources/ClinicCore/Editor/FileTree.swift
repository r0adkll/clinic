import Foundation

/// A nested file tree built from a flat list of relative paths: directories first, name-sorted.
///
/// Shared by the Files panel's repo tree (ADR-057) and the pull request panel's changed-file tree
/// (ADR-091). It lives here rather than in the app target because it is pure and worth testing —
/// the flattening below in particular, which is what both surfaces actually render (ADR-099).
public struct FileTreeNode: Identifiable, Hashable, Sendable {
    public let relativePath: String
    public let name: String
    public let isDirectory: Bool
    public var children: [FileTreeNode]?
    public var id: String { relativePath }

    public init(relativePath: String, name: String, isDirectory: Bool, children: [FileTreeNode]? = nil) {
        self.relativePath = relativePath
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
    }

    public static func build(from files: [String], showHidden: Bool) -> [FileTreeNode] {
        final class Dir { var dirs: [String: Dir] = [:]; var files: [String] = [] }
        let root = Dir()
        for f in files {
            let parts = f.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            if !showHidden && parts.contains(where: { $0.hasPrefix(".") }) { continue }
            var cur = root
            for p in parts.dropLast() { if cur.dirs[p] == nil { cur.dirs[p] = Dir() }; cur = cur.dirs[p]! }
            cur.files.append(parts.last!)
        }
        func nodes(_ d: Dir, prefix: String) -> [FileTreeNode] {
            let dirs = d.dirs.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
                FileTreeNode(relativePath: prefix + name, name: name, isDirectory: true, children: nodes(d.dirs[name]!, prefix: prefix + name + "/"))
            }
            let files = d.files.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { FileTreeNode(relativePath: prefix + $0, name: $0, isDirectory: false, children: nil) }
            return dirs + files
        }
        return nodes(root, prefix: "")
    }

    /// Folds runs of single-child directories into one row (ADR-091).
    ///
    /// A pull request tree is not a repo tree: it holds only the touched paths, so a Kotlin or Java
    /// project produces chains like `infra/audioplayer/api/src/commonMain/kotlin/com/…` where every
    /// level has exactly one child. Expanded one level at a time that is six clicks to reach a file
    /// and a tree mostly made of indentation. GitHub and VS Code both fold these; so does this.
    ///
    /// The folded row keeps the *deepest* path as its identity, so an expansion set built from path
    /// prefixes (`ancestors(of:)`) still names it.
    public static func compress(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.map { node in
            guard node.isDirectory, var children = node.children else { return node }
            var name = node.name
            var path = node.relativePath
            // Only fold when the single child is itself a directory: a folder holding one file still
            // shows that file as its own row.
            while children.count == 1, let only = children.first, only.isDirectory, let next = only.children {
                name += "/" + only.name
                path = only.relativePath
                children = next
            }
            return FileTreeNode(relativePath: path, name: name, isDirectory: true, children: compress(children))
        }
    }
}

/// One visible row of a flattened tree: everything a row draws, and nothing that changes when a
/// sibling does.
///
/// Trees are rendered as a flat list rather than nested `OutlineGroup`s (ADR-099). Flat rows are what
/// let a row be a full-width control — `OutlineGroup` hands its content closure a view only as wide
/// as its own label, so most of the column was dead space — and they put expansion in the model,
/// where it survives the tree being rebuilt underneath it.
public struct FileTreeRow: Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let depth: Int
    public let isDirectory: Bool
    /// Meaningless for a file; a directory row draws its chevron from it.
    public let isExpanded: Bool
    public var id: String { path }

    public init(path: String, name: String, depth: Int, isDirectory: Bool, isExpanded: Bool) {
        self.path = path
        self.name = name
        self.depth = depth
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
    }
}

extension FileTreeNode {
    /// Depth-first rows for an expansion set. Only descends into open directories, so a collapsed
    /// 50 000-file repo costs one pass over its top level.
    public static func rows(_ nodes: [FileTreeNode], expanded: Set<String>) -> [FileTreeRow] {
        var out: [FileTreeRow] = []
        func walk(_ nodes: [FileTreeNode], depth: Int) {
            for node in nodes {
                let open = node.isDirectory && expanded.contains(node.relativePath)
                out.append(FileTreeRow(path: node.relativePath, name: node.name, depth: depth,
                                       isDirectory: node.isDirectory, isExpanded: open))
                if open, let children = node.children { walk(children, depth: depth + 1) }
            }
        }
        walk(nodes, depth: 0)
        return out
    }

    /// Every directory in the tree — the expansion set for "show me the whole thing", which is what a
    /// pull request's file list wants on arrival.
    public static func directories(_ nodes: [FileTreeNode]) -> Set<String> {
        var out: Set<String> = []
        func walk(_ nodes: [FileTreeNode]) {
            for node in nodes where node.isDirectory {
                out.insert(node.relativePath)
                if let children = node.children { walk(children) }
            }
        }
        walk(nodes)
        return out
    }

    /// The directories that must be open for `path` to be on screen: every path prefix, so it names
    /// the folded rows of a compressed tree (`a/b`) as well as the plain ones (`a`).
    public static func ancestors(of path: String) -> Set<String> {
        let parts = path.split(separator: "/").dropLast()
        var out: Set<String> = []
        var prefix = ""
        for p in parts {
            prefix += prefix.isEmpty ? String(p) : "/" + p
            out.insert(prefix)
        }
        return out
    }
}
