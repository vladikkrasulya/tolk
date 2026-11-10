import Foundation

/// Reads `rules.md` (style section + glossary lines `- term → перевод`), re-reading on mtime change,
/// and picks only the glossary lines relevant to a given text.
public final class RulesStore: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()
    private var mtime: Date?
    private var parsed = Parsed()

    struct GlossaryLine {
        let text: String       // the original "- a → b; c → d" line
        let patterns: [NSRegularExpression]
    }
    struct Parsed {
        var style = ""
        var glossaryHeader = ""
        var glossary: [GlossaryLine] = []
    }

    /// Used in memory when the file does not exist (fresh install); never written unless the user adds a term.
    private let builtIn: String?

    public init(path: String, builtIn: String? = nil) { self.path = expandPath(path); self.builtIn = builtIn }

    /// True when the rules come from the built-in text because the file is missing.
    public var usesBuiltIn: Bool { builtIn != nil && !FileManager.default.fileExists(atPath: path) }

    /// Rules block for the system prompt: style always, glossary only lines matching `text`.
    /// With `target`, every glossary pair is turned to point INTO the target language
    /// (the file mixes «en → ru» and «ru → en»; Gemma copied the wrong side otherwise).
    public func promptBlock(for text: String, target: Language? = nil) -> String {
        let p = current()
        var parts: [String] = []
        if !p.style.isEmpty { parts.append(p.style) }
        let range = NSRange(text.startIndex..., in: text)
        let hits = p.glossary.filter { line in
            line.patterns.contains { $0.firstMatch(in: text, range: range) != nil }
        }
        if !hits.isEmpty {
            if let target {
                let toCyrillic = target == .russian || target == .ukrainian || target == .bulgarian || target == .kazakh
                let header = toCyrillic ? "## Glossary: English → how to write it in the translation"
                                        : "## Glossary: Russian → how to write it in English"
                parts.append(([header] + hits.map { Self.orient($0.text, toCyrillic: toCyrillic) }).joined(separator: "\n"))
            } else {
                parts.append(([p.glossaryHeader.isEmpty ? "## Glossary" : p.glossaryHeader] + hits.map(\.text))
                    .joined(separator: "\n"))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// "- без жести → nothing explicit; a → b" turned so that each pair points into the target script.
    static func orient(_ line: String, toCyrillic: Bool) -> String {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("- ") { body.removeFirst(2) }
        let pairs = body.components(separatedBy: ";").map { pair -> String in
            let sides = pair.components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }
            guard sides.count == 2 else { return pair.trimmingCharacters(in: .whitespaces) }
            let (a, b) = (sides[0], sides[1])
            let aCyr = isMostlyCyrillic(a), bCyr = isMostlyCyrillic(b)
            let swap = toCyrillic ? (aCyr && !bCyr) : (!aCyr && bCyr)
            return swap ? "\(b) → \(a)" : "\(a) → \(b)"
        }
        return "- " + pairs.joined(separator: "; ")
    }

    static func isMostlyCyrillic(_ s: String) -> Bool {
        var cyr = 0, lat = 0
        for u in s.unicodeScalars {
            if (0x0400...0x04FF).contains(u.value) { cyr += 1 }
            else if (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) { lat += 1 }
        }
        return cyr > lat
    }

    /// Appends `- source → translation` to the end of the glossary section (or of the file).
    public func addTerm(source: String, translation: String) throws {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty else { return }
        let entry = "- \(s) → \(t)"
        lock.lock(); defer { lock.unlock() }
        let url = URL(fileURLWithPath: path)
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? builtIn ?? "")
            .components(separatedBy: "\n")
        if let g = lines.firstIndex(where: Self.isGlossaryHeader) {
            var end = lines[(g + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
            while end > g + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.insert(entry, at: end)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.append(entry)
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, atomically: true, encoding: .utf8)
        mtime = nil // force re-read
    }

    // MARK: - Loading

    private func current() -> Parsed {
        lock.lock(); defer { lock.unlock() }
        let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if m != mtime || m == nil {
            mtime = m
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? (m == nil ? builtIn ?? "" : "")
            parsed = Self.parse(text)
        }
        return parsed
    }

    static func isGlossaryHeader(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        let l = line.lowercased()
        return l.contains("глоссар") || l.contains("глосар") || l.contains("glossary")
    }

    static func parse(_ raw: String) -> Parsed {
        // Drop HTML comments (the file starts with a usage note for humans).
        let text = raw.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        var p = Parsed()
        var style: [String] = []
        var inGlossary = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                inGlossary = isGlossaryHeader(line)
                if inGlossary { p.glossaryHeader = line; continue }
            }
            if inGlossary {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("-") || t.hasPrefix("*") else { continue }
                let pats = terms(in: t).compactMap(pattern(for:))
                p.glossary.append(GlossaryLine(text: t, patterns: pats))
            } else {
                style.append(line)
            }
        }
        p.style = style.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return p
    }

    /// All forms on both sides of every arrow: "cap / daily cap → капа / дневная капа" ->
    /// ["cap", "daily cap", "капа", "дневная капа"].
    static func terms(in line: String) -> [String] {
        var body = String(line.drop(while: { $0 == "-" || $0 == "*" || $0 == " " }))
        body = body.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        let separators = CharacterSet(charactersIn: ";,/")
        return body.components(separatedBy: "→")
            .flatMap { $0.components(separatedBy: "->") }
            .flatMap { $0.components(separatedBy: separators) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    /// Case-insensitive whole-word match.
    /// Latin terms: only regular inflection may follow (s/es/ed/d/ing, 's, y→ies, doubled final consonant),
    /// so "cap" matches "caps", "capped" but not "capital"; "feed" not "feedback". A verb entry ("to scale")
    /// does not fire when a particle follows that changes the meaning ("scale back").
    /// Cyrillic terms: matched by stem; a trailing vowel of a 4+ letter word is dropped and an ending of up to
    /// 3 letters is allowed, so «капа» matches «капу/капы/капой» but not «капитал».
    static func pattern(for term: String) -> NSRegularExpression? {
        let words = term.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let start = "(?<![\\p{L}\\p{N}])"
        let end = "(?![\\p{L}\\p{N}])"
        let isCyr = { (w: String) in w.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }
        var parts: [String] = []
        for (i, w) in words.enumerated() {
            let last = i == words.count - 1
            if isCyr(w) {
                let stem = cyrillicStem(w)
                parts.append(NSRegularExpression.escapedPattern(for: stem) + "\\p{L}{0,3}")
            } else if last {
                parts.append(latinForms(w))
            } else {
                parts.append(NSRegularExpression.escapedPattern(for: w))
            }
        }
        var body = parts.joined(separator: "[\\s-]+")
        var tail = end
        if words.count == 2, words[0] == "to", !isCyr(words[1]) {
            tail += "(?!\\s+(?:back|away|around|off|over|out)(?![\\p{L}\\p{N}]))"
        }
        body = start + body + tail
        return try? NSRegularExpression(pattern: body, options: [.caseInsensitive])
    }

    static func cyrillicStem(_ word: String) -> String {
        let vowels: Set<Character> = ["а", "я", "о", "е", "ы", "и", "і", "у", "ю", "й", "ь", "ї", "є"]
        var w = word
        let twoLetter = ["ая", "яя", "ое", "ее", "ый", "ий", "ой", "ую", "юю", "ых", "их", "ій", "ою"]
        if w.count >= 6, twoLetter.contains(String(w.suffix(2))) { w.removeLast(2) }
        else if w.count >= 4, let last = w.last, vowels.contains(last) { w.removeLast() }
        return w
    }

    /// "cap" -> cap(?:s|es|ed|d|ing|'s|’s|ped|ping) — whole word, regular inflection only.
    static func latinForms(_ w: String) -> String {
        guard let lastChar = w.last, lastChar.isLetter, w.count >= 2 else { return NSRegularExpression.escapedPattern(for: w) }
        let esc = NSRegularExpression.escapedPattern(for: w)
        var alts = ["s", "es", "ed", "d", "ing", "'s", "’s", "s'", "s’"]
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        var stemAlts: [String] = []
        if lastChar == "e" {
            stemAlts.append(NSRegularExpression.escapedPattern(for: String(w.dropLast())) + "ing")
        } else if lastChar == "y" {
            let stem = NSRegularExpression.escapedPattern(for: String(w.dropLast()))
            stemAlts += [stem + "ies", stem + "ied"]
        } else if !vowels.contains(lastChar), lastChar != "w", lastChar != "x" {
            let c = NSRegularExpression.escapedPattern(for: String(lastChar))
            alts += ["\(c)ed", "\(c)ing"]
        }
        let all = stemAlts + alts.map { esc + NSRegularExpression.escapedPattern(for: $0) }
        return "(?:" + esc + "|" + all.joined(separator: "|") + ")"
    }
}
