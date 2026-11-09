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

    public init(path: String) { self.path = expandPath(path) }

    /// Rules block for the system prompt: style always, glossary only lines matching `text`.
    public func promptBlock(for text: String) -> String {
        let p = current()
        var parts: [String] = []
        if !p.style.isEmpty { parts.append(p.style) }
        let range = NSRange(text.startIndex..., in: text)
        let hits = p.glossary.filter { line in
            line.patterns.contains { $0.firstMatch(in: text, range: range) != nil }
        }
        if !hits.isEmpty {
            parts.append(([p.glossaryHeader.isEmpty ? "## Glossary" : p.glossaryHeader] + hits.map(\.text))
                .joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Appends `- source → translation` to the end of the glossary section (or of the file).
    public func addTerm(source: String, translation: String) throws {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty else { return }
        let entry = "- \(s) → \(t)"
        lock.lock(); defer { lock.unlock() }
        let url = URL(fileURLWithPath: path)
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
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
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
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

    /// Case-insensitive match at a word start. Russian/Ukrainian forms drop a trailing vowel so that
    /// "капа" also matches "капу/капы", "постбек" matches "постбеки".
    static func pattern(for term: String) -> NSRegularExpression? {
        let words = term.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let vowels: Set<Character> = ["а", "я", "о", "е", "ы", "и", "і", "у", "ю", "й", "ь"]
        let stems = words.map { w -> String in
            var w = w
            if w.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }),
               w.count >= 4, let last = w.last, vowels.contains(last) { w.removeLast() }
            return NSRegularExpression.escapedPattern(for: w)
        }
        let body = stems.joined(separator: "\\w*[\\s-]+")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + body, options: [.caseInsensitive])
    }
}
