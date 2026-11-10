// «Неверная раскладка»: текст набран не в той раскладке («Ghbdtn» ↔ «Привет», «Ерфтлы» ↔ «Thanks»).
// Чистая логика, без модели и без AppKit. Словарь (NSSpellChecker) приходит снаружи как `LayoutOracle`;
// без него (или для слов, которых в нём нет) работает эвристика «невозможных» сочетаний букв.
//
// Раскладки сопоставляются по ПОЗИЦИИ клавиши: US QWERTY ↔ русская ЙЦУКЕН ↔ украинская. Украинские і/ї/є/ґ стоят
// на клавишах русских ы/ъ/э/ё, поэтому в сторону кириллицы такие буквы неоднозначны (RU или UA?) — решает словарь,
// затем «голосование» по всему тексту.
//
// Знаки: на русской/украинской раскладке «,» и «.» стоят на клавише «/» (с Shift и без), «?» — на Shift+7, «:» — Shift+6,
// «;» — Shift+4, «"» — Shift+2. Поэтому текст, набранный по-русски на английской раскладке, содержит: «?» там, где
// хотели «,»; «&» там, где хотели «?»; «/» там, где хотели «.»; «^» → «:», «$» → «;», «@» → «"». «.» и «,» на самой
// клавише букв — это «ю» и «б» (решает словарь). Краевые знаки слова преобразуются, только если слово исправлено.
// «?» неоднозначен (в тесте «Ghbdtn, rfr ltkf? Ctujlyz» человек имел в виду вопрос): «?» перед словом с заглавной,
// в конце строки/текста остаётся вопросительным знаком, перед словом со строчной — запятая.
// Короткие слова, которые есть в обоих языках («vs» = «мы», «nj» = «то»), решаются по соседям: если рядом исправленное
// слово и в тексте исправлено большинство слов, они тоже исправляются.
import Foundation

public enum LayoutLanguage: String, Sendable { case en, ru, uk }

/// Словарь: знает ли слово язык. nil = ответить нельзя (словаря нет) — тогда решает эвристика.
public protocol LayoutOracle {
    func isKnown(_ word: String, _ language: LayoutLanguage) -> Bool?
}

public struct LayoutFixResult: Equatable, Sendable {
    public let text: String
    /// Сколько слов исправлено.
    public let changedWords: Int
    /// Есть ли в результате украинские буквы (для лога/подсказки).
    public let ukrainian: Bool
    public var changed: Bool { changedWords > 0 }
}

public enum LayoutFix {
    // MARK: Таблицы клавиш

    private static let latinKeys = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,./`")
    private static let latinShift = Array("QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?~")
    private static let ruKeys = Array("йцукенгшщзхъфывапролджэячсмитьбю.ё")
    private static let ruShift = Array("ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,Ё")
    private static let ukKeys = Array("йцукенгшщзхїфівапролджєячсмитьбю.ґ")
    private static let ukShift = Array("ЙЦУКЕНГШЩЗХЇФІВАПРОЛДЖЄЯЧСМИТЬБЮ,Ґ")

    private static func table(_ from: [Character], _ to: [Character]) -> [Character: Character] {
        var d: [Character: Character] = [:]
        for (a, b) in zip(from, to) { d[a] = b }
        return d
    }

    private static let toRu = table(latinKeys + latinShift, ruKeys + ruShift)
    private static let toUk = table(latinKeys + latinShift, ukKeys + ukShift)
    /// Кириллица (RU и UA вместе) → латиница.
    private static let toLatin: [Character: Character] = {
        var d = table(ruKeys + ruShift, latinKeys + latinShift)
        for (k, v) in table(ukKeys + ukShift, latinKeys + latinShift) { d[k] = v }
        return d
    }()

    private static let ukOnly = Set("іїєґІЇЄҐ")

    // MARK: Классы символов

    private static func isLatinLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
    private static func isCyrillicLetter(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) } && c.isLetter
    }
    /// Знаки, которые в другой раскладке — буквы (внутри слова считаем частью слова).
    private static let layoutPunct = Set("[]{};:'\"<>,.`~")

    // MARK: Публичное API

    /// Исправляет текст по словам. Слова в верной раскладке, числа, ссылки, почта, пути, код остаются как есть.
    public static func fix(_ text: String, oracle: LayoutOracle?, preferUkrainian: Bool = false) -> LayoutFixResult {
        // Разбиваем на токены (слова/пробелы), сохраняя пробелы как есть.
        var tokens: [(text: String, isSpace: Bool)] = []
        var current = "", currentSpace = false
        for ch in text {
            let sp = ch.isWhitespace
            if current.isEmpty { current = String(ch); currentSpace = sp }
            else if sp == currentSpace { current.append(ch) }
            else { tokens.append((current, currentSpace)); current = String(ch); currentSpace = sp }
        }
        if !current.isEmpty { tokens.append((current, currentSpace)) }

        return fixImpl(tokens: tokens, oracle: oracle, preferUkrainian: preferUkrainian)
    }

    // MARK: Реализация

    private enum Judgement {
        case keep
        /// Конвертировать: варианты для кириллицы (ru/uk) или одна латиница.
        case strong(Candidate2)
        /// Слабое решение: применяется, только если в тексте большинство слов исправлено.
        case weak(Candidate2)
    }

    private struct Candidate2 {
        var primary: String   // латиница, либо кириллица (RU)
        var alt: String       // кириллица (UK); для латиницы = primary
        var ruKnown: Bool
        var ukKnown: Bool
        var ambiguous: Bool { primary != alt }
        var hasUkLetters: Bool { alt.contains { ukOnly.contains($0) } }
    }

    private static func fixImpl(tokens: [(text: String, isSpace: Bool)], oracle: LayoutOracle?, preferUkrainian: Bool) -> LayoutFixResult {
        var strong: [Int: Candidate2] = [:], weak: [Int: Candidate2] = [:]
        var keptAlpha = 0
        var parts: [Int: Peeled] = [:]
        var ctx: [Int: Candidate2] = [:]
        for (i, t) in tokens.enumerated() where !t.isSpace {
            let pe = peel(t.text)
            parts[i] = pe
            switch analyze(pe.body, oracle: oracle) {
            case .keep:
                if hasLetters(t.text) { keptAlpha += 1 }
                if let c = contextCandidate(pe.body, oracle: oracle) { ctx[i] = c }
            case let .strong(c): strong[i] = c
            case let .weak(c): weak[i] = c
            }
        }
        // Второй проход: если исправлено большинство слов, добираем неуверенные (имена, жаргон, однобуквенные).
        var chosen = strong
        if !strong.isEmpty, strong.count >= keptAlpha { for (i, c) in weak { chosen[i] = c } }
        else if !strong.isEmpty, strong.count * 2 >= keptAlpha + weak.count { for (i, c) in weak { chosen[i] = c } }

        // Короткие слова «в обеих раскладках» — по соседям: рядом исправленное слово, и исправлено большинство.
        let wordIdx = tokens.indices.filter { !tokens[$0].isSpace && hasLetters(tokens[$0].text) }
        if !chosen.isEmpty, !ctx.isEmpty {
            var progress = true
            while progress {
                progress = false
                for (pos, i) in wordIdx.enumerated() where chosen[i] == nil {
                    guard let c = ctx[i], chosen.count * 2 >= wordIdx.count else { continue }
                    let toCyr = parts[i].map { $0.body.contains(where: isLatinLetter) } ?? true
                    let near = [pos - 1, pos + 1].filter { wordIdx.indices.contains($0) }.map { wordIdx[$0] }
                    let ok = near.contains { n in
                        guard chosen[n] != nil, let pb = parts[n]?.body else { return false }
                        return pb.contains(where: isLatinLetter) == toCyr
                    }
                    if ok { chosen[i] = c; progress = true }
                }
            }
        }

        // Голосуем за украинский: слова, где украинский вариант известен словарю, а русский нет (или есть укр. буквы).
        var ukVotes = 0, ruVotes = 0
        for (_, c) in chosen where c.ambiguous || c.hasUkLetters {
            if c.ukKnown && !c.ruKnown { ukVotes += 1 }
            else if c.ruKnown && !c.ukKnown { ruVotes += 1 }
        }
        let useUk = ukVotes > ruVotes || (ukVotes == ruVotes && ukVotes > 0 && preferUkrainian)
            || (ukVotes == 0 && ruVotes == 0 && preferUkrainian)
        var out = ""
        var changed = 0
        var anyUk = false
        for (i, t) in tokens.enumerated() {
            guard let c = chosen[i] else { out += t.text; continue }
            changed += 1
            let pick: String
            if c.ruKnown && !c.ukKnown { pick = c.primary }
            else if c.ukKnown && !c.ruKnown { pick = c.alt }
            else { pick = useUk ? c.alt : c.primary }
            if pick.contains(where: { ukOnly.contains($0) }) { anyUk = true }
            if let pe = parts[i], pe.body.contains(where: isLatinLetter) {
                let next = tokens[(i + 1)...]
                out += convertMarks(pe.lead, atEnd: false, next: next) + pick + convertMarks(pe.trail, atEnd: true, next: next)
            } else {
                out += pick
            }
        }
        return LayoutFixResult(text: out, changedWords: changed, ukrainian: anyUk)
    }


    // MARK: Краевые знаки

    private struct Peeled { var lead: String; var body: String; var trail: String }
    private static let trailMarks = Set("?&/^$@")

    /// Отделяет краевые знаки цифрового ряда/слэша от латинского слова. Ссылки, пути, почта и числа не трогаем.
    private static func peel(_ token: String) -> Peeled {
        var chars = Array(token)
        var lead = "", trail = ""
        if chars.first == "@" { lead = "@"; chars.removeFirst() }
        while let l = chars.last, trailMarks.contains(l) { trail = String(l) + trail; chars.removeLast() }
        let body = String(chars)
        let isWord = body.contains(where: isLatinLetter) && !body.contains(where: isCyrillicLetter)
            && !body.contains(where: { "@#$_\\/".contains($0) || $0.isNumber }) && !body.lowercased().contains("://")
        guard isWord, !(lead.isEmpty && trail.isEmpty) else { return Peeled(lead: "", body: token, trail: "") }
        return Peeled(lead: lead, body: body, trail: trail)
    }

    /// Знаки в русской раскладке: & → ?, / → ., ^ → :, $ → ;, @ → ", ? → «,» (или «?» в конце предложения).
    private static func convertMarks(_ marks: String, atEnd: Bool, next: ArraySlice<(text: String, isSpace: Bool)>) -> String {
        var out = ""
        let chars = Array(marks)
        for (k, m) in chars.enumerated() {
            switch m {
            case "&": out.append("?")
            case "/": out.append(".")
            case "^": out.append(":")
            case "$": out.append(";")
            case "@": out.append("\"")
            case "?":
                out.append(atEnd && k == chars.count - 1 && !sentenceContinues(next) ? "?" : ",")
            default: out.append(m)
            }
        }
        return out
    }

    /// После «?» идёт слово со строчной буквы (в другой раскладке — запятая внутри предложения).
    private static func sentenceContinues(_ next: ArraySlice<(text: String, isSpace: Bool)>) -> Bool {
        guard let sp = next.first, sp.isSpace, !sp.text.contains("\n") else { return false }
        guard let w = next.dropFirst().first, !w.isSpace, let f = w.text.first(where: { $0.isLetter }) else { return false }
        return f.isLowercase
    }

    /// Короткое слово, верное в своей раскладке, но тоже слово в другой («vs» = «мы»): кандидат для решения по соседям.
    private static func contextCandidate(_ body: String, oracle: LayoutOracle?) -> Candidate2? {
        guard let oracle else { return nil }
        let lettersOnly = letters(body)
        guard (1...3).contains(lettersOnly.count) else { return nil }
        if body.contains(where: isLatinLetter), !body.contains(where: isCyrillicLetter) {
            let ru = mapLatinToCyr(body, uk: false), uk = mapLatinToCyr(body, uk: true)
            let ruK = oracle.isKnown(letters(ru), .ru) == true, ukK = oracle.isKnown(letters(uk), .uk) == true
            guard ruK || ukK else { return nil }
            return Candidate2(primary: ru, alt: uk, ruKnown: ruK, ukKnown: ukK)
        }
        if body.contains(where: isCyrillicLetter), !body.contains(where: isLatinLetter) {
            let lat = String(body.map { toLatin[$0] ?? $0 })
            guard oracle.isKnown(letters(lat), .en) == true else { return nil }
            return Candidate2(primary: lat, alt: lat, ruKnown: false, ukKnown: false)
        }
        return nil
    }

    private static func hasLetters(_ s: String) -> Bool { s.contains { $0.isLetter } }

    /// Слово без краевых «нейтральных» знаков → «ядро» из букв (+ знаки раскладки внутри слова).
    private static func core(of token: String, letter: (Character) -> Bool) -> String {
        var chars = Array(token)
        while let f = chars.first, !letter(f) { chars.removeFirst() }
        while let l = chars.last, !letter(l) { chars.removeLast() }
        return String(chars)
    }

    private static func letters(_ s: String) -> String { String(s.filter { $0.isLetter }) }

    private static func analyze(_ token: String, oracle: LayoutOracle?) -> Judgement {
        // Ссылки, почта, пути, код, числа с буквами — не трогаем.
        let lower = token.lowercased()
        if token.contains("@") || lower.contains("://") || lower.hasPrefix("www.") || token.contains("_")
            || token.contains("\\") || token.contains("#") || token.contains("$") { return .keep }
        if token.contains(where: { $0.isNumber }) && token.contains(where: { $0.isLetter }) { return .keep }
        let hasLatin = token.contains(where: isLatinLetter), hasCyr = token.contains(where: isCyrillicLetter)
        if hasLatin && hasCyr { return .keep } // смесь в одном слове — не угадываем
        if hasLatin { return analyzeLatin(token, oracle: oracle) }
        if hasCyr { return analyzeCyrillic(token, oracle: oracle) }
        // Только знаки раскладки, например ";fk" не попадёт сюда (там есть буква); «,.» и т. п. — не слово.
        return .keep
    }

    private static func mapLatinToCyr(_ s: String, uk: Bool) -> String {
        let table = uk ? toUk : toRu
        return String(s.map { c -> Character in
            if let m = table[c] { return m }
            // Заглавные знаки уже в таблице; прочее оставляем.
            return c
        })
    }

    private static func known(_ word: String, _ lang: LayoutLanguage, oracle: LayoutOracle?) -> Bool? {
        guard !word.isEmpty else { return false }
        return oracle?.isKnown(word, lang)
    }

    /// Краевые «.» и «,» — это либо буквы ю/б, либо знаки препинания. Если слово со ю/б есть в словаре — буквы,
    /// иначе остаются знаками.
    private static func withTrailingPunct(_ token: String, oracle: LayoutOracle?, _ inner: (String) -> Judgement) -> Judgement {
        let trail = String(token.reversed().prefix { $0 == "," || $0 == "." }.reversed())
        let full = inner(token)
        guard !trail.isEmpty, token.count > trail.count else { return full }
        if case let .strong(c) = full, c.ruKnown || c.ukKnown { return full }
        let base = String(token.dropLast(trail.count))
        switch inner(base) {
        case .keep: return full
        case let .strong(c): return .strong(Candidate2(primary: c.primary + trail, alt: c.alt + trail, ruKnown: c.ruKnown, ukKnown: c.ukKnown))
        case let .weak(c): return .weak(Candidate2(primary: c.primary + trail, alt: c.alt + trail, ruKnown: c.ruKnown, ukKnown: c.ukKnown))
        }
    }

    private static func analyzeLatin(_ token: String, oracle: LayoutOracle?) -> Judgement {
        withTrailingPunct(token, oracle: oracle) { analyzeLatinCore($0, oracle: oracle) }
    }

    private static func analyzeLatinCore(_ token: String, oracle: LayoutOracle?) -> Judgement {
        // «Ядро» английского слова: буквы и апостроф/дефис внутри.
        let enCore = core(of: token) { isLatinLetter($0) }
        // Для проверки словарём: без внутренних знаков раскладки, кроме апострофа.
        let enWord = enCore.replacingOccurrences(of: "’", with: "'")
        let enKnown = known(enWord, .en, oracle: oracle)
        if enKnown == true { return .keep }
        // Ядро по русской раскладке: всё, что стоит внутри слова (в т. ч. [];',.`).
        let mapCore = core(of: token) { isLatinLetter($0) || layoutPunct.contains($0) }
        let mappedRu = mapLatinToCyr(mapCore, uk: false), mappedUk = mapLatinToCyr(mapCore, uk: true)
        let ruLetters = letters(mappedRu), ukLetters = letters(mappedUk)
        guard !ruLetters.isEmpty else { return .keep }
        let ruKnown = known(ruLetters, .ru, oracle: oracle)
        let ukKnown = known(ukLetters, .uk, oracle: oracle)
        let full = Candidate2(primary: mapLatinToCyr(token, uk: false), alt: mapLatinToCyr(token, uk: true),
                              ruKnown: ruKnown == true, ukKnown: ukKnown == true)
        // Внутри слова знак раскладки (e;t, rjnjhsq) в английском слове невозможен.
        let innerPunct = enCore.isEmpty ? false : mapCore.dropFirst().dropLast().contains { layoutPunct.contains($0) && $0 != "'" }
        let singleLetter = max(ruLetters.count, ukLetters.count) < 2
        if ruKnown == true || ukKnown == true {
            // Слово есть в русском/украинском, но нет в английском. Одну букву (в, с, и, я…) — только слабо.
            return singleLetter ? .weak(full) : .strong(full)
        }
        if singleLetter { return .weak(full) }
        // Ни там ни там словаря: решает эвристика.
        let enBad = innerPunct || !plausibleLatin(letters(enCore))
        let cyrGood = plausibleCyrillic(ruLetters) || plausibleCyrillic(ukLetters)
        if enBad && cyrGood { return oracle == nil || ruKnown == nil ? .strong(full) : .weak(full) }
        if enKnown == nil && !plausibleLatin(letters(enCore)) { return .weak(full) }
        return .keep
    }

    private static func analyzeCyrillic(_ token: String, oracle: LayoutOracle?) -> Judgement {
        withTrailingPunct(token, oracle: oracle) { analyzeCyrillicCore($0, oracle: oracle) }
    }

    private static func analyzeCyrillicCore(_ token: String, oracle: LayoutOracle?) -> Judgement {
        let cyrCore = core(of: token) { isCyrillicLetter($0) }
        let word = letters(cyrCore)
        if word.isEmpty { return .keep }
        let ru = known(word, .ru, oracle: oracle), uk = known(word, .uk, oracle: oracle)
        if ru == true || uk == true { return .keep }
        let mapCore = core(of: token) { isCyrillicLetter($0) || layoutPunct.contains($0) }
        let mappedWord = String(mapCore.map { toLatin[$0] ?? $0 })
        let mapped = String(token.map { toLatin[$0] ?? $0 })
        let latLetters = letters(mappedWord)
        guard !latLetters.isEmpty else { return .keep }
        let cand = Candidate2(primary: mapped, alt: mapped, ruKnown: false, ukKnown: false)
        let enKnown = known(latLetters, .en, oracle: oracle)
        let single = word.count < 2
        if enKnown == true { return single ? .weak(cand) : .strong(cand) }
        if single { return .weak(cand) }
        // Украинская буква в слове, которого нет в словаре, — скорее реальное слово (имя), а не раскладка.
        let cyrBad = !plausibleCyrillic(word)
        let latGood = plausibleLatin(latLetters)
        if cyrBad && latGood { return oracle == nil || enKnown == nil ? .strong(cand) : .weak(cand) }
        return .keep
    }

    // MARK: Эвристика «невозможных» сочетаний

    private static let latinVowels = Set("aeiouyAEIOUY")
    private static let cyrVowels = Set("аеёиоуыэюяіїєАЕЁИОУЫЭЮЯІЇЄ")

    /// Пары латинских букв, которых в английских словах практически нет.
    private static let impossibleLatin: Set<String> = [
        "bq", "bx", "cj", "cv", "cx", "dx", "fq", "fv", "fx", "gq", "gx", "hx", "jq", "jx", "jz", "kq", "kx", "kz",
        "mx", "pq", "px", "qb", "qc", "qd", "qf", "qg", "qh", "qj", "qk", "ql", "qm", "qn", "qp", "qs", "qt", "qv",
        "qw", "qx", "qz", "sx", "vb", "vf", "vj", "vk", "vm", "vp", "vq", "vw", "vx", "wq", "wx", "xj", "xx", "zx",
        "hk", "hg", "hb", "hd", "hf", "hj", "hl", "hm", "hn", "hp", "hq", "hs", "hv", "hz",
    ]
    /// Сочетания, невозможные в русском/украинском.
    private static let impossibleCyr: Set<String> = [
        "ыы", "ъъ", "ьь", "ьъ", "ъь", "йй", "аъ", "оъ", "уъ", "иъ", "эъ", "ьа", "ьо", "ьи", "ьэ", "ьу", "ьы",
        "жы", "шы", "чы", "щы", "цю", "щя", "чя", "шя", "жя", "щю", "чю", "шю", "жю",
        "ііі", "її", "єє", "ґґ", "іі",
    ]

    /// Правдоподобно ли слово как английское: есть гласная (для ≥3 букв), нет пачки согласных ≥5, нет «невозможных» пар.
    static func plausibleLatin(_ w: String) -> Bool {
        let chars = Array(w.lowercased())
        guard !chars.isEmpty else { return false }
        if chars.count >= 3 && !chars.contains(where: { latinVowels.contains($0) }) { return false }
        if chars.count == 2 && !chars.contains(where: { latinVowels.contains($0) }) && !["by", "my", "hm", "sh", "st", "tv", "pm", "ms", "mr", "vs", "dr"].contains(String(chars)) { return false }
        var run = 0
        for c in chars {
            if latinVowels.contains(c) { run = 0 } else { run += 1; if run >= 5 { return false } }
        }
        return impossibleFraction(chars, impossibleLatin) == 0
    }

    static func plausibleCyrillic(_ w: String) -> Bool {
        let chars = Array(w.lowercased())
        guard !chars.isEmpty else { return false }
        if let f = chars.first, "ъыь".contains(f) { return false }
        if chars.count >= 3 && !chars.contains(where: { cyrVowels.contains($0) }) { return false }
        if chars.count == 2 && !chars.contains(where: { cyrVowels.contains($0) }) && !["вс", "вз", "вт", "кс", "ст", "мс"].contains(String(chars)) { return false }
        var run = 0
        for c in chars {
            if cyrVowels.contains(c) { run = 0 } else { run += 1; if run >= 5 { return false } }
        }
        return impossibleFraction(chars, impossibleCyr) == 0
    }

    /// Доля соседних пар из «невозможного» набора.
    static func impossibleFraction(_ chars: [Character], _ set: Set<String>) -> Double {
        guard chars.count >= 2 else { return 0 }
        var bad = 0
        for i in 0..<(chars.count - 1) where set.contains(String(chars[i]) + String(chars[i + 1])) { bad += 1 }
        return Double(bad) / Double(chars.count - 1)
    }
}
