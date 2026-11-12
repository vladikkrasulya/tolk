// Glossary for the fallback translators (Google, Apple). They take no instructions, so the terms are put into the
// text itself before it is sent: «raise the floor» goes out as «raise the флор», and the translator builds the
// sentence around the word (it usually even inflects it: «снизим флор», «от этих паблишеров»).
//
// Measured on work phrases (2026-11-12): this fixed «лимит → капа», «лента → фид», «нижний предел → флор»,
// «пабов → паблишеров», but now and then the translator mangles an inserted word («расхождение» came back as
// «передвижение»). So every inserted term is looked for in the answer; the ones that did not survive are taken
// out and the text is translated again; if that fails too, the plain translation is used. At most three requests.
//
// OFF by default. On nine work phrases five came out better, two the same, and in two the translator garbled a
// word NEXT to an inserted term («Your account was suspended because of фрод» → «аккаунт был причинён из-за фрода»).
// A back-translation check was tried and did not catch it (both versions come back equally close to the original),
// so there is no automatic guard: the switch is for those who prefer the right terms and reread the result.
import Foundation

public enum FallbackGlossary {
    struct Sub: Sendable, Equatable {
        let range: NSRange
        let insert: String      // what goes into the text (may be a plural of `term`)
        let term: String        // the glossary rendering, as written in the rules file
    }

    /// Glossary terms go only into Russian and English: the glossary is written for this pair, and a Russian term
    /// inside a Ukrainian or Polish sentence is a mistake the fallback translator cannot repair.
    static func applies(to target: Language) -> Bool { target == .russian || target == .english }

    static func plan(_ text: String, pairs: [(from: String, to: String)], target: Language) -> [Sub] {
        guard applies(to: target) else { return [] }
        let ns = text as NSString
        let wantCyrillic = target == .russian
        var subs: [Sub] = []
        // Longer English terms first («daily cap» before «cap»). Russian forms the other way round: «паблишеру» fits
        // both «паблишер → publisher» and «паблишеры → pubs», and the dictionary form is the shorter one.
        let ordered = pairs.sorted { a, b in
            let (ac, bc) = (RulesStore.isMostlyCyrillic(a.from), RulesStore.isMostlyCyrillic(b.from))
            if ac && bc && a.from.split(separator: " ").count == b.from.split(separator: " ").count { return a.from.count < b.from.count }
            return a.from.count > b.from.count
        }
        for p in ordered {
            // «Добрый день! → Hello,» is a hint about a whole phrase with its punctuation; put in as a word it ate the «!».
            guard isPlainTerm(p.from), isPlainTerm(p.to),
                  p.from.lowercased() != p.to.lowercased(), RulesStore.isMostlyCyrillic(p.to) == wantCyrillic,
                  RulesStore.isMostlyCyrillic(p.from) != wantCyrillic, let re = RulesStore.pattern(for: p.from) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let found = ns.substring(with: m.range)
                guard !subs.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }),
                      var ins = rendering(found: found, from: p.from, to: p.to) else { continue }
                if let f = found.first, f.isUppercase, startsSentence(ns, at: m.range.location) { ins = capitalized(ins) }
                subs.append(Sub(range: m.range, insert: ins, term: p.to))
            }
        }
        return subs.sorted { $0.range.location < $1.range.location }
    }

    /// Letters, digits, spaces, hyphens and apostrophes only.
    static func isPlainTerm(_ s: String) -> Bool {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -'’"))
        return !s.isEmpty && s.unicodeScalars.allSatisfy(ok.contains)
    }

    /// The word to insert for the form found in the text; nil = leave this place to the translator.
    /// English: the base form and a plain plural only — «capped», «pausing» are verbs, a noun would break the sentence.
    static func rendering(found: String, from: String, to: String) -> String? {
        guard !RulesStore.isMostlyCyrillic(from) else { return to }   // Russian form → English term as is
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: "[\\s-]+", with: " ", options: .regularExpression) }
        let f = norm(found), base = norm(from)
        if f == base { return to }
        let plurals = [base + "s", base + "es"] + (base.hasSuffix("y") ? [String(base.dropLast()) + "ies"] : [])
        return plurals.contains(f) ? plural(to) : nil
    }

    /// «постбек → постбеки», «капа → капы», «пиксель → пиксели»; nil when the rule is not obvious (phrases, -о/-е words).
    static func plural(_ word: String) -> String? {
        guard !word.contains(" "), RulesStore.isMostlyCyrillic(word), word.count >= 3, let last = word.last else { return nil }
        let soft: Set<Character> = ["к", "г", "х", "ж", "ш", "ч", "щ"]
        let stem = String(word.dropLast())
        switch last {
        case "а": return stem + (stem.last.map(soft.contains) == true ? "и" : "ы")
        case "я", "ь", "й": return stem + "и"
        case "о", "е", "ё", "и", "ы", "у", "ю", "э": return nil
        default: return word + (soft.contains(last) ? "и" : "ы")
        }
    }

    static func apply(_ text: String, _ subs: [Sub]) -> String {
        let ns = NSMutableString(string: text)
        for s in subs.sorted(by: { $0.range.location > $1.range.location }) { ns.replaceCharacters(in: s.range, with: s.insert) }
        return ns as String
    }

    /// Did the term survive the translation? Every word of it is looked for by its stem, so an inflected form counts.
    static func kept(_ output: String, term: String) -> Bool {
        term.split(separator: " ").allSatisfy { w in
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: stem(String(w))),
                                                    options: [.caseInsensitive]) else { return true }
            return re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
        }
    }

    static func stem(_ word: String) -> String {
        let w = word.lowercased()
        if RulesStore.isMostlyCyrillic(w) { return RulesStore.cyrillicStem(w) }
        return w.count > 3 && (w.hasSuffix("e") || w.hasSuffix("y")) ? String(w.dropLast()) : w
    }

    /// The translator sometimes returns an inserted word with a stray capital («удерживать Выплаты») or leaves it
    /// lower-case at the start of a sentence. Only words that begin with a glossary term written in lower case.
    static func fixCase(_ output: String, terms: [String]) -> String {
        let ns = NSMutableString(string: output)
        for term in Set(terms) {
            guard let first = term.split(separator: " ").first, let c = first.first, c.isLowercase, stem(String(first)).count >= 4,
                  let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: stem(String(first))) + "\\p{L}*",
                                                    options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: m.range)
                guard word != word.uppercased() || word.count == 1 else { continue }   // an abbreviation stays
                let head = NSRange(location: m.range.location, length: 1)
                let letter = ns.substring(with: head)
                let want = startsSentence(ns, at: m.range.location) ? letter.uppercased() : letter.lowercased()
                if want != letter, (want as NSString).length == 1 { ns.replaceCharacters(in: head, with: want) }
            }
        }
        return ns as String
    }

    static func startsSentence(_ ns: NSString, at location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            guard let u = Unicode.Scalar(ns.character(at: i)) else { return false }
            if CharacterSet.whitespaces.contains(u) || "\"«“'(".unicodeScalars.contains(u) { i -= 1; continue }
            return ".!?…\n".unicodeScalars.contains(u)
        }
        return true
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func collect(_ s: AsyncThrowingStream<String, Error>) async throws -> String {
        var out = ""
        for try await chunk in s { try Task.checkCancellation(); out += chunk }
        return out
    }

    public static func stream(_ r: ResolvedRequest, provider: TranslationProvider, rules: RulesStore,
                              enabled: Bool) -> AsyncThrowingStream<String, Error> {
        guard enabled, r.mode == .translate else { return provider.translate(r) }
        let all = plan(r.text, pairs: rules.glossaryPairs(in: r.text, target: r.target), target: r.target)
        guard !all.isEmpty else { return provider.translate(r) }
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    var active = all
                    for _ in 0..<2 where !active.isEmpty {
                        var req = r
                        req.text = apply(r.text, active)
                        let out = try await collect(provider.translate(req))
                        let lost = Set(active.filter { !kept(out, term: $0.term) }.map(\.term))
                        if lost.isEmpty {
                            EngineLog.write("fallback glossary: \(provider.name) terms \(active.count) of \(all.count)")
                            c.yield(fixCase(out, terms: active.map(\.term))); c.finish(); return
                        }
                        active.removeAll { lost.contains($0.term) }
                    }
                    EngineLog.write("fallback glossary: \(provider.name) terms 0 of \(all.count), plain translation")
                    c.yield(try await collect(provider.translate(r))); c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}
