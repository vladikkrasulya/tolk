// Sentence pairs for the big window: which sentence of the translation answers which sentence of the source,
// so the UI can highlight the pair under the cursor. Pure function: no model, no network. Uses the same
// `SentenceSplitter` as live typing.
import Foundation

public struct SentencePair: Sendable, Equatable {
    /// UTF-16 ranges (NSRange) inside the exact strings that were passed in; whitespace around is excluded.
    /// A group of several sentences (when the counts differ) is one contiguous range.
    public let source: NSRange
    public let translation: NSRange
    /// false = the pairing is a guess (different sentence counts, or very different lengths).
    public let isConfident: Bool

    public func sourceRange(in text: String) -> Range<String.Index>? { Range(source, in: text) }
    public func translationRange(in text: String) -> Range<String.Index>? { Range(translation, in: text) }
}

public enum SentencePairing {
    /// Pairs in reading order, covering all non-blank sentences of both texts. Empty if either text is blank.
    public static func pairs(source: String, translation: String) -> [SentencePair] {
        let s = units(source), t = units(translation)
        guard !s.isEmpty, !t.isEmpty else { return [] }

        // Same number of non-empty lines (a list, paragraphs): pair line by line, then sentences inside the line.
        let sl = lines(source), tl = lines(translation)
        if sl.count > 1, sl.count == tl.count {
            var out: [SentencePair] = []
            for (a, b) in zip(sl, tl) {
                out += align(units(source, within: a), units(translation, within: b))
            }
            return out
        }
        return align(s, t)
    }

    // MARK: Units

    struct Unit { let range: NSRange; var length: Int { range.length } }

    /// Sentences with trailing/leading whitespace trimmed, blank ones dropped.
    static func units(_ text: String, within: NSRange? = nil) -> [Unit] {
        let ns = text as NSString
        var out: [Unit] = []
        var offset = 0
        for piece in SentenceSplitter.split(text) {
            let len = (piece as NSString).length
            var r = NSRange(location: offset, length: len)
            offset += len
            if let w = within {
                let i = NSIntersectionRange(r, w)
                if i.length == 0 { continue }
                r = i
            }
            while r.length > 0, isSpace(ns.character(at: r.location)) { r.location += 1; r.length -= 1 }
            while r.length > 0, isSpace(ns.character(at: r.location + r.length - 1)) { r.length -= 1 }
            if r.length > 0 { out.append(Unit(range: r)) }
        }
        // A bare list marker («1.», «2)», «-», «•») belongs to the item that follows it.
        var merged: [Unit] = []
        var i = 0
        while i < out.count {
            let marker = ns.substring(with: out[i].range)
            if i + 1 < out.count, marker.range(of: "^(\\d{1,3}[.)]|[-–—•*])$", options: .regularExpression) != nil {
                let a = out[i].range, b = out[i + 1].range
                merged.append(Unit(range: NSRange(location: a.location, length: b.location + b.length - a.location)))
                i += 2
            } else { merged.append(out[i]); i += 1 }
        }
        return merged
    }

    /// Ranges of non-blank lines.
    static func lines(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { sub, r, _, _ in
            if let sub, !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(r) }
        }
        return out
    }

    private static func isSpace(_ c: unichar) -> Bool {
        guard let u = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(u)
    }

    // MARK: Alignment

    /// Length-based alignment (Gale–Church style, simplified): groups of 1:1, 1:2, 2:1, 1:3, 3:1 sentences,
    /// minimising the sum of |log(length ratio)| with a penalty for anything but 1:1.
    static func align(_ s: [Unit], _ t: [Unit]) -> [SentencePair] {
        guard !s.isEmpty, !t.isEmpty else { return [] }
        let n = s.count, m = t.count
        if n == m {
            return zip(s, t).map { a, b in SentencePair(source: a.range, translation: b.range, isConfident: ratioOK(a.length, b.length)) }
        }
        func len(_ u: [Unit], _ i: Int, _ k: Int) -> Int { u[i..<i + k].reduce(0) { $0 + $1.length } }
        func cost(_ a: Int, _ b: Int) -> Double { abs(log(Double(a + 8) / Double(b + 8))) }
        let moves = [(1, 1, 0.0), (1, 2, 0.7), (2, 1, 0.7), (1, 3, 1.6), (3, 1, 1.6)]
        let inf = Double.infinity
        var best = Array(repeating: Array(repeating: inf, count: m + 1), count: n + 1)
        var back = Array(repeating: Array(repeating: (0, 0), count: m + 1), count: n + 1)
        best[0][0] = 0
        for i in 0...n {
            for j in 0...m where best[i][j] < inf {
                for (di, dj, pen) in moves where i + di <= n && j + dj <= m {
                    let c = best[i][j] + pen + cost(len(s, i, di), len(t, j, dj))
                    if c < best[i + di][j + dj] { best[i + di][j + dj] = c; back[i + di][j + dj] = (di, dj) }
                }
            }
        }
        // Counts that cannot be covered by the allowed moves (e.g. 1 vs 5): one group per side.
        guard best[n][m] < inf else {
            return [SentencePair(source: union(s[...]), translation: union(t[...]), isConfident: false)]
        }
        var groups: [(Int, Int, Int, Int)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let (di, dj) = back[i][j]
            groups.append((i - di, di, j - dj, dj))
            i -= di; j -= dj
        }
        return groups.reversed().map { si, di, tj, dj in
            let a = s[si..<si + di], b = t[tj..<tj + dj]
            return SentencePair(source: union(a), translation: union(b),
                                isConfident: di == 1 && dj == 1 && ratioOK(a.first!.length, b.first!.length))
        }
    }

    private static func union(_ u: ArraySlice<Unit>) -> NSRange {
        let a = u.first!.range, b = u.last!.range
        return NSRange(location: a.location, length: b.location + b.length - a.location)
    }

    /// Translations differ from the source by up to ~2x in length; more than that looks like a misalignment.
    private static func ratioOK(_ a: Int, _ b: Int) -> Bool {
        let r = Double(a + 6) / Double(b + 6)
        return r > 0.4 && r < 2.5
    }
}
