// Shared contracts between the engine (TolkCore/Engine), input (Tolk/Input) and UI (Tolk/UI).
// Change only by agreement: every part of the app compiles against these types.
import Foundation

public enum Language: String, CaseIterable, Codable, Sendable {
    case russian = "ru", ukrainian = "uk", english = "en"

    /// Name used inside LLM prompts.
    public var englishName: String {
        switch self { case .russian: "Russian"; case .ukrainian: "Ukrainian"; case .english: "English" }
    }
    /// Short label for the UI.
    public var label: String { rawValue.uppercased() }
}

public enum Tone: String, CaseIterable, Codable, Sendable {
    case auto    // let the model keep the tone of the source
    case chat    // short, informal (Slack/Telegram)
    case formal  // polite business email
}

/// What the app asks for. `source`/`target` nil = detect automatically.
public struct TranslationRequest: Sendable, Equatable {
    public var text: String
    public var source: Language?
    public var target: Language?
    public var tone: Tone

    public init(text: String, source: Language? = nil, target: Language? = nil, tone: Tone = .auto) {
        self.text = text; self.source = source; self.target = target; self.tone = tone
    }
}

/// Request after language detection, handed to a provider.
public struct ResolvedRequest: Sendable, Equatable {
    public var text: String
    public var source: Language
    public var target: Language
    public var tone: Tone

    public init(text: String, source: Language, target: Language, tone: Tone) {
        self.text = text; self.source = source; self.target = target; self.tone = tone
    }
}

/// Stream the UI consumes: one `.started`, then `.delta` chunks, then `.finished`.
/// If the primary provider fails, the engine may emit `.fellBack` and a new `.started`
/// from the fallback provider; the UI should then clear the text it has shown.
public enum TranslationEvent: Sendable, Equatable {
    case started(provider: String, source: Language, target: Language)
    case delta(String)
    case fellBack(from: String, reason: String)
    case finished
}

/// One translation backend (Ollama/Qwen, Google, ...).
public protocol TranslationProvider: Sendable {
    var name: String { get }
    /// Fast check (<1 s) whether the provider can be used right now.
    func isAvailable() async -> Bool
    /// Streams the translated text in chunks.
    func translate(_ request: ResolvedRequest) -> AsyncThrowingStream<String, Error>
}

/// Entry point used by the app.
public protocol TranslationEngine: AnyObject, Sendable {
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error>
    /// Adds a term to the user's glossary (rules file). Used by the UI's "add term" action.
    func addGlossaryTerm(source: String, translation: String) throws
}

/// App settings. Stored as JSON at `TolkConfig.defaultPath`; missing file = defaults.
public struct TolkConfig: Codable, Sendable, Equatable {
    public var ollamaURL: String = "http://192.168.1.13:11434"
    public var model: String = "qwen-translate"
    /// Rules + glossary in Markdown, injected into the system prompt.
    public var rulesPath: String = "~/Translate/rules.md"
    /// Text in `secondary` (or Ukrainian) goes to... see engine rules; default: RU/UA -> EN, EN -> RU.
    public var primaryLanguage: Language = .russian
    public var secondaryLanguage: Language = .english
    /// Max seconds between the two Cmd+C presses.
    public var doubleCopyInterval: Double = 0.4
    public var useGoogleFallback: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case ollamaURL, model, rulesPath, primaryLanguage, secondaryLanguage, doubleCopyInterval, useGoogleFallback
    }

    /// Every key is optional: `{"model": "x"}` keeps all other defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TolkConfig()
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        rulesPath = try c.decodeIfPresent(String.self, forKey: .rulesPath) ?? d.rulesPath
        primaryLanguage = try c.decodeIfPresent(Language.self, forKey: .primaryLanguage) ?? d.primaryLanguage
        secondaryLanguage = try c.decodeIfPresent(Language.self, forKey: .secondaryLanguage) ?? d.secondaryLanguage
        doubleCopyInterval = try c.decodeIfPresent(Double.self, forKey: .doubleCopyInterval) ?? d.doubleCopyInterval
        useGoogleFallback = try c.decodeIfPresent(Bool.self, forKey: .useGoogleFallback) ?? d.useGoogleFallback
    }

    public static let defaultPath = "~/Translate/tolk.json"

    public static func load(from path: String = defaultPath) -> TolkConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return TolkConfig() }
        return (try? JSONDecoder().decode(TolkConfig.self, from: data)) ?? TolkConfig()
    }
}
