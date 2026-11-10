// Back-translation check: what really differs in MEANING between the original and its round trip.
// Synonyms («reviewed» for «looked at») are noise and are NOT reported; only
//   - numbers that changed (64 → 46) or went missing,
//   - negations that appeared or disappeared (not / не / ні),
//   - names, acronyms and file names that appeared or went missing,
//   - glossary terms that did not survive.
// No model. `marks` are ranges in the back-translation (to highlight); `missing` are things that are in the original
// but not in the round trip (nothing to highlight there, so the UI lists them in words).
import Foundation

public enum BackDiff {
    public struct Result: Sendable, Equatable {
        public var marks: [NSRange] = []
        public var missing: [String] = []
        public var isClean: Bool { marks.isEmpty && missing.isEmpty }
    }

    public static func compare(source: String, back: String, glossary: [GlossaryHit] = []) -> Result {
        var r = Result()
        let backNS = back as NSString
        func add(_ range: NSRange) { if !r.marks.contains(range) { r.marks.append(range) } }
        func miss(_ s: String) { if !r.missing.contains(s) { r.missing.append(s) } }

        // Numbers
        let srcNums = numbers(in: source), backNums = numbers(in: back)
        let srcKeys = Set(srcNums.map(\.key)), backKeys = Set(backNums.map(\.key))
        for n in backNums where !srcKeys.contains(n.key) { add(n.range) }
        for n in srcNums where !backKeys.contains(n.key) { miss(n.text) }

        // Negations: compared sentence by sentence when the sentences pair up, else over the whole text.
        let pairs = SentencePairing.pairs(source: source, translation: back)
        var units: [(String, String, NSRange)] = []
        if !pairs.isEmpty, pairs.allSatisfy(\.isConfident) {
            for p in pairs { units.append(((source as NSString).substring(with: p.source), backNS.substring(with: p.translation), p.translation)) }
        } else {
            units = [(source, back, NSRange(location: 0, length: backNS.length))]
        }
        var negMissing = false
        for (s, b, range) in units {
            let sn = negations(in: s), bn = negations(in: b)
            if sn.isEmpty != bn.isEmpty {
                if bn.isEmpty { negMissing = true } else { for n in bn { add(NSRange(location: range.location + n.location, length: n.length)) } }
            }
        }
        if negMissing { miss("отрицание") }

        // Names, acronyms, file names
        let srcNames = names(in: source), backNames = names(in: back)
        let srcWords = Set(words(in: source).map { $0.0 }), backWords = Set(words(in: back).map { $0.0 })
        let srcLow = source.lowercased(), backLow = back.lowercased()
        for n in srcNames where !(n.word.contains(".") ? backLow.contains(n.word) : contains(backWords, n.word)) { miss(n.text) }
        for n in backNames where !(n.word.contains(".") ? srcLow.contains(n.word) : contains(srcWords, n.word)) { add(n.range) }

        // Glossary terms of the original
        let low = back.lowercased()
        for h in glossary {
            let found = RulesStore.pattern(for: h.source).map { $0.firstMatch(in: back, range: NSRange(location: 0, length: backNS.length)) != nil } ?? low.contains(h.source.lowercased())
            if !found { miss(h.source) }
        }
        r.marks.sort { $0.location < $1.location }
        return r
    }

    // MARK: - Pieces

    struct Num { let text: String; let key: String; let range: NSRange }

    static let numberRE = try! NSRegularExpression(pattern: "\\d{1,3}(?:[\\u00a0\\u202f ,.]\\d{3})+(?:[.,]\\d+)?|\\d+(?:[.,:]\\d+)*")

    static func numbers(in s: String) -> [Num] {
        let ns = s as NSString
        return numberRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            let t = ns.substring(with: m.range)
            return Num(text: t, key: t.filter(\.isNumber), range: m.range)
        }
    }

    static let negationWords: Set<String> = [
        "not", "no", "never", "none", "nobody", "nothing", "cannot", "neither", "nor",
        "не", "нет", "ни", "никогда", "никто", "ничего", "нельзя",
        "ні", "немає", "ніколи", "ніхто", "нічого", "неможливо",
    ]

    static func negations(in s: String) -> [NSRange] {
        words(in: s).compactMap { w, r -> NSRange? in
            let word = w.replacingOccurrences(of: "’", with: "'")
            return negationWords.contains(word) || word.hasSuffix("n't") ? r : nil
        }
    }

    static let wordRE = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}'’]*")

    /// Lowercased words with their ranges.
    static func words(in s: String) -> [(String, NSRange)] {
        let ns = s as NSString
        return wordRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range).lowercased(), $0.range) }
    }

    struct Name { let text: String; let word: String; let range: NSRange }

    static let fileRE = try! NSRegularExpression(pattern: "[A-Za-z0-9][A-Za-z0-9_-]*(?:\\.[A-Za-z0-9_-]+)*\\.[A-Za-z]{2,}")

    /// ALL-CAPS acronyms (CTR, SSP), capitalized words that do not open a sentence (Friday, Max), domain/file names.
    static func names(in s: String) -> [Name] {
        let ns = s as NSString
        var out: [Name] = []
        var covered: [NSRange] = []
        for m in fileRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range)
            guard t.rangeOfCharacter(from: .letters) != nil, !t.allSatisfy({ $0.isNumber || $0 == "." }) else { continue }
            out.append(Name(text: t, word: t.lowercased(), range: m.range))
            covered.append(m.range)
        }
        for (w, r) in words(in: s) where w.count >= 2 {
            if covered.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let t = ns.substring(with: r)
            guard let first = t.first, first.isUppercase else { continue }
            let letters = t.filter(\.isLetter)
            let acronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
            if acronym { out.append(Name(text: t, word: w, range: r)); continue }
            if letters.count >= 3, !opensSentence(ns, at: r.location) { out.append(Name(text: t, word: w, range: r)) }
        }
        return out
    }

    private static func opensSentence(_ ns: NSString, at location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if let u = Unicode.Scalar(c) {
                if CharacterSet.whitespaces.contains(u) || "\"'«“„([-–—•*".unicodeScalars.contains(u) { i -= 1; continue }
                return ".!?…\n:".unicodeScalars.contains(u) || u == "\r"
            }
            return false
        }
        return true
    }

    /// The word, or an inflected form of it (the round trip may decline a name), is among `words`.
    private static func contains(_ words: Set<String>, _ w: String) -> Bool {
        if words.contains(w) { return true }
        // Plural of an acronym or name: DSP / DSPs, ID / IDs.
        if w.hasSuffix("s"), w.count >= 3, words.contains(String(w.dropLast())) { return true }
        if words.contains(w + "s") { return true }
        guard w.count >= 5 else { return false }
        let stem = String(w.prefix(w.count - 2))
        return words.contains { $0.hasPrefix(stem) }
    }
}
