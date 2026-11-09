import Foundation
import NaturalLanguage

/// Language detection: exact script heuristic for RU/UA (the user's main case),
/// Apple's NaturalLanguage recognizer for everything else.
public enum LanguageDetector {
    public static func detect(_ text: String) -> Language {
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
        if cyrillic > 0, cyrillic >= latin / 2, cyrillic >= other {
            if ukrainianMarks > 0 || russianMarks > 0 {
                // A Russian message can quote a Ukrainian word; let the stronger signal win.
                return ukrainianMarks > russianMarks ? .ukrainian : .russian
            }
            // No distinctive letters: ask NL among Cyrillic languages, default Russian.
            return recognize(text, among: [.russian, .ukrainian, .bulgarian, .kazakh]) ?? .russian
        }
        let nonCyrillic = Language.allCases.filter { ![.russian, .ukrainian, .bulgarian, .kazakh].contains($0) }
        return recognize(text, among: nonCyrillic) ?? .english
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
        var target = request.target ?? defaultTarget(for: source, config: config)
        if target == source { target = defaultTarget(for: source, config: config) }
        if target == source { target = source == config.primaryLanguage ? config.secondaryLanguage : config.primaryLanguage }
        return ResolvedRequest(text: request.text, source: source, target: target, tone: request.tone)
    }
}
