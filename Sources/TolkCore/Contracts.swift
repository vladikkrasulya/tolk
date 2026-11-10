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

/// What the engine does with the text.
public enum TextMode: String, CaseIterable, Codable, Sendable {
    case translate   // translate into `target`
    case polish      // rewrite in the SAME language: fix grammar, make it sound native and professional
}

/// What the app asks for. `source`/`target` nil = detect automatically. For `.polish` the target is the source.
public struct TranslationRequest: Sendable, Equatable {
    public var text: String
    public var source: Language?
    public var target: Language?
    public var tone: Tone
    public var mode: TextMode
    /// The message this text replies to (partner's original). The translation then keeps the partner's
    /// terms, names and register so the conversation reads as one thread.
    public var replyTo: String?
    /// Live typing: `text` is only the changed tail of a longer message; this is the unchanged beginning
    /// and its translation (see `IncrementalSession`). The model translates `text` only, consistent with it.
    public var context: TranslationContext?
    /// «Translate again»: skip the engine's result cache; the new result replaces the cached one.
    public var bypassCache: Bool
    /// Earlier lines of this conversation (see ThreadMemory): context for pronouns, never translated.
    public var threadContext: String?

    public init(text: String, source: Language? = nil, target: Language? = nil, tone: Tone = .auto,
                mode: TextMode = .translate, replyTo: String? = nil, context: TranslationContext? = nil,
                bypassCache: Bool = false) {
        self.text = text; self.source = source; self.target = target; self.tone = tone; self.mode = mode
        self.replyTo = replyTo; self.context = context; self.bypassCache = bypassCache
    }
}

/// The already translated beginning of a message whose tail is being translated now.
public struct TranslationContext: Sendable, Equatable {
    public var source: String
    public var translation: String
    public init(source: String, translation: String) { self.source = source; self.translation = translation }
}

/// Request after language detection, handed to a provider.
public struct ResolvedRequest: Sendable, Equatable {
    public var text: String
    public var source: Language
    public var target: Language
    public var tone: Tone
    public var mode: TextMode
    public var replyTo: String?
    public var context: TranslationContext?
    public var threadContext: String?
    /// Set by EntityMasking: an example placeholder, the prompt then explains that placeholders must be copied.
    public var protectedExample: String?

    public init(text: String, source: Language, target: Language, tone: Tone, mode: TextMode = .translate,
                replyTo: String? = nil, context: TranslationContext? = nil) {
        self.text = text; self.source = source; self.target = target; self.tone = tone; self.mode = mode
        self.replyTo = replyTo; self.context = context
    }
}

/// Stream the UI consumes: one `.started`, then `.delta` chunks, then `.finished`.
/// If the primary provider fails, the engine may emit `.fellBack` and a new `.started`
/// from the fallback provider; the UI should then clear the text it has shown.
public enum TranslationEvent: Sendable, Equatable {
    case started(provider: String, source: Language, target: Language)
    case delta(String)
    case fellBack(from: String, reason: String)
    /// Sent right before `.finished`: who translated, by which route, how fast.
    case stats(TranslationStats)
    case finished
}

/// How a translation went — shown as a one-line status under the translation.
public struct TranslationStats: Sendable, Equatable {
    public enum Route: String, Sendable { case home, remote, web, device }
    public var provider: String
    public var route: Route
    /// Seconds from the request to the first chunk.
    public var firstChunk: TimeInterval?
    public var total: TimeInterval
    /// Exact output tokens when the server reports them, else an estimate from streamed chunks.
    public var outputTokens: Int?
    public var tokensExact: Bool
    /// Why the primary model was not used (nil = it was).
    public var fallbackReason: String?
    /// Problems found by the automatic check of the finished translation (a lost number or link,
    /// wrong output language). Short Russian phrases for the status line; empty = nothing found.
    public var warnings: [String] = []
    /// The text came from the engine's cache of finished translations: no model was called, `total` ≈ 0.
    public var fromCache: Bool = false

    public init(provider: String, route: Route, firstChunk: TimeInterval?, total: TimeInterval,
                outputTokens: Int?, tokensExact: Bool, fallbackReason: String?) {
        self.provider = provider; self.route = route; self.firstChunk = firstChunk; self.total = total
        self.outputTokens = outputTokens; self.tokensExact = tokensExact; self.fallbackReason = fallbackReason
    }

    /// Generation speed (after the first chunk).
    public var tokensPerSecond: Double? {
        guard let t = outputTokens, t > 1, let f = firstChunk, total - f > 0.05 else { return nil }
        return Double(t) / (total - f)
    }

    public var routeTitle: String {
        switch route {
        case .home: "\(provider) дома"
        case .remote: "\(provider) вне дома"
        case .web: provider
        case .device: "\(provider) на этом Mac"
        }
    }
}

/// Lets a provider report the server's token count to the engine (bound per request with a task-local).
public final class UsageBox: @unchecked Sendable {
    public var completionTokens: Int?
    public init() {}
    @TaskLocal public static var current: UsageBox?
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
    /// 3–4 alternative renderings of `fragment` (a word/phrase of `translation`) that fit the context. Empty if unavailable.
    func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String]
    /// Second, "editor" pass over a finished translation: same meaning, numbers and names, but phrased the way
    /// a native speaker would write it (removes calques). Streams the improved text; on any problem streams
    /// `translation` unchanged.
    func refine(source: String, translation: String, from: Language, to: Language, tone: Tone) -> AsyncThrowingStream<String, Error>
    // Big-window extras (see Engine/BigWindowTools.swift). Each model call is started by a button press.
    func sentenceVariants(sentence: String, current: String, fullSource: String, fullTranslation: String,
                          from: Language, to: Language, tone: Tone) async throws -> [SentenceVariant]
    func rewrite(translation: String, source: String, from: Language, to: Language, mode: RewriteMode) async throws -> RewriteResult
    /// 2-3 alternative translations of the whole text, each with a label and a reason.
    func translationVariants(source: String, translation: String, from: Language, to: Language, tone: Tone, replyTo: String?) async throws -> [TranslationVariant]
    func explain(message: String) async throws -> MessageExplanation
    /// The request for the reply flow (partner's message + the user's answer); stream it through `translate`.
    func replyRequest(message: String, reply: String, tone: Tone) -> TranslationRequest
    /// Glossary entries that fire for `text` when translating into `target` (no model, instant).
    func glossaryHits(in text: String, target: Language) -> [GlossaryHit]
}

public extension TranslationEngine {
    func refine(source: String, translation: String, from: Language, to: Language, tone: Tone) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in c.yield(translation); c.finish() }
    }
    func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote] { [] }
    func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String] { [] }
    func sentenceVariants(sentence: String, current: String, fullSource: String, fullTranslation: String,
                          from: Language, to: Language, tone: Tone) async throws -> [SentenceVariant] {
        throw TolkError.unavailable("Варианты предложения недоступны для этого движка")
    }
    func rewrite(translation: String, source: String, from: Language, to: Language, mode: RewriteMode) async throws -> RewriteResult {
        throw TolkError.unavailable("Переписывание недоступно для этого движка")
    }
    func translationVariants(source: String, translation: String, from: Language, to: Language, tone: Tone, replyTo: String?) async throws -> [TranslationVariant] {
        throw TolkError.unavailable("Варианты перевода недоступны для этого движка")
    }
    func explain(message: String) async throws -> MessageExplanation {
        throw TolkError.unavailable("Разбор смысла недоступен для этого движка")
    }
    func replyRequest(message: String, reply: String, tone: Tone) -> TranslationRequest {
        let cfg = TolkConfig.load()
        let partner = LanguageDetector.detect(message)
        var source = LanguageDetector.detect(reply)
        if source == partner { source = cfg.primaryLanguage == partner ? cfg.secondaryLanguage : cfg.primaryLanguage }
        return TranslationRequest(text: reply, source: source, target: partner, tone: tone, replyTo: message)
    }
    func glossaryHits(in text: String, target: Language) -> [GlossaryHit] { [] }
}

/// What translates when the home model is unreachable.
public enum FallbackProvider: String, Codable, CaseIterable, Sendable {
    case google   // free web endpoint, text goes to Google
    case apple    // Apple Translation, on-device (macOS 26+, language packs must be downloaded)
    case none     // show an error instead

    public var title: String {
        switch self { case .google: "Google"; case .apple: "Apple (на этом Mac)"; case .none: "Никакого" }
    }
}

/// A glossary profile: its own rules/glossary file and, optionally, its own model.
/// E.g. «Работа» (adtech slang, Qwen) and «Дом» (books and documents, Gemma).
public struct GlossaryProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var rulesPath: String
    /// nil = use `TolkConfig.model`.
    public var model: String?

    public init(id: String, name: String, rulesPath: String, model: String? = nil) {
        self.id = id; self.name = name; self.rulesPath = rulesPath; self.model = model
    }
}

/// App settings. Stored as JSON at `TolkConfig.defaultPath`; missing file = defaults.
public struct TolkConfig: Codable, Sendable, Equatable {
    public var ollamaURL: String = "http://192.168.1.13:11434"
    public var model: String = "gemma-translate"
    /// Rules + glossary in Markdown, injected into the system prompt.
    public var rulesPath: String = "~/Translate/rules.md"
    /// Default direction: `primary`/Ukrainian -> `secondary`; any other language -> `primary`.
    public var primaryLanguage: Language = .russian
    public var secondaryLanguage: Language = .english
    /// Max seconds between the two Cmd+C presses.
    public var doubleCopyInterval: Double = 0.4
    public var fallback: FallbackProvider = .google
    /// Glossary profiles; the active one decides the rules file (and may override the model).
    public var profiles: [GlossaryProfile] = TolkConfig.defaultProfiles(workRules: "~/Translate/rules.md")
    public var activeProfileID: String = "home"

    public static func defaultProfiles(workRules: String) -> [GlossaryProfile] {
        [GlossaryProfile(id: "work", name: "Работа", rulesPath: workRules),
         GlossaryProfile(id: "home", name: "Дом", rulesPath: "~/Translate/home.md")]
    }

    public var activeProfile: GlossaryProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
            ?? GlossaryProfile(id: "work", name: "Работа", rulesPath: rulesPath)
    }
    /// What the engine really uses.
    public var effectiveRulesPath: String { activeProfile.rulesPath }
    public var effectiveModel: String {
        if let m = activeProfile.model, !m.isEmpty { return m }
        return model
    }
    /// Remote access to the same Ollama from outside the home network (e.g. a Cloudflare Tunnel URL).
    /// Empty = LAN only. The engine tries `ollamaURL` first, then `remoteURL`.
    public var remoteURL: String = ""
    /// Extra HTTP headers for `remoteURL` (e.g. Cloudflare Access service-token headers).
    public var remoteHeaders: [String: String] = [:]
    /// Tone chosen automatically by the frontmost app's bundle id (quick actions, popup when tone = auto).
    public var toneByApp: [String: Tone] = TolkConfig.defaultToneByApp

    public static let defaultToneByApp: [String: Tone] = [
        "com.tinyspeck.slackmacgap": .chat, "ru.keepcoder.Telegram": .chat, "com.hnc.Discord": .chat,
        "net.whatsapp.WhatsApp": .chat, "com.microsoft.teams2": .chat,
        "com.apple.mail": .formal, "com.microsoft.Outlook": .formal, "com.readdle.smartemail-Mac": .formal,
    ]

    /// System-wide autocomplete (local model, ghost text, Tab accepts).
    public var autocomplete: Bool = false
    /// GGUF model for autocomplete.
    public var autocompleteModel: String = "~/Library/Application Support/Tolk/models/gemma-4-E4B-it-q4_0.gguf"
    /// Bundle ids where autocomplete stays off (terminals, IDEs).
    public var autocompleteOffApps: [String] = TolkConfig.defaultAutocompleteOffApps
    /// Suggestion length: "short" (~3 words), "medium" (~6), "long" (~12).
    public var autocompleteLength: String = "medium"
    /// Global writing instructions for suggestions.
    public var autocompleteInstructions: String = ""
    /// Per-app instructions, bundle id -> text.
    public var autocompleteAppInstructions: [String: String] = [:]
    /// Use the active glossary profile + tone-by-app in suggestions.
    public var autocompleteUseGlossary: Bool = true
    /// Add recently copied text to the prompt.
    public var autocompleteClipboard: Bool = false
    /// ":code" -> emoji suggestions.
    public var autocompleteEmoji: Bool = true
    /// Typo fixes as ghost text (Tab applies).
    public var autocorrect: Bool = true
    /// Remember accepted/sent phrases locally and use them as style examples.
    public var autocompleteLearnStyle: Bool = false
    /// Remember every sent message (true) or only messages where a suggestion was accepted (false, the default).
    public var autocompleteRecordAll: Bool = false
    /// Preference for the user's own words in suggestions: "off", "medium" (default) or "strong". Works with style learning on.
    public var autocompleteWordPreference: String = "medium"
    /// How often suggestions appear: "rare" (only confident), "normal", "often".
    public var autocompleteFrequency: String = "normal"
    /// Context from a screen snapshot (OCR) when the window text via Accessibility is too short.
    public var autocompleteScreenContext: Bool = true
    /// On battery: only rare suggestions / no screen snapshots / short suggestions. All off by default.
    public var autocompleteBatteryRare: Bool = false
    public var autocompleteBatteryNoScreen: Bool = false
    public var autocompleteBatteryShort: Bool = false
    /// «Перевод при наборе»: explicit per-app switch, bundle id -> on/off (nil = never decided).
    public var typeTranslateApps: [String: Bool] = [:]
    /// Turn the mode on by itself where the partner's last message is in another language (apps without an explicit switch).
    public var typeTranslateAuto: Bool = false

    public static let defaultAutocompleteOffApps: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case ollamaURL, model, rulesPath, primaryLanguage, secondaryLanguage, doubleCopyInterval, useGoogleFallback
        case fallback, profiles, activeProfileID
        case remoteURL, remoteHeaders, toneByApp
        case autocomplete, autocompleteModel, autocompleteOffApps
        case autocompleteLength, autocompleteInstructions, autocompleteAppInstructions, autocompleteUseGlossary
        case autocompleteClipboard, autocompleteEmoji, autocorrect, autocompleteLearnStyle, autocompleteFrequency, autocompleteRecordAll, autocompleteWordPreference
        case autocompleteScreenContext, autocompleteBatteryRare, autocompleteBatteryNoScreen, autocompleteBatteryShort, typeTranslateApps, typeTranslateAuto
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
        // Old configs had a Google on/off switch; new ones store the fallback choice.
        if let f = try c.decodeIfPresent(FallbackProvider.self, forKey: .fallback) {
            fallback = f
        } else if let google = try c.decodeIfPresent(Bool.self, forKey: .useGoogleFallback) {
            fallback = google ? .google : .none
        } else {
            fallback = d.fallback
        }
        profiles = try c.decodeIfPresent([GlossaryProfile].self, forKey: .profiles)
            ?? TolkConfig.defaultProfiles(workRules: rulesPath)
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID) ?? d.activeProfileID
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL) ?? d.remoteURL
        remoteHeaders = try c.decodeIfPresent([String: String].self, forKey: .remoteHeaders) ?? d.remoteHeaders
        toneByApp = try c.decodeIfPresent([String: Tone].self, forKey: .toneByApp) ?? d.toneByApp
        autocomplete = try c.decodeIfPresent(Bool.self, forKey: .autocomplete) ?? d.autocomplete
        autocompleteModel = try c.decodeIfPresent(String.self, forKey: .autocompleteModel) ?? d.autocompleteModel
        autocompleteOffApps = try c.decodeIfPresent([String].self, forKey: .autocompleteOffApps) ?? d.autocompleteOffApps
        autocompleteLength = try c.decodeIfPresent(String.self, forKey: .autocompleteLength) ?? d.autocompleteLength
        autocompleteInstructions = try c.decodeIfPresent(String.self, forKey: .autocompleteInstructions) ?? d.autocompleteInstructions
        autocompleteAppInstructions = try c.decodeIfPresent([String: String].self, forKey: .autocompleteAppInstructions) ?? d.autocompleteAppInstructions
        autocompleteUseGlossary = try c.decodeIfPresent(Bool.self, forKey: .autocompleteUseGlossary) ?? d.autocompleteUseGlossary
        autocompleteClipboard = try c.decodeIfPresent(Bool.self, forKey: .autocompleteClipboard) ?? d.autocompleteClipboard
        autocompleteEmoji = try c.decodeIfPresent(Bool.self, forKey: .autocompleteEmoji) ?? d.autocompleteEmoji
        autocorrect = try c.decodeIfPresent(Bool.self, forKey: .autocorrect) ?? d.autocorrect
        autocompleteLearnStyle = try c.decodeIfPresent(Bool.self, forKey: .autocompleteLearnStyle) ?? d.autocompleteLearnStyle
        autocompleteFrequency = try c.decodeIfPresent(String.self, forKey: .autocompleteFrequency) ?? d.autocompleteFrequency
        autocompleteRecordAll = try c.decodeIfPresent(Bool.self, forKey: .autocompleteRecordAll) ?? d.autocompleteRecordAll
        autocompleteWordPreference = try c.decodeIfPresent(String.self, forKey: .autocompleteWordPreference) ?? d.autocompleteWordPreference
        autocompleteScreenContext = try c.decodeIfPresent(Bool.self, forKey: .autocompleteScreenContext) ?? d.autocompleteScreenContext
        autocompleteBatteryRare = try c.decodeIfPresent(Bool.self, forKey: .autocompleteBatteryRare) ?? d.autocompleteBatteryRare
        autocompleteBatteryNoScreen = try c.decodeIfPresent(Bool.self, forKey: .autocompleteBatteryNoScreen) ?? d.autocompleteBatteryNoScreen
        autocompleteBatteryShort = try c.decodeIfPresent(Bool.self, forKey: .autocompleteBatteryShort) ?? d.autocompleteBatteryShort
        typeTranslateApps = try c.decodeIfPresent([String: Bool].self, forKey: .typeTranslateApps) ?? d.typeTranslateApps
        typeTranslateAuto = try c.decodeIfPresent(Bool.self, forKey: .typeTranslateAuto) ?? d.typeTranslateAuto
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ollamaURL, forKey: .ollamaURL)
        try c.encode(model, forKey: .model)
        try c.encode(rulesPath, forKey: .rulesPath)
        try c.encode(primaryLanguage, forKey: .primaryLanguage)
        try c.encode(secondaryLanguage, forKey: .secondaryLanguage)
        try c.encode(doubleCopyInterval, forKey: .doubleCopyInterval)
        try c.encode(fallback, forKey: .fallback)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(activeProfileID, forKey: .activeProfileID)
        try c.encode(remoteURL, forKey: .remoteURL)
        try c.encode(remoteHeaders, forKey: .remoteHeaders)
        try c.encode(toneByApp, forKey: .toneByApp)
        try c.encode(autocomplete, forKey: .autocomplete)
        try c.encode(autocompleteModel, forKey: .autocompleteModel)
        try c.encode(autocompleteOffApps, forKey: .autocompleteOffApps)
        try c.encode(autocompleteLength, forKey: .autocompleteLength)
        try c.encode(autocompleteInstructions, forKey: .autocompleteInstructions)
        try c.encode(autocompleteAppInstructions, forKey: .autocompleteAppInstructions)
        try c.encode(autocompleteUseGlossary, forKey: .autocompleteUseGlossary)
        try c.encode(autocompleteClipboard, forKey: .autocompleteClipboard)
        try c.encode(autocompleteEmoji, forKey: .autocompleteEmoji)
        try c.encode(autocorrect, forKey: .autocorrect)
        try c.encode(autocompleteLearnStyle, forKey: .autocompleteLearnStyle)
        try c.encode(autocompleteFrequency, forKey: .autocompleteFrequency)
        try c.encode(autocompleteRecordAll, forKey: .autocompleteRecordAll)
        try c.encode(autocompleteWordPreference, forKey: .autocompleteWordPreference)
        try c.encode(autocompleteScreenContext, forKey: .autocompleteScreenContext)
        try c.encode(autocompleteBatteryRare, forKey: .autocompleteBatteryRare)
        try c.encode(autocompleteBatteryNoScreen, forKey: .autocompleteBatteryNoScreen)
        try c.encode(autocompleteBatteryShort, forKey: .autocompleteBatteryShort)
        try c.encode(typeTranslateApps, forKey: .typeTranslateApps)
        try c.encode(typeTranslateAuto, forKey: .typeTranslateAuto)
    }

    /// Tone for an app (bundle id), `.auto` if not configured.
    public func tone(forApp bundleID: String?) -> Tone { bundleID.flatMap { toneByApp[$0] } ?? .auto }

    public static let defaultPath = "~/Translate/tolk.json"

    /// Writes the config as pretty JSON (creates the folder). Posts `TolkConfig.didChange`.
    public func save(to path: String = defaultPath) throws {
        let url = URL(fileURLWithPath: expandPath(path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: TolkConfig.didChange, object: nil)
    }

    /// Posted after `save`; the app rebuilds the engine with the new settings.
    public static let didChange = Notification.Name("TolkConfigDidChange")

    public static func load(from path: String = defaultPath) -> TolkConfig {
        let url = URL(fileURLWithPath: expandPath(path))
        guard let data = try? Data(contentsOf: url) else { return TolkConfig() }
        return (try? JSONDecoder().decode(TolkConfig.self, from: data)) ?? TolkConfig()
    }
}
