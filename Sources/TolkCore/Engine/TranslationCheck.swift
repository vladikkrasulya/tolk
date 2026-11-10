// Automatic check of a finished translation: did numbers, links and identifiers survive, and is the text in the
// target language? Pure function, no model, no network. Problems are returned as short Russian phrases for the
// status line. It must stay quiet on ordinary text: numbers written as words are not checked, small integers
// that a translation may spell out («2 kids» → «двое детей») are not checked, separators/currency position are tolerated.
import Foundation
import NaturalLanguage

public enum TranslationCheck {
    /// Problems found (empty = nothing suspicious). At most 3.
    public static func warnings(source: String, translation: String, from: Language, to: Language) -> [String] {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !dst.isEmpty else { return [] }
        var out: [String] = []

        let a = Extracted(src, isSource: true)
        let b = Extracted(dst, isSource: false)
        let dstLower = normalizeForSearch(dst)

        for u in a.urls where !dstLower.contains(normalizeURL(u)) {
            out.append("потеряна ссылка \(shorten(u))")
        }
        for e in a.emails where !dstLower.contains(e.lowercased()) {
            out.append("потерян e-mail \(shorten(e))")
        }
        for h in a.handles where !dstLower.contains(h.lowercased()) {
            out.append("потеряно упоминание \(shorten(h))")
        }
        for id in a.ids where !dstLower.contains(id.lowercased()) {
            out.append("потерян идентификатор \(shorten(id))")
        }
        for t in a.times where !b.hasTime(t) {
            out.append("в переводе нет времени \(t.display)")
        }
        for y in a.dateYears where !b.numberSet.contains(y.canonical) {
            out.append("в переводе нет даты \(y.display)")
        }
        for n in a.numbers where n.alts.isDisjoint(with: b.numberSet) {
            out.append("в переводе нет числа \(n.display)")
        }
        if let lang = wrongLanguage(translation: dst, source: src, target: to, from: from) { out.append(lang) }

        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    // MARK: - Extraction

    struct Number { let display: String; let alts: Set<String>; let canonical: String }
    struct Time { let display: String; let h24: Int; let h12: Int; let minute: Int }

    struct Extracted {
        var urls: [String] = []
        var emails: [String] = []
        var handles: [String] = []
        var ids: [String] = []
        var times: [Time] = []
        var dateYears: [Number] = []
        var numbers: [Number] = []          // source: required numbers
        var numberSet = Set<String>()       // translation: every canonical form present
        private var timeSet = Set<String>() // "h:mm" in any plausible reading

        func hasTime(_ t: Time) -> Bool {
            if timeSet.contains("\(t.h24):\(t.minute)") || timeSet.contains("\(t.h12):\(t.minute)") { return true }
            // «в 14 часов», «в 8 вечера»: bare hour is fine for a round time.
            if t.minute == 0, numberSet.contains(String(t.h24)) || numberSet.contains(String(t.h12)) { return true }
            return false
        }

        init(_ text: String, isSource: Bool) {
            var work = text.replacingOccurrences(of: "＠", with: "@")
            /// Finds matches, hands each to `handle`; when it returns true the span is blanked out so that
            /// later passes (numbers) do not see it.
            func take(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive],
                      _ handle: (String) -> Bool) {
                guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
                let ns = work as NSString
                var blank = work
                for m in re.matches(in: work, range: NSRange(location: 0, length: ns.length)).reversed() {
                    if handle(ns.substring(with: m.range)) {
                        blank = (blank as NSString).replacingCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
                    }
                }
                work = blank
            }
            let trimSet = CharacterSet(charactersIn: ".,;:!?)]}»”’'\"")
            take(#"(?:https?://|www\.)[^\s<>"«»]+"#) { s in
                let u = s.trimmingCharacters(in: trimSet)
                if !u.isEmpty { urls.append(u) }
                return true
            }
            take(#"[A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)+"#) { s in
                emails.append(s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))); return true
            }
            take(#"(?<![\p{L}\p{N}_])@[\p{L}\p{N}_][\p{L}\p{N}_.]+"#) { s in
                handles.append(s.trimmingCharacters(in: CharacterSet(charactersIn: "."))); return true
            }
            // Links without a scheme: example.com/path
            take(#"(?<![\p{L}\p{N}@.])[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.(?:com|net|org|io|ua|ru|app|dev|co|me|ly|info|eu)(?:/[^\s<>"«»]*)?"#) { s in
                urls.append(s.trimmingCharacters(in: trimSet)); return true
            }
            // ID-like tokens: letters + digits (A-12345, COVID-19, order2024x); not "10am" / "5th" / plain numbers.
            take(#"(?<![\p{L}\p{N}_\-])[A-Za-z0-9][A-Za-z0-9_\-]{3,}(?![\p{L}\p{N}_])"#, options: []) { s in
                guard s.contains(where: \.isNumber), s.contains(where: \.isLetter) else { return false }
                guard s.first!.isLetter || s.contains("-") || s.contains("_") else { return false }
                ids.append(s); return true
            }
            if isSource {
                // 8 pm, 2:30 p.m.
                take(#"(?<![\d:.])\d{1,2}(?::\d{2})?\s?(?:a\.?m\.?|p\.?m\.?)(?![\p{L}])"#) { s in
                    let p = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                    guard let h = p.first else { return false }
                    let pm = s.lowercased().contains("p")
                    times.append(Time(display: s.trimmingCharacters(in: .whitespaces), h24: (h % 12) + (pm ? 12 : 0),
                                      h12: h == 0 ? 12 : h, minute: p.count > 1 ? p[1] : 0))
                    return true
                }
                // 14:30
                take(#"(?<![\d:.,])(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?![\d:])"#) { s in
                    let p = s.split(separator: ":").compactMap { Int($0) }
                    guard p.count >= 2 else { return false }
                    times.append(Time(display: s, h24: p[0], h12: p[0] % 12 == 0 ? 12 : p[0] % 12, minute: p[1]))
                    return true
                }
                // Dates in digits: only the year is checked (order and format change in translation).
                take(#"(?<![\d.])(?:\d{1,2}[./-]\d{1,2}[./-]\d{4}|\d{4}[./-]\d{1,2}[./-]\d{1,2})(?![\d])"#) { s in
                    guard let year = s.split(whereSeparator: { !$0.isNumber }).first(where: { $0.count == 4 }).map(String.init) else { return false }
                    dateYears.append(Number(display: s, alts: [year], canonical: year))
                    return true
                }
            } else {
                // Times in the translation: 14:30, 14.30, 8:30 PM.
                if let re = try? NSRegularExpression(pattern: #"(?<![\d:.,])(\d{1,2})[:.](\d{2})(?![\d])\s?(a\.?m\.?|p\.?m\.?)?"#, options: [.caseInsensitive]) {
                    let ns = work as NSString
                    for m in re.matches(in: work, range: NSRange(location: 0, length: ns.length)) {
                        var h = Int(ns.substring(with: m.range(at: 1))) ?? 0
                        let mn = Int(ns.substring(with: m.range(at: 2))) ?? 0
                        if m.range(at: 3).location != NSNotFound {
                            let pm = ns.substring(with: m.range(at: 3)).lowercased().contains("p")
                            h = (h % 12) + (pm ? 12 : 0)
                        }
                        timeSet.insert("\(h):\(mn)")
                        timeSet.insert("\(h % 12 == 0 ? 12 : h % 12):\(mn)")
                    }
                }
            }
            collectNumbers(work, isSource: isSource, original: text)
        }

        private mutating func collectNumbers(_ s: String, isSource: Bool, original: String) {
            let pattern = #"(?<![\p{L}\p{N}_])\d{1,3}(?:[ \x{00A0}\x{202F}',.’]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range)
                var alts = Self.canonical(raw)
                guard !alts.isEmpty else { continue }
                alts.formUnion(Self.scaled(alts, suffix: ns.substring(from: m.range.location + m.range.length)))
                if isSource {
                    if Self.isTrivial(raw, in: ns, range: m.range) { continue }
                    numbers.append(Number(display: raw, alts: alts, canonical: alts.first!))
                } else {
                    numberSet.formUnion(alts)
                }
            }
        }

        /// Canonical forms of "8 416,20" / "8,416.20" / "1.500" ("1500" or "1.5": ambiguous -> both).
        static func canonical(_ raw: String) -> Set<String> {
            let t = raw.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "’", with: "'")
            let seps = CharacterSet(charactersIn: " ',.")
            let chars = Array(t)
            guard let lastSep = chars.lastIndex(where: { $0.unicodeScalars.allSatisfy(seps.contains) }) else {
                return [stripZeros(t)]
            }
            let head = String(chars[..<lastSep]).filter(\.isNumber)
            let frac = String(chars[(lastSep + 1)...])
            let lastIsDecimalChar = chars[lastSep] == "." || chars[lastSep] == ","
            let otherSeps = chars[..<lastSep].contains(where: { seps.contains($0.unicodeScalars.first!) })
            func decimal() -> String {
                let f = frac.reversed().drop(while: { $0 == "0" }).reversed()
                return f.isEmpty ? stripZeros(head) : stripZeros(head) + "." + String(f)
            }
            let thousands = head + frac
            if frac.count == 3 && frac.allSatisfy(\.isNumber) {
                // 1,500 / 1.500 / 1 500: thousands; but «0.500», «1.500» may also be a decimal.
                if chars[lastSep] == " " || chars[lastSep] == "'" || otherSeps { return [stripZeros(thousands)] }
                return head.hasPrefix("0") || head.isEmpty ? [decimal()] : [stripZeros(thousands), decimal()]
            }
            if !lastIsDecimalChar { return [stripZeros(thousands)] }
            return [decimal()]
        }

        /// «50k» / «1.2M» / «50 тыс.» are the same as 50000 / 1200000: add the expanded value as an alternative.
        static func scaled(_ alts: Set<String>, suffix: String) -> Set<String> {
            guard let re = try? NSRegularExpression(pattern: #"^\s?(k|к|m|м|b|тыс|млн|млрд|цент\p{L}*|cents?|коп\p{L}*)(?![\p{L}])"#, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length)) else { return [] }
            var unit = (suffix as NSString).substring(with: m.range(at: 1)).lowercased()
            if unit.hasPrefix("цент") || unit.hasPrefix("cent") || unit.hasPrefix("коп") { unit = "cent" }
            let factor: Decimal = ["cent": Decimal(string: "0.01")!, "k": 1_000, "к": 1_000, "тыс": 1_000, "m": 1_000_000, "м": 1_000_000, "млн": 1_000_000,
                                   "b": 1_000_000_000, "млрд": 1_000_000_000][unit] ?? 1
            return Set(alts.compactMap { Decimal(string: $0) }.map { NSDecimalNumber(decimal: $0 * factor).stringValue })
        }

        static func stripZeros(_ s: String) -> String {
            let d = s.drop(while: { $0 == "0" })
            return d.isEmpty ? "0" : String(d)
        }

        /// Small integers are often spelled out in a translation («2 kids» → «двое детей»): not checked,
        /// unless attached to %, currency or a time.
        static func isTrivial(_ raw: String, in ns: NSString, range: NSRange) -> Bool {
            guard raw.allSatisfy(\.isNumber), let v = Int(raw), v <= 12 else { return false }
            let after = ns.substring(from: range.location + range.length).prefix(6).lowercased()
            let before = ns.substring(to: range.location).suffix(2)
            let marks: [Character] = ["%", "$", "€", "£", "₴", "₽", "¥"]
            if let f = after.trimmingCharacters(in: .whitespaces).first, marks.contains(f) { return false }
            if let l = before.last, marks.contains(l) { return false }
            let t = after.trimmingCharacters(in: .whitespaces)
            for w in ["usd", "eur", "uah", "rub", "gbp", "грн", "руб", "долл", "евро", "грив"] where t.hasPrefix(w) { return false }
            return true
        }
    }

    // MARK: - Language

    static func wrongLanguage(translation: String, source: String, target: Language, from: Language) -> String? {
        let text = Extracted.stripNonProse(translation)
        let letters = text.filter(\.isLetter)
        guard letters.count >= 12 else { return nil }
        var cyr = 0, lat = 0, ukMarks = 0, ruMarks = 0, other = 0
        for u in letters.unicodeScalars {
            switch u.value {
            case 0x0400...0x04FF:
                cyr += 1
                switch u {
                case "і", "І", "ї", "Ї", "є", "Є", "ґ", "Ґ": ukMarks += 1
                case "ы", "Ы", "э", "Э", "ъ", "Ъ", "ё", "Ё": ruMarks += 1
                default: break
                }
            case 0x41...0x24F: lat += 1
            default: other += 1
            }
        }
        let total = Double(cyr + lat + other)
        let cyrTargets: Set<Language> = [.russian, .ukrainian, .bulgarian, .kazakh]
        let latinTargets: Set<Language> = [.english, .german, .french, .spanish, .italian, .portuguese, .polish, .czech,
                                           .dutch, .romanian, .turkish, .indonesian, .vietnamese]
        if cyrTargets.contains(target) {
            if Double(lat) / total > 0.6 { return "перевод не на том языке: латиница вместо \(target.russianName)" }
            if other > 0, Double(other) / total > 0.5 { return "перевод не на том языке: другой алфавит вместо \(target.russianName)" }
            if target == .ukrainian, ruMarks >= 2, ukMarks == 0 { return "перевод не на том языке: русский вместо украинского" }
            if target == .russian, ukMarks >= 2, ruMarks == 0 { return "перевод не на том языке: украинский вместо русского" }
        } else if latinTargets.contains(target) {
            if Double(cyr) / total > 0.5 { return "перевод не на том языке: кириллица вместо \(target.russianName)" }
            if Double(other) / total > 0.5 { return "перевод не на том языке: другой алфавит вместо \(target.russianName)" }
        } else {
            // CJK, Arabic, Hebrew, Georgian, Hindi: need mostly non-Latin, non-Cyrillic letters.
            if Double(other) / total < 0.3 { return "перевод не на том языке: нужен \(target.russianName)" }
        }
        // NaturalLanguage for longer Latin/Cyrillic texts.
        guard letters.count >= 40, target != from else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        let h = r.languageHypotheses(withMaximum: 4)
        let want = NLLanguage(rawValue: target == .chinese ? "zh-Hans" : target.rawValue)
        guard let (best, p) = h.max(by: { $0.value < $1.value }), best != want, p >= 0.7, (h[want] ?? 0) < 0.15 else { return nil }
        // Closely related pairs are only trusted with a Cyrillic marker (handled above); skip them here.
        let close: [Set<NLLanguage>] = [[.russian, .ukrainian, .bulgarian, .kazakh], [.czech, .slovak], [.indonesian, .malay], [.spanish, .portuguese, .catalan]]
        if close.contains(where: { $0.contains(best) && $0.contains(want) }) { return nil }
        guard let found = Language.allCases.first(where: { NLLanguage(rawValue: $0 == .chinese ? "zh-Hans" : $0.rawValue) == best }) else { return nil }
        return "перевод не на том языке: \(found.russianName) вместо \(target.russianName)"
    }

    // MARK: - Helpers

    static func normalizeURL(_ u: String) -> String {
        var s = u.lowercased()
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func normalizeForSearch(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: "＠", with: "@")
        t = t.replacingOccurrences(of: "https://www.", with: "").replacingOccurrences(of: "http://www.", with: "")
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        return t
    }

    static func shorten(_ s: String) -> String { s.count > 40 ? String(s.prefix(38)) + "…" : s }
}

extension TranslationCheck.Extracted {
    /// Text without links, e-mails, @handles and ID-like tokens (they say nothing about the language).
    static func stripNonProse(_ text: String) -> String {
        var t = text
        for p in [#"(?:https?://|www\.)\S+"#, #"\S+@\S+\.\S+"#, #"[@＠]\w+"#, #"\{[^}\s]*\}"#] {
            t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        let words = t.split(whereSeparator: \.isWhitespace).filter { w in
            !(w.contains { $0.isNumber } || w.contains("=") || w.contains("_") || w.contains("/"))
        }
        return words.joined(separator: " ")
    }
}
