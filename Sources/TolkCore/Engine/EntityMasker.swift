// Protection of technical fragments (URLs, macros, code, ticket ids …): they are replaced by placeholders before
// the text goes to the model and put back after the translation. If a placeholder is lost or duplicated, the caller
// translates the original text without masking (see EntityMasking in MaskedTranslation.swift).
import Foundation

public struct EntityMasker: Sendable {
    public enum Kind: String, Sendable { case code, link, email, mention, macro, ticket, field, path, id }

    public struct Entity: Sendable, Equatable {
        public let token: String
        public let original: String
        public let kind: Kind
    }

    /// Placeholder look. Chosen by measurement on gemma-translate (see report); `.tag` is the default (0 failures on 24 texts; ⟦⟧ and §§ lost a placeholder once).
    public enum Format: String, Sendable, CaseIterable {
        case brackets   // ⟦1⟧
        case section    // §1§
        case square     // [[1]]
        case tag        // <x1/>
        case word       // QZX1Q

        public func token(_ i: Int) -> String {
            switch self {
            case .brackets: "⟦\(i)⟧"
            case .section: "§\(i)§"
            case .square: "[[\(i)]]"
            case .tag: "<x\(i)/>"
            case .word: "QZX\(i)Q"
            }
        }
        var tokenPattern: String {
            switch self {
            case .brackets: "⟦(\\d+)⟧"
            case .section: "§(\\d+)§"
            case .square: "\\[\\[(\\d+)\\]\\]"
            case .tag: "<x(\\d+)/>"
            case .word: "QZX(\\d+)Q"
            }
        }
    }

    nonisolated(unsafe) public static var defaultFormat: Format = .tag

    public struct Masked: Sendable {
        public let text: String
        public let entities: [Entity]
        public let format: Format

        /// Original text with every placeholder replaced back. nil when a placeholder is missing, repeated or invented.
        public func restore(_ translated: String) -> String? {
            guard !entities.isEmpty else { return translated }
            guard let re = try? NSRegularExpression(pattern: format.tokenPattern) else { return nil }
            let ns = translated as NSString
            let matches = re.matches(in: translated, range: NSRange(location: 0, length: ns.length))
            var seen = Set<Int>()
            for m in matches {
                guard let n = Int(ns.substring(with: m.range(at: 1))), n >= 1, n <= entities.count, seen.insert(n).inserted else { return nil }
            }
            guard seen.count == entities.count else { return nil }
            var out = translated
            for m in matches.reversed() {
                let n = Int(ns.substring(with: m.range(at: 1)))!
                out = (out as NSString).replacingCharacters(in: m.range, with: entities[n - 1].original)
            }
            return out
        }

        /// Longest prefix-safe description for logs.
        public var summary: String { entities.map { "\($0.kind.rawValue):\($0.original.prefix(40))" }.joined(separator: " | ") }
    }

    // MARK: - Patterns (priority order: earlier wins on overlap)

    private static let fieldWords = "seatbid|bidfloor|bidfloorcur|bidid|impid|adomain|nurl|burl|lurl|crid|tmax|bcat|badv|ifa|cattax|ortb|openrtb|vast|vpaid|vmap"
    private static let patterns: [(Kind, String)] = [
        (.code, "```[\\s\\S]*?```"),
        (.code, "`[^`\\n]+`"),
        (.mention, "<[@#!][^>\\s]+>"),
        (.link, "<https?://[^>\\s]+>"),
        (.link, "(?:https?|ftp)://[^\\s<>\"«»]+"),
        (.link, "\\bwww\\.[^\\s<>\"«»]+"),
        (.email, "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}"),
        (.macro, "\\$\\{[^}\\s]+\\}"),
        (.macro, "\\{\\{[^}\\n]+\\}\\}"),
        (.macro, "%%[A-Za-z0-9_.:-]+%%"),
        (.macro, "%[A-Z][A-Z0-9_]{2,}%"),
        (.macro, "\\b__[A-Z0-9_]+__\\b"),
        (.macro, "\\{[A-Za-z_][A-Za-z0-9_.:-]*\\}"),
        (.macro, "\\[(?:[A-Z][A-Z0-9_]+|[a-z][a-z0-9_]*)\\]"),
        (.macro, "\\$[A-Z_][A-Z0-9_]{2,}\\b"),
        (.mention, "(?<![\\w@])@(?:channel|here|everyone)\\b"),
        (.mention, "(?<![\\w@.])@[A-Za-z0-9_][A-Za-z0-9_.-]{1,30}[A-Za-z0-9_]"),
        (.ticket, "\\b[A-Z][A-Z0-9]{1,9}-\\d{1,7}\\b"),
        (.path, "(?<![\\w/.:])~?/(?:[\\w.-]+/)+[\\w.-]+"),
        (.field, "\\b[a-z_][a-z0-9_]*(?:\\[\\d+\\])?(?:\\.[a-z_][a-z0-9_]*(?:\\[\\d+\\])?)+\\b"),
        (.field, "\\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\\b"),
        (.field, "\\b(?:\(fieldWords))\\b"),
        (.id, "\\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\\b"),
        (.id, "\\b[0-9a-fA-F]{16,}\\b"),
        (.id, "\\b(?=[A-Za-z0-9_-]*\\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{20,}\\b"),
    ]
    private static let compiled: [(Kind, NSRegularExpression)] = patterns.compactMap { k, p in
        (try? NSRegularExpression(pattern: p)).map { (k, $0) }
    }

    /// «e.g.», «i.e.» and friends look like dotted field paths but are words.
    private static let notFields: Set<String> = ["e.g", "i.e", "e.g.", "i.e.", "a.m", "p.m", "etc", "vs"]
    private static let trailingPunct = CharacterSet(charactersIn: ".,;:!?)]}»\"'…")

    public static func mask(_ text: String, format: Format? = nil) -> Masked {
        let format = format ?? defaultFormat
        let ns = text as NSString
        var taken: [(range: NSRange, kind: Kind)] = []
        func overlaps(_ r: NSRange) -> Bool { taken.contains { NSIntersectionRange($0.range, r).length > 0 } }
        for (kind, re) in compiled {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var r = m.range
                if kind == .link || kind == .path {
                    // Sentence punctuation after a link is not part of it; a closing ")" stays if its "(" is inside.
                    while r.length > 1 {
                        let s = ns.substring(with: r)
                        guard let last = s.unicodeScalars.last, trailingPunct.contains(last) else { break }
                        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
                        if let open = pairs[Character(last)], s.filter({ $0 == open }).count >= s.filter({ $0 == Character(last) }).count { break }
                        r.length -= 1
                    }
                }
                if kind == .field {
                    let s = ns.substring(with: r).lowercased()
                    if notFields.contains(s) || s.hasPrefix("e.g") || s.hasPrefix("i.e") { continue }
                    // A sentence glued without a space after the full stop is not a field path.
                    if r.length > 0, ns.substring(with: r).first?.isNumber == true { continue }
                }
                if overlaps(r) { continue }
                taken.append((r, kind))
            }
        }
        guard !taken.isEmpty else { return Masked(text: text, entities: [], format: format) }
        taken.sort { $0.range.location < $1.range.location }
        var entities: [Entity] = []
        var out = ""
        var cursor = 0
        // One placeholder per occurrence (never shared): validation is «each exactly once».
        for t in taken {
            out += ns.substring(with: NSRange(location: cursor, length: t.range.location - cursor))
            let original = ns.substring(with: t.range)
            let token = format.token(entities.count + 1)
            entities.append(Entity(token: token, original: original, kind: t.kind))
            out += token
            cursor = t.range.location + t.range.length
        }
        out += ns.substring(from: cursor)
        return Masked(text: out, entities: entities, format: format)
    }

    /// One system-prompt paragraph that explains the placeholders to the model.
    public static func promptNote(example: String) -> String {
        "The text contains protected placeholders such as \(example). They stand for links, macros, code, ids and other fragments that must not change. Copy every placeholder into the translation exactly as written, exactly once, at the natural place in the sentence. Never translate, change, split, drop, add or repeat them."
    }
}
