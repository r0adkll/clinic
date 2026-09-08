import Foundation

/// Case-insensitive subsequence matching with a score that favours consecutive hits, segment starts and the file name.
public enum FuzzyMatcher {
    public struct Match: Sendable, Hashable {
        public var score: Int
        public var matchedIndices: [Int]
    }

    public static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.lowercased().unicodeScalars).filter { !$0.properties.isWhitespace }
        if q.isEmpty { return Match(score: 0, matchedIndices: []) }
        let c = Array(candidate.unicodeScalars)
        let lower = Array(candidate.lowercased().unicodeScalars)
        guard c.count == lower.count else { return greedy(q, candidate: candidate) }
        let nameStart = (c.lastIndex(of: "/").map { $0 + 1 }) ?? 0

        var indices: [Int] = []
        var score = 0
        var qi = 0
        var last = -2
        for (i, ch) in lower.enumerated() where qi < q.count && ch == q[qi] {
            var s = 1
            if i == last + 1 { s += 4 }                                   // consecutive
            if i == 0 || isBoundary(prev: c[i - 1], cur: c[i]) { s += 3 } // segment / camel start
            if i >= nameStart { s += 2 }                                  // in file name
            score += s
            indices.append(i)
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        score -= c.count / 8                                              // shorter wins ties
        if let first = indices.first, first >= nameStart { score += 3 }
        return Match(score: score, matchedIndices: indices)
    }

    private static func greedy(_ q: [Unicode.Scalar], candidate: String) -> Match? {
        var qi = 0; var idx: [Int] = []
        for (i, ch) in candidate.lowercased().unicodeScalars.enumerated() where qi < q.count && ch == q[qi] { idx.append(i); qi += 1 }
        return qi == q.count ? Match(score: idx.count, matchedIndices: idx) : nil
    }

    private static func isBoundary(prev: Unicode.Scalar, cur: Unicode.Scalar) -> Bool {
        if "/_-. ".unicodeScalars.contains(prev) { return true }
        return prev.properties.isLowercase && cur.properties.isUppercase
    }

    public static func rank(_ query: String, candidates: [String], limit: Int = 50) -> [(candidate: String, match: Match)] {
        var out: [(String, Match)] = []
        out.reserveCapacity(min(candidates.count, limit * 4))
        for c in candidates { if let m = match(query, in: c) { out.append((c, m)) } }
        let sorted = out.enumerated().sorted { a, b in
            if a.element.1.score != b.element.1.score { return a.element.1.score > b.element.1.score }
            return a.offset < b.offset
        }
        return sorted.prefix(limit).map { (candidate: $0.element.0, match: $0.element.1) }
    }
}
