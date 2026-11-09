import Foundation

/// Script-based language detection for the three languages Tolk handles.
public enum LanguageDetector {
    /// Cyrillic with і/ї/є/ґ -> Ukrainian, other Cyrillic -> Russian, otherwise English.
    public static func detect(_ text: String) -> Language {
        var cyrillic = 0, latin = 0, ukrainianMarks = 0, russianMarks = 0
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
            default: break
            }
        }
        guard cyrillic > 0, cyrillic >= latin / 2 else { return .english }
        // A Russian message can quote a Ukrainian word; let the stronger signal win.
        return ukrainianMarks > russianMarks ? .ukrainian : .russian
    }

    /// Default direction: `secondary` (EN) -> `primary` (RU); anything else (RU/UA) -> `secondary`.
    public static func defaultTarget(for source: Language, config: TolkConfig) -> Language {
        if source == config.secondaryLanguage { return config.primaryLanguage }
        return config.secondaryLanguage
    }

    public static func resolve(_ request: TranslationRequest, config: TolkConfig) -> ResolvedRequest {
        let source = request.source ?? detect(request.text)
        let target = request.target ?? defaultTarget(for: source, config: config)
        return ResolvedRequest(text: request.text, source: source, target: target, tone: request.tone)
    }
}
