import Foundation
import NaturalLanguage

/// Language detection: exact script heuristic for RU/UA (the user's main case),
/// Apple's NaturalLanguage recognizer for everything else.
public enum LanguageDetector {
    /// Text without things that say nothing about the language: URLs, emails, {macros}, IDs (sid=…, tokens with digits, paths).
    static func meaningful(_ text: String) -> String {
        var t = text
        for pattern in [#"https?://\S+|www\.\S+"#, #"\S+@\S+\.\S+"#, #"\{[^}\s]*\}"#] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let words = t.split(whereSeparator: { $0.isWhitespace }).filter { w in
            !(w.contains { $0.isNumber } || w.contains("=") || w.contains("_") || w.contains("/"))
        }
        return words.joined(separator: " ")
    }

    public static func detect(_ original: String) -> Language { detect(original, retried: false) }

    /// `retried`: the second pass looks at the raw text; without this flag a text whose every word is dropped by
    /// `meaningful` ("ключ=значение") called itself forever (stack overflow).
    private static func detect(_ original: String, retried: Bool) -> Language {
        let text = retried ? original : meaningful(original)
        guard text.contains(where: { $0.isLetter }) else {
            // Only IDs / links / numbers: if there are Cyrillic letters (e.g. inside an ID) keep going, else English.
            guard !retried, original.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) else { return .english }
            return detect(original.filter { !$0.isNumber }, retried: true)
        }
        var cyrillic = 0, latin = 0, ukrainianMarks = 0, russianMarks = 0, other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF:
                cyrillic += 1
                switch scalar {
                case "і", "І", "ї", "Ї", "є", "Є", "ґ", "Ґ": ukrainianMarks += 1
                case "ы", "Ы", "э", "Э", "ъ", "Ъ", "ё", "Ё": russianMarks += 1
                default: break
                }
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x0590...0x06FF, 0x0900...0x097F, 0x10A0...0x10FF, 0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: other += 1
            default: break
            }
        }
        // The script with more letters wins (a Russian text with a few English words stays Russian and vice versa).
        if cyrillic > 0, cyrillic >= latin, cyrillic >= other {
            if ukrainianMarks > 0 || russianMarks > 0 {
                // A Russian message can quote a Ukrainian word; let the stronger signal win.
                return ukrainianMarks > russianMarks ? .ukrainian : .russian
            }
            // No distinctive letters: ask NL among Cyrillic languages, default Russian.
            // Short words are ambiguous («привет» is "Bulgarian" for NL): Russian unless NL is really sure.
            return cyrillicByNL(text)
        }
        // Single acronym or ID-like token («QPS», «SSP»): NL guesses Portuguese; it is English adtech jargon.
        let letters = text.filter(\.isLetter)
        if !text.contains(where: \.isWhitespace), letters.count <= 6, letters == letters.uppercased() { return .english }
        let nonCyrillic = Language.allCases.filter { ![.russian, .ukrainian, .bulgarian, .kazakh].contains($0) }
        return recognize(text, among: nonCyrillic) ?? .english
    }

    private static func cyrillicByNL(_ text: String) -> Language {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.russian, .ukrainian, .bulgarian, .kazakh]
        r.processString(String(text.unicodeScalars.filter { !(0x41...0x5A).contains($0.value) && !(0x61...0x7A).contains($0.value) }.map(Character.init)))
        let h = r.languageHypotheses(withMaximum: 4)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        if (h[.ukrainian] ?? 0) >= 0.6 { return .ukrainian }
        if words >= 3, text.count >= 25, (h[.bulgarian] ?? 0) >= 0.9 { return .bulgarian }
        if words >= 3, text.count >= 25, (h[.kazakh] ?? 0) >= 0.9 { return .kazakh }
        return .russian
    }

    private static func recognize(_ text: String, among candidates: [Language]) -> Language? {
        let r = NLLanguageRecognizer()
        var constraints: [NLLanguage] = []
        var map: [NLLanguage: Language] = [:]
        for l in candidates {
            let nl = NLLanguage(rawValue: l == .chinese ? "zh-Hans" : l.rawValue)
            constraints.append(nl); map[nl] = l
        }
        r.languageConstraints = constraints
        r.processString(text)
        guard let (best, p) = r.languageHypotheses(withMaximum: 1).first else { return nil }
        // Very short or ambiguous text ("ok thanks"): unsure -> let the caller default (English).
        if p < 0.5, candidates.contains(.english), best != .english { return .english }
        return map[best]
    }

    /// Default direction: primary (RU) and Ukrainian -> secondary (EN); everything else -> primary (RU).
    public static func defaultTarget(for source: Language, config: TolkConfig) -> Language {
        if source == config.primaryLanguage || source == .ukrainian {
            return config.secondaryLanguage == source ? config.primaryLanguage : config.secondaryLanguage
        }
        return config.primaryLanguage
    }

    public static func resolve(_ request: TranslationRequest, config: TolkConfig) -> ResolvedRequest {
        let source = request.source ?? detect(request.text)
        if request.mode == .polish {
            return ResolvedRequest(text: request.text, source: source, target: source, tone: request.tone, mode: .polish)
        }
        var target = request.target ?? defaultTarget(for: source, config: config)
        if target == source { target = defaultTarget(for: source, config: config) }
        if target == source { target = source == config.primaryLanguage ? config.secondaryLanguage : config.primaryLanguage }
        var r = ResolvedRequest(text: request.text, source: source, target: target, tone: request.tone, mode: .translate,
                                replyTo: request.replyTo, context: request.context)
        r.threadContext = request.threadContext
        return r
    }
}
