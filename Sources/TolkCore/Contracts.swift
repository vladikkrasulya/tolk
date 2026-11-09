// Shared contracts between the engine (TolkCore/Engine), input (Tolk/Input) and UI (Tolk/UI).
// Change only by agreement: every part of the app compiles against these types.
import Foundation

public enum Language: String, CaseIterable, Codable, Sendable {
    // Order = order in menus: main working languages first, then the rest.
    case english = "en", russian = "ru", ukrainian = "uk"
    case german = "de", french = "fr", spanish = "es", italian = "it", portuguese = "pt"
    case polish = "pl", czech = "cs", dutch = "nl", romanian = "ro", bulgarian = "bg"
    case turkish = "tr", kazakh = "kk", georgian = "ka", hebrew = "he", arabic = "ar"
    case chinese = "zh", japanese = "ja", korean = "ko", hindi = "hi", indonesian = "id", vietnamese = "vi"

    /// Name used inside LLM prompts.
    public var englishName: String {
        switch self {
        case .english: "English"; case .russian: "Russian"; case .ukrainian: "Ukrainian"
        case .german: "German"; case .french: "French"; case .spanish: "Spanish"; case .italian: "Italian"
        case .portuguese: "Portuguese"; case .polish: "Polish"; case .czech: "Czech"; case .dutch: "Dutch"
        case .romanian: "Romanian"; case .bulgarian: "Bulgarian"; case .turkish: "Turkish"; case .kazakh: "Kazakh"
        case .georgian: "Georgian"; case .hebrew: "Hebrew"; case .arabic: "Arabic"
        case .chinese: "Chinese (Simplified)"; case .japanese: "Japanese"; case .korean: "Korean"
        case .hindi: "Hindi"; case .indonesian: "Indonesian"; case .vietnamese: "Vietnamese"
        }
    }

    /// Russian name for the UI, nominative, lower case: "немецкий".
    public var russianName: String {
        switch self {
        case .english: "английский"; case .russian: "русский"; case .ukrainian: "украинский"
        case .german: "немецкий"; case .french: "французский"; case .spanish: "испанский"; case .italian: "итальянский"
        case .portuguese: "португальский"; case .polish: "польский"; case .czech: "чешский"; case .dutch: "нидерландский"
        case .romanian: "румынский"; case .bulgarian: "болгарский"; case .turkish: "турецкий"; case .kazakh: "казахский"
        case .georgian: "грузинский"; case .hebrew: "иврит"; case .arabic: "арабский"
        case .chinese: "китайский"; case .japanese: "японский"; case .korean: "корейский"
        case .hindi: "хинди"; case .indonesian: "индонезийский"; case .vietnamese: "вьетнамский"
        }
    }

    /// Flag emoji for compact UI.
    public var flag: String {
        switch self {
        case .english: "🇬🇧"; case .russian: "🇷🇺"; case .ukrainian: "🇺🇦"; case .german: "🇩🇪"; case .french: "🇫🇷"
        case .spanish: "🇪🇸"; case .italian: "🇮🇹"; case .portuguese: "🇵🇹"; case .polish: "🇵🇱"; case .czech: "🇨🇿"
        case .dutch: "🇳🇱"; case .romanian: "🇷🇴"; case .bulgarian: "🇧🇬"; case .turkish: "🇹🇷"; case .kazakh: "🇰🇿"
        case .georgian: "🇬🇪"; case .hebrew: "🇮🇱"; case .arabic: "🇸🇦"; case .chinese: "🇨🇳"; case .japanese: "🇯🇵"
        case .korean: "🇰🇷"; case .hindi: "🇮🇳"; case .indonesian: "🇮🇩"; case .vietnamese: "🇻🇳"
        }
    }

    /// Code for Google Translate.
    public var googleCode: String { self == .chinese ? "zh-CN" : (self == .hebrew ? "iw" : rawValue) }

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

/// "Footnote" on a debatable term in a finished translation (industry jargon, ambiguity).
public struct TranslationNote: Sendable, Equatable, Codable {
    /// The term as written in the source text.
    public var term: String
    /// How the translation rendered it.
    public var used: String
    /// A better / more idiomatic industry variant, if the model thinks there is one.
    public var suggestion: String?
    /// Short explanation in Russian.
    public var note: String

    public init(term: String, used: String, suggestion: String?, note: String) {
        self.term = term; self.used = used; self.suggestion = suggestion; self.note = note
    }

    /// What goes into the glossary when the user saves the note.
    public var preferred: String { (suggestion?.isEmpty == false ? suggestion : nil) ?? used }
}

/// Entry point used by the app.
public protocol TranslationEngine: AnyObject, Sendable {
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error>
    /// Adds a term to the user's glossary (rules file). Used by the UI's "add term" action.
    func addGlossaryTerm(source: String, translation: String) throws
    /// Up to 3 notes on debatable industry terms in a finished translation. Empty when nothing is debatable
    /// or the model is unavailable (notes are optional, never an error the user has to see).
    func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote]
}

public extension TranslationEngine {
    func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote] { [] }
}

/// App settings. Stored as JSON at `TolkConfig.defaultPath`; missing file = defaults.
public struct TolkConfig: Codable, Sendable, Equatable {
    public var ollamaURL: String = "http://192.168.1.13:11434"
    public var model: String = "qwen-translate"
    /// Rules + glossary in Markdown, injected into the system prompt.
    public var rulesPath: String = "~/Translate/rules.md"
    /// Default direction: `primary`/Ukrainian -> `secondary`; any other language -> `primary`.
    public var primaryLanguage: Language = .russian
    public var secondaryLanguage: Language = .english
    /// Max seconds between the two Cmd+C presses.
    public var doubleCopyInterval: Double = 0.4
    public var useGoogleFallback: Bool = true
    /// Remote access to the same Ollama from outside the home network (e.g. a Cloudflare Tunnel URL).
    /// Empty = LAN only. The engine tries `ollamaURL` first, then `remoteURL`.
    public var remoteURL: String = ""
    /// Extra HTTP headers for `remoteURL` (e.g. Cloudflare Access service-token headers).
    public var remoteHeaders: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case ollamaURL, model, rulesPath, primaryLanguage, secondaryLanguage, doubleCopyInterval, useGoogleFallback
        case remoteURL, remoteHeaders
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
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL) ?? d.remoteURL
        remoteHeaders = try c.decodeIfPresent([String: String].self, forKey: .remoteHeaders) ?? d.remoteHeaders
    }

    public static let defaultPath = "~/Translate/tolk.json"

    /// Writes the config as pretty JSON (creates the folder). Posts `TolkConfig.didChange`.
    public func save(to path: String = defaultPath) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: TolkConfig.didChange, object: nil)
    }

    /// Posted after `save`; the app rebuilds the engine with the new settings.
    public static let didChange = Notification.Name("TolkConfigDidChange")

    public static func load(from path: String = defaultPath) -> TolkConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return TolkConfig() }
        return (try? JSONDecoder().decode(TolkConfig.self, from: data)) ?? TolkConfig()
    }
}
