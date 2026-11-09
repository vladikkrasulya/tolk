// Owned by the "glossary" session. Foundation only.
//
// Editable model of `rules.md` that writes back the same Markdown `RulesStore` reads:
//   <!-- usage note -->            preamble, kept verbatim
//   ## Стиль                       free text, always injected into the prompt
//   ## Глоссарий EN → RU           "- term → translation (comment); term2 → translation2"
//   ## anything else               kept verbatim
//
// Round-trip rule: a glossary line whose entries were not touched is written back byte-for-byte;
// only edited lines are regenerated, new entries go to the end of the (first) glossary section.
import Foundation

public struct GlossaryEntry: Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    /// Source side, may hold variants: "landing / landing page".
    public var term: String
    /// Target side, may hold variants: "капа / дневная капа".
    public var translation: String
    /// Trailing "(...)" of the translation in the file: "паблишер (вебмастер, если про партнёрку)".
    public var comment: String

    public init(id: UUID = UUID(), term: String, translation: String, comment: String = "") {
        self.id = id; self.term = term; self.translation = translation; self.comment = comment
    }

    /// Same content, ignoring id and surrounding whitespace.
    public func sameContent(as o: GlossaryEntry) -> Bool {
        term.glTrimmed == o.term.glTrimmed && translation.glTrimmed == o.translation.glTrimmed && comment.glTrimmed == o.comment.glTrimmed
    }

    /// Case-insensitive key used for CSV merge and external-change merge.
    public var termKey: String { term.glTrimmed.lowercased() }

    /// The pair as it is written into the file (without the leading "- ").
    public var markdown: String {
        let t = Self.sanitize(term), tr = Self.sanitize(translation), c = Self.sanitize(comment)
            .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        var s = t
        if !tr.isEmpty { s += " → " + tr }
        if !c.isEmpty { s += " (" + c + ")" }
        return s
    }

    /// ";" separates pairs and a newline ends the line, so neither may appear inside a field.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ";", with: ",")
            .components(separatedBy: .newlines).joined(separator: " ")
            .glTrimmed
    }
}

public struct GlossaryDocument: Equatable, Sendable {
    /// Body of the "## Стиль" section (without the header).
    public var style: String
    /// All glossary pairs in file order; edit freely (ids keep the link to the file lines).
    public var entries: [GlossaryEntry]

    // Layout of the source file, used to write it back.
    enum Node: Equatable, Sendable {
        case raw(String)
        case styleBody
        case line(GlossaryLineNode)
        case insertPoint
    }
    struct GlossaryLineNode: Equatable, Sendable {
        var text: String                 // original line, verbatim
        var original: [GlossaryEntry]    // as parsed (ids match `entries`)
    }
    var nodes: [Node]
    var originalStyleLines: [String]
    var originalStyle: String

    public static let defaultStyleHeader = "## Стиль"
    public static let defaultGlossaryHeader = "## Глоссарий"

    public init(markdown raw: String) {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() } // trailing newline
        var nodes: [Node] = []
        var entries: [GlossaryEntry] = []
        var styleLines: [String] = []
        enum Section { case none, style, glossary, other }
        var section = Section.none
        var sawStyle = false, sawGlossary = false
        var inComment = false
        var pendingInsert = false // insertion point at the end of the first glossary section

        func closeGlossary() {
            guard pendingInsert else { return }
            // Put the insertion point before trailing blank lines of the section.
            var i = nodes.count
            while i > 0, case .raw(let s) = nodes[i - 1], s.glTrimmed.isEmpty { i -= 1 }
            nodes.insert(.insertPoint, at: i)
            pendingInsert = false
        }

        for line in lines {
            // HTML comments are invisible to RulesStore: keep them (and anything inside) verbatim.
            let wasInComment = inComment
            inComment = Self.commentState(after: line, startingIn: inComment)
            if wasInComment || line.contains("<!--") {
                if section == .style { styleLines.append(line) } else { nodes.append(.raw(line)) }
                continue
            }
            if line.hasPrefix("#") {
                closeGlossary()
                if RulesStoreCompat.isGlossaryHeader(line) {
                    section = .glossary
                    if !sawGlossary { pendingInsert = true }
                    sawGlossary = true
                    nodes.append(.raw(line))
                } else if !sawStyle, Self.isStyleHeader(line) {
                    section = .style
                    sawStyle = true
                    nodes.append(.raw(line))
                    nodes.append(.styleBody)
                } else {
                    section = .other
                    nodes.append(.raw(line))
                }
                continue
            }
            switch section {
            case .style:
                styleLines.append(line)
            case .glossary:
                let t = line.glTrimmed
                if (t.hasPrefix("-") || t.hasPrefix("*")), case let parsed = Self.parsePairs(t), !parsed.isEmpty {
                    entries += parsed
                    nodes.append(.line(GlossaryLineNode(text: line, original: parsed)))
                } else {
                    nodes.append(.raw(line))
                }
            case .none, .other:
                nodes.append(.raw(line))
            }
        }
        closeGlossary()
        self.nodes = nodes
        self.entries = entries
        self.originalStyleLines = styleLines
        self.originalStyle = styleLines.joined(separator: "\n").glTrimmed
        self.style = originalStyle
    }

    /// An empty document with the two standard sections.
    public init() { self.init(markdown: "\(Self.defaultStyleHeader)\n\n\(Self.defaultGlossaryHeader)\n") }

    /// Markdown for `rules.md`.
    public func markdown() -> String {
        var out: [String] = []
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = entries.filter { !$0.term.glTrimmed.isEmpty }
        var placed = Set<UUID>()
        var hasStyleNode = false, hasInsertPoint = false

        func emitNew() {
            for e in live where !placed.contains(e.id) {
                out.append("- " + e.markdown); placed.insert(e.id)
            }
        }
        func styleOut() -> [String] {
            if style.glTrimmed == originalStyle { return originalStyleLines }
            let body = style.glTrimmed
            return body.isEmpty ? [""] : body.components(separatedBy: "\n") + [""]
        }

        for node in nodes {
            switch node {
            case .raw(let s):
                out.append(s)
            case .styleBody:
                hasStyleNode = true
                out += styleOut()
            case .line(let ln):
                // Entries of this line that still exist, in their original order.
                let current = ln.original.compactMap { byId[$0.id] }.filter { !$0.term.glTrimmed.isEmpty }
                current.forEach { placed.insert($0.id) }
                if current.count == ln.original.count,
                   zip(current, ln.original).allSatisfy({ $0.sameContent(as: $1) }) {
                    out.append(ln.text)
                } else if !current.isEmpty {
                    out.append("- " + current.map(\.markdown).joined(separator: "; "))
                }
            case .insertPoint:
                hasInsertPoint = true
                emitNew()
            }
        }
        if !hasStyleNode, !style.glTrimmed.isEmpty {
            // No style section in the file: put one before the glossary (or at the end).
            let block = [Self.defaultStyleHeader, ""] + style.glTrimmed.components(separatedBy: "\n") + [""]
            if let g = out.firstIndex(where: RulesStoreCompat.isGlossaryHeader) {
                out.insert(contentsOf: block, at: g)
            } else {
                Self.trimTrailingBlank(&out)
                if !out.isEmpty { out.append("") }
                out += block
            }
        }
        if !hasInsertPoint, live.contains(where: { !placed.contains($0.id) }) {
            Self.trimTrailingBlank(&out)
            if !out.isEmpty { out.append("") }
            out.append(Self.defaultGlossaryHeader)
            emitNew()
        }
        Self.trimTrailingBlank(&out)
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Editing helpers

    /// Merges entries from elsewhere (CSV, external change): same term (case-insensitive) updates
    /// translation/comment, new terms are appended. Returns (added, updated).
    @discardableResult
    public mutating func merge(_ incoming: [GlossaryEntry], overwrite: Bool = true) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for e in incoming where !e.term.glTrimmed.isEmpty {
            if let i = entries.firstIndex(where: { $0.termKey == e.termKey }) {
                guard overwrite, !entries[i].sameContent(as: e) else { continue }
                entries[i].translation = e.translation
                entries[i].comment = e.comment
                updated += 1
            } else {
                entries.append(GlossaryEntry(term: e.term.glTrimmed, translation: e.translation.glTrimmed, comment: e.comment.glTrimmed))
                added += 1
            }
        }
        return (added, updated)
    }

    // MARK: - Parsing

    /// "- a → b (c); d → e" -> pairs. Splits on ";" outside parentheses; first "→"/"->" divides a pair.
    static func parsePairs(_ line: String) -> [GlossaryEntry] {
        let body = String(line.drop(while: { $0 == "-" || $0 == "*" || $0 == " " || $0 == "\t" }))
        return splitTopLevel(body, on: ";").compactMap { pair -> GlossaryEntry? in
            let p = pair.glTrimmed
            guard !p.isEmpty else { return nil }
            var term = p, translation = ""
            if let r = topLevelArrow(in: p) {
                term = String(p[..<r.lowerBound]).glTrimmed
                translation = String(p[r.upperBound...]).glTrimmed
            }
            var comment = ""
            if let (main, c) = trailingParenthetical(translation), !main.isEmpty {
                translation = main; comment = c
            }
            return GlossaryEntry(term: term, translation: translation, comment: comment)
        }
    }

    static func splitTopLevel(_ s: String, on sep: Character) -> [String] {
        var parts: [String] = [], cur = "", depth = 0
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if ch == sep, depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        parts.append(cur)
        return parts
    }

    static func topLevelArrow(in s: String) -> Range<String.Index>? {
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            else if depth == 0 {
                if ch == "→" { return i..<s.index(after: i) }
                if ch == "-", s.index(after: i) < s.endIndex, s[s.index(after: i)] == ">" {
                    return i..<s.index(i, offsetBy: 2)
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// "паблишер (вебмастер)" -> ("паблишер", "вебмастер"); requires the "(...)" to close the string.
    static func trailingParenthetical(_ s: String) -> (String, String)? {
        guard s.hasSuffix(")") else { return nil }
        var depth = 0
        var i = s.endIndex
        while i > s.startIndex {
            i = s.index(before: i)
            if s[i] == ")" { depth += 1 }
            else if s[i] == "(" {
                depth -= 1
                if depth == 0 {
                    let inner = String(s[s.index(after: i)..<s.index(before: s.endIndex)]).glTrimmed
                    return (String(s[..<i]).glTrimmed, inner)
                }
            }
        }
        return nil
    }

    static func isStyleHeader(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("стил") || l.contains("style") || l.contains("правил") || l.contains("rules")
    }

    static func commentState(after line: String, startingIn inside: Bool) -> Bool {
        var inside = inside
        var rest = Substring(line)
        while true {
            if inside {
                guard let r = rest.range(of: "-->") else { return true }
                inside = false; rest = rest[r.upperBound...]
            } else {
                guard let r = rest.range(of: "<!--") else { return false }
                inside = true; rest = rest[r.upperBound...]
            }
        }
    }

    static func trimTrailingBlank(_ a: inout [String]) {
        while let l = a.last, l.glTrimmed.isEmpty { a.removeLast() }
    }
}

/// Mirrors `RulesStore.isGlossaryHeader` (internal there; kept identical on purpose).
enum RulesStoreCompat {
    static func isGlossaryHeader(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        let l = line.lowercased()
        return l.contains("глоссар") || l.contains("глосар") || l.contains("glossary")
    }
}

extension String {
    /// Internal to TolkCore (glossary files only use it).
    var glTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
