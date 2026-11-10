// Typo autocorrect for the autocomplete: when a word has just been finished (space or punctuation
// typed after it) and NSSpellChecker is sure it is misspelled, offers the fix as an instant suggestion.
// Tab / → replace "word + separator" with "fix + separator". Esc / typing on leaves the word alone; after 3 refusals in a row it is not offered again (until Tolk quits).
import AppKit
import TolkCore

@MainActor
final class Autocorrect: InstantSuggestionProvider {
    /// Words never corrected: adtech slang (always) + terms from the user's glossary file.
    private var ignored: Set<String> = Autocorrect.builtinSlang
    /// Refusals per word (Esc, or typed on past the suggestion). A word is silenced only after 3 refusals in a row
    /// (a fix that was taken resets the count); the silenced list is capped at 200 and lives until Tolk quits,
    /// never stored: typing on once is not a decision, so one miss must not silence a word.
    private var rejections = AutocompleteSafety.RejectionTracker(threshold: 3, capacity: 200)
    /// word(lowercased) → flagged by the English checker (for the translit guard).
    private var englishMisspelled: [String: Bool] = [:]
    /// word(lowercased) → fix, "" = nothing to fix.
    private var cache: [String: String] = [:]
    /// The last suggestion we returned (to notice an implicit Esc, see `suggestion(for:)`).
    private var offered: (textBefore: String, word: String)?
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()

    init(rulesPath: String) {
        ignored.formUnion(Autocorrect.glossaryTerms(path: rulesPath))
        UserDefaults.standard.removeObject(forKey: "autocorrectRejectedWords")  // hidden permanent list of 0.6.x
    }

    // MARK: - InstantSuggestionProvider

    func suggestion(for field: FocusedField) -> InstantSuggestion? {
        // Esc detection without a controller hook: after Esc the typo is still in the text and the
        // provider is asked again (the user typed on). After Tab it is gone (replaced by the fix).
        if let o = offered {
            if field.textBefore.hasPrefix(o.textBefore) { rejections.reject(o.word) } else { rejections.accepted(o.word) }
            offered = nil
        }
        guard let (word, sep) = Autocorrect.lastFinishedWord(in: field.textBefore) else { return nil }
        let key = word.lowercased()
        guard !rejections.isSilenced(key), !ignored.contains(key) else { return nil }
        let head = String(field.textBefore.dropLast(word.count + sep.count))
        // A word already used earlier in this text is the user's own (name, slang), not a typo.
        if Autocorrect.occursEarlier(key, in: head) { return nil }
        // Capitalized in the middle of a sentence: a name or a brand.
        if word.first!.isUppercase, !Autocorrect.atSentenceStart(head) { return nil }
        // Russian/Ukrainian typed in Latin letters ("privet, kak dela"): the English checker flags every word.
        if script(of: key) == .latin, looksLikeTranslit(head) { return nil }
        guard let fix = fix(for: word) else { return nil }
        offered = (field.textBefore, word)
        return InstantSuggestion(replaceCount: word.count + sep.count, text: fix + sep,
                                 display: "→ " + fix, blocksModel: true)
    }

    // MARK: - Word extraction

    private static let separators: Set<Character> = [" ", ",", ".", "!", "?", ";", ":", ")", "\u{00A0}"]

    /// The word right before the caret plus the one separator after it, or nil if the caret is not right after "word<sep>".
    static func lastFinishedWord(in text: String) -> (word: String, sep: String)? {
        guard let sepChar = text.last, separators.contains(sepChar) else { return nil }
        var rest = text.dropLast()
        var word = ""
        while let c = rest.last, c.isLetter || c == "'" || c == "’" || c == "-" {
            word.insert(c, at: word.startIndex)
            rest = rest.dropLast()
        }
        // A word glued to digits, @, #, /, _, ., etc. is an identifier / link / handle, not prose.
        if let before = rest.last, !(before.isWhitespace || "([{«\"“,;:!?—–".contains(before)) { return nil }
        guard word.count >= 3, word.first!.isLetter, word.last!.isLetter else { return nil }
        // "foo.bar" typed as a domain: sep "." with something non-space coming later is not detectable; fine.
        return (word, String(sepChar))
    }

    /// `head` is the text before a word: true when that word starts the text, a line or a sentence.
    static func atSentenceStart(_ head: String) -> Bool {
        var rest = Substring(head)
        while let c = rest.last, c == " " || c == "\t" || c == "\u{00A0}" || "\"“«([".contains(c) { rest = rest.dropLast() }
        guard let last = rest.last else { return true }
        return last.isNewline || ".!?…".contains(last)
    }

    /// Two or more of the last six Latin words before the caret are not English (and not slang or glossary terms).
    private func looksLikeTranslit(_ head: String) -> Bool {
        var words: [String] = []
        var cur = ""
        func flush() {
            let w = cur.lowercased()
            if w.count >= 3, script(of: w) == .latin { words.append(w) }
            cur = ""
        }
        for ch in head.suffix(120) { if ch.isLetter { cur.append(ch) } else { flush() } }
        flush()
        var unknown = 0
        for w in words.suffix(6) where !ignored.contains(w) {
            let bad: Bool
            if let b = englishMisspelled[w] { bad = b } else {
                bad = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                          inSpellDocumentWithTag: tag, wordCount: nil).location != NSNotFound
                englishMisspelled[w] = bad
            }
            if bad { unknown += 1 }
        }
        return unknown >= 2
    }

    static func occursEarlier(_ key: String, in text: String) -> Bool {
        var cur = ""
        func hit() -> Bool { defer { cur = "" }; return cur.lowercased() == key }
        for ch in text {
            if ch.isLetter || ch == "'" || ch == "’" || ch == "-" { cur.append(ch) } else if hit() { return true }
        }
        return hit()
    }

    // MARK: - Checking

    private enum Script { case latin, cyrillic, other }

    private func script(of word: String) -> Script {
        var latin = false, cyr = false
        for u in word.unicodeScalars where CharacterSet.letters.contains(u) {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A: latin = true
            case 0x400...0x4FF: cyr = true
            default: return .other
            }
        }
        if latin && cyr { return .other }
        return latin ? .latin : (cyr ? .cyrillic : .other)
    }

    private func fix(for word: String) -> String? {
        // Skip: digits, CamelCase / ALL CAPS, anything not a plain EN/RU/UK word.
        // Hyphenated compounds are checked as one word by the system and get fixed into something else.
        guard !word.contains(where: { $0.isNumber || $0 == "-" }) else { return nil }
        let letters = word.filter { $0.isLetter }
        let upperTail = letters.dropFirst().contains(where: { $0.isUppercase })
        if upperTail { return nil }
        let key = word.lowercased()
        let fixed: String
        if let c = cache[key] {
            fixed = c
        } else {
            fixed = Autocorrect.contractions[key] ?? computeFix(key) ?? ""
            cache[key] = fixed
        }
        if fixed.isEmpty { return nil }
        // Keep the case of the original: "Teh" → "The".
        if word.first!.isUppercase { return fixed.prefix(1).uppercased() + fixed.dropFirst() }
        return fixed
    }

    /// Fix for a lowercased word, nil when it is fine or no confident fix exists.
    private func computeFix(_ w: String) -> String? {
        let sc = script(of: w)
        let langs: [String]
        switch sc {
        case .latin: langs = ["en"]
        case .cyrillic:
            let ukOnly = w.contains(where: { "іїєґ".contains($0) })
            let ruOnly = w.contains(where: { "ыэъё".contains($0) })
            langs = ukOnly ? ["uk"] : (ruOnly ? ["ru"] : ["ru", "uk"])  // ambiguous: right in either → fine
        case .other: return nil
        }
        let checker = NSSpellChecker.shared
        let ns = w as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Misspelled only if every candidate language flags it.
        for lang in langs {
            let r = checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                          inSpellDocumentWithTag: tag, wordCount: nil)
            if r.location == NSNotFound { return nil }
        }
        let lang = langs[0]
        var candidates: [String] = []
        if let c = checker.correction(forWordRange: full, in: w, language: lang, inSpellDocumentWithTag: tag) { candidates.append(c) }
        candidates += checker.guesses(forWordRange: full, in: w, language: lang, inSpellDocumentWithTag: tag) ?? []
        for cand in candidates.prefix(3) {
            let c = cand.lowercased()
            guard c != w, !c.contains(" "), !cand.dropFirst().contains(where: { $0.isUppercase }),
                  script(of: c) == sc else { continue }
            // Never change the first letter (or add/drop a char at the start).
            guard c.first == w.first else { continue }
            let d = Autocorrect.editDistance(Array(w), Array(c))
            if w.count <= 5 {
                // Short words: one substitution or one adjacent swap only (same length), no insert/delete.
                if d == 1 && c.count == w.count { return c }
            } else if d == 1 || d == 2 && w.count >= 8 {
                return c
            }
        }
        return nil
    }

    /// English contractions typed without the apostrophe; the spell checker offers other words for them ("dont" → "done").
    static let contractions: [String: String] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "cant": "can't", "wont": "won't", "isnt": "isn't",
        "arent": "aren't", "wasnt": "wasn't", "werent": "weren't", "hasnt": "hasn't", "havent": "haven't", "hadnt": "hadn't",
        "couldnt": "couldn't", "shouldnt": "shouldn't", "wouldnt": "wouldn't", "youre": "you're", "theyre": "they're",
        "thats": "that's", "whats": "what's", "ive": "I've", "youve": "you've", "weve": "we've", "theyve": "they've",
    ]

    /// Damerau–Levenshtein (adjacent transposition counts as one edit).
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    // MARK: - Ignore lists

    static let builtinSlang: Set<String> = [
        "cpa", "ecpm", "cpm", "cpc", "cpl", "cpi", "cpv", "ctr", "cr", "qps", "rtb", "ortb", "dsp", "ssp", "roi", "kpi", "geo", "s2s", "api",
        "postback", "postbacks", "sub", "subs", "subid", "subids", "pub", "pubs", "feed", "feeds", "push", "pushes",
        "offer", "offers", "landing", "landings", "lander", "creative", "creatives", "tracker", "payout", "payouts",
        "whitelist", "blacklist", "blacklisted", "whitelisted", "floor", "bid", "bids", "cap", "capped", "fraud", "adtech",
        "cookiematch", "kaminari", "kadam", "sid", "zone", "zoneid", "approve", "scale", "scaled", "cloaking",
        "сабы", "саб", "сабов", "сабам", "капа", "капу", "капы", "капе", "капой", "капы", "оффер", "оффера", "офферы", "офферов", "офферу", "оффером",
        "лендинг", "лендинги", "лендинга", "лендингу", "лендингов", "пуш", "пуши", "пушей", "пуша", "пушы",
        "тизер", "тизеры", "тизеров", "тизера", "фид", "фиды", "фида", "фидов", "трафик", "трафика", "трафику", "трафиком",
        "постбек", "постбеки", "постбека", "постбэк", "постбэки", "пиксель", "пиксели", "креатив", "креативы", "креатива", "креативов",
        "выплата", "флор", "флоры", "апрув", "апрува", "апрувы", "фрод", "фрода", "фродовый", "фродовых", "вайтлист", "блэклист",
        "паблишер", "паблишеры", "паблишеров", "паблишера", "трекер", "трекеры", "рекламодатель", "кукиматчинг", "метрика",
        "ставка", "ставку", "ставки", "кап", "каппинг", "лить", "льем", "льём", "залить", "слить", "масштабировать", "разжать", "разжать",
        "слак", "слаке", "слаку", "слака", "тимс", "тимсе", "телега", "телеге", "телегу", "телеги", "гугл", "гугле", "гугла", "фейсбук", "фейсбуке",
        "тикток", "тиктоке", "ютуб", "ютубе", "инста", "инсте", "инсту", "вотсап", "вотсапе", "вацап", "зум", "зуме", "джира", "джире", "джиру",
        "конфа", "конфе", "конфу", "конфы", "чатгпт", "клод", "клода", "клоде", "ватсап", "слэк",
        "коммит", "коммита", "коммиты", "коммитов", "деплой", "деплоя", "мерж", "мержа", "ревью", "фикс", "фиксы",
        "ок", "окей", "спс", "пжл", "плиз", "хз", "имхо", "лол", "кек"
    ]

    /// All Latin and Cyrillic words (≥2 letters, lowercased) from the glossary file.
    static func glossaryTerms(path: String) -> Set<String> {
        let p = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
        var out: Set<String> = []
        var cur = ""
        func flush() { if cur.count >= 2 { out.insert(cur.lowercased()) }; cur = "" }
        for ch in text {
            if ch.isLetter || ((ch == "-" || ch == "'") && !cur.isEmpty) { cur.append(ch) } else { flush() }
        }
        flush()
        return out
    }
}
