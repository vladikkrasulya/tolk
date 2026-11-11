// Shared contracts between the engine (TolkCore/Engine), input (Tolk/Input) and UI (Tolk/UI).
// Change only by agreement: every part of the app compiles against these types.
import Foundation

public enum Language: String, CaseIterable, Codable, Sendable {
    // Order = order in menus: the four main languages first (`Language.main`), then the rest.
    case ukrainian = "uk", english = "en", russian = "ru", polish = "pl"
    case german = "de", french = "fr", spanish = "es", italian = "it", portuguese = "pt"
    case czech = "cs", dutch = "nl", romanian = "ro", bulgarian = "bg"
    case turkish = "tr", kazakh = "kk", georgian = "ka", hebrew = "he", arabic = "ar"
    case chinese = "zh", japanese = "ja", korean = "ko", hindi = "hi", indonesian = "id", vietnamese = "vi"

    /// The languages at the top of every language list, in this order.
    public static let main: [Language] = [.ukrainian, .english, .russian, .polish]
    /// The other languages, by their Russian name.
    public static var others: [Language] { allCases.filter { !main.contains($0) }.sorted { $0.russianName < $1.russianName } }

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
    /// «Сформулировать»: ready message from the user's points + honest back-translation.
    func compose(points: String, tone: ComposeTone, to: Language, partnerMessage: String?, threadContext: String?) async throws -> ComposeResult
    /// The request for the reply flow (partner's message + the user's answer); stream it through `translate`.
    func replyRequest(message: String, reply: String, tone: Tone) -> TranslationRequest
    /// Glossary entries that fire for `text` when translating into `target` (no model, instant).
    func glossaryHits(in text: String, target: Language) -> [GlossaryHit]
}

public extension TranslationEngine {
    func compose(points: String, tone: ComposeTone, to: Language, partnerMessage: String?) async throws -> ComposeResult {
        try await compose(points: points, tone: tone, to: to, partnerMessage: partnerMessage, threadContext: nil)
    }
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
    func compose(points: String, tone: ComposeTone, to: Language, partnerMessage: String?, threadContext: String?) async throws -> ComposeResult {
        throw TolkError.unavailable("«Сформулировать» недоступно для этого движка")
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
    public var ollamaURL: String = "http://127.0.0.1:11434"
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
    public var autocompleteModel: String = "~/Library/Application Support/Tolk/models/gemma-4-E2B-abl-Q4_K.gguf"
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
    /// «Patient second look»: after an empty answer and a pause, show the continuation the model was less sure about.
    public var autocompletePatient: Bool = true
    /// The pause (seconds) before that second look.
    public var autocompletePatientDelay: Double = 0.65
    /// Fields that do not report the caret (web text areas): find it on a snapshot of the field and put the bubble there.
    public var autocompleteCaretBubble: Bool = true
    /// Detailed log: every autocomplete decision is written (default: only events that explain a problem).
    public var verboseLog: Bool = false
    /// Minutes after the last translation during which a model that fell out of the server's memory is reloaded
    /// in the background (0 = never: the first translation after a pause waits for the load).
    public var keepWarmMinutes: Int = 15

    // Fine tuning of the models (Настройки → «Тонкая настройка»). The defaults are the measured values.
    /// Translation sampling temperature, 0…1. Low = the same, more literal wording every time.
    public var translateTemperature: Double = 0.1
    /// Fixed seed: the same text gets the same translation every time.
    public var translateFixedSeed: Bool = true
    /// Keep finished translations in memory for a day and answer repeats instantly.
    public var translateCache: Bool = true
    /// Suggestions: use the two bars below instead of the «Частота» preset.
    public var autocompleteCustomConfidence: Bool = false
    /// Minimum probability of the first word / of every later word of a suggestion, 0.05…0.95.
    public var autocompleteFirstProb: Double = 0.3
    public var autocompleteNextProb: Double = 0.3
    /// Bar for the first word of the suggestion shown after a pause, 0.02…0.5.
    public var autocompletePatientProb: Double = 0.08
    /// Suggestion sampling temperature, 0…1 (0 = always the most likely word).
    public var autocompleteTemperature: Double = 0
    /// Context window of the suggestion model, tokens: 2048, 4096 or 8192.
    public var autocompleteContextSize: Int = 4096
    /// Letters typed in the field before the first suggestion is asked for, 2…20.
    public var autocompleteMinChars: Int = 4
    /// The base instruction of the suggestion model, in the user's wording. Empty = the built-in one
    /// (`AutocompletePrompt.defaultRules`).
    public var autocompleteBaseRules: String = ""
    /// The user's rewordings of the built-in instructions, block id → text (see `PromptCatalog`). Missing = built-in.
    public var prompts: [String: String] = [:]
    /// Run the editor pass by itself after a translation: "off", "formal" (contracts, licences, official notices —
    /// where the model slips on case agreement in long sentences) or "always".
    public var autoEditor: String = "formal"

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
        case autocompletePatient, autocompletePatientDelay, autocompleteCaretBubble, verboseLog, keepWarmMinutes
        case translateTemperature, translateFixedSeed, translateCache, autocompleteCustomConfidence, autocompleteFirstProb
        case autocompleteNextProb, autocompletePatientProb, autocompleteTemperature, autocompleteContextSize, autocompleteMinChars
        case autocompleteBaseRules, prompts, autoEditor
    }

    /// Every key is optional: `{"model": "x"}` keeps all other defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TolkConfig()
        ollamaURL = c.lenient(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        model = c.lenient(String.self, forKey: .model) ?? d.model
        rulesPath = c.lenient(String.self, forKey: .rulesPath) ?? d.rulesPath
        primaryLanguage = c.lenient(Language.self, forKey: .primaryLanguage) ?? d.primaryLanguage
        secondaryLanguage = c.lenient(Language.self, forKey: .secondaryLanguage) ?? d.secondaryLanguage
        doubleCopyInterval = c.lenient(Double.self, forKey: .doubleCopyInterval) ?? d.doubleCopyInterval
        // Old configs had a Google on/off switch; new ones store the fallback choice.
        if let f = c.lenient(FallbackProvider.self, forKey: .fallback) {
            fallback = f
        } else if let google = c.lenient(Bool.self, forKey: .useGoogleFallback) {
            fallback = google ? .google : .none
        } else {
            fallback = d.fallback
        }
        profiles = c.lenient([GlossaryProfile].self, forKey: .profiles)
            ?? TolkConfig.defaultProfiles(workRules: rulesPath)
        activeProfileID = c.lenient(String.self, forKey: .activeProfileID) ?? d.activeProfileID
        remoteURL = c.lenient(String.self, forKey: .remoteURL) ?? d.remoteURL
        remoteHeaders = c.lenient([String: String].self, forKey: .remoteHeaders) ?? d.remoteHeaders
        toneByApp = c.lenient([String: Tone].self, forKey: .toneByApp) ?? d.toneByApp
        autocomplete = c.lenient(Bool.self, forKey: .autocomplete) ?? d.autocomplete
        autocompleteModel = c.lenient(String.self, forKey: .autocompleteModel) ?? d.autocompleteModel
        autocompleteOffApps = c.lenient([String].self, forKey: .autocompleteOffApps) ?? d.autocompleteOffApps
        autocompleteLength = c.lenient(String.self, forKey: .autocompleteLength) ?? d.autocompleteLength
        autocompleteInstructions = c.lenient(String.self, forKey: .autocompleteInstructions) ?? d.autocompleteInstructions
        autocompleteAppInstructions = c.lenient([String: String].self, forKey: .autocompleteAppInstructions) ?? d.autocompleteAppInstructions
        autocompleteUseGlossary = c.lenient(Bool.self, forKey: .autocompleteUseGlossary) ?? d.autocompleteUseGlossary
        autocompleteClipboard = c.lenient(Bool.self, forKey: .autocompleteClipboard) ?? d.autocompleteClipboard
        autocompleteEmoji = c.lenient(Bool.self, forKey: .autocompleteEmoji) ?? d.autocompleteEmoji
        autocorrect = c.lenient(Bool.self, forKey: .autocorrect) ?? d.autocorrect
        autocompleteLearnStyle = c.lenient(Bool.self, forKey: .autocompleteLearnStyle) ?? d.autocompleteLearnStyle
        autocompleteFrequency = c.lenient(String.self, forKey: .autocompleteFrequency) ?? d.autocompleteFrequency
        autocompleteRecordAll = c.lenient(Bool.self, forKey: .autocompleteRecordAll) ?? d.autocompleteRecordAll
        autocompleteWordPreference = c.lenient(String.self, forKey: .autocompleteWordPreference) ?? d.autocompleteWordPreference
        autocompleteScreenContext = c.lenient(Bool.self, forKey: .autocompleteScreenContext) ?? d.autocompleteScreenContext
        autocompleteBatteryRare = c.lenient(Bool.self, forKey: .autocompleteBatteryRare) ?? d.autocompleteBatteryRare
        autocompleteBatteryNoScreen = c.lenient(Bool.self, forKey: .autocompleteBatteryNoScreen) ?? d.autocompleteBatteryNoScreen
        autocompleteBatteryShort = c.lenient(Bool.self, forKey: .autocompleteBatteryShort) ?? d.autocompleteBatteryShort
        typeTranslateApps = c.lenient([String: Bool].self, forKey: .typeTranslateApps) ?? d.typeTranslateApps
        typeTranslateAuto = c.lenient(Bool.self, forKey: .typeTranslateAuto) ?? d.typeTranslateAuto
        autocompletePatient = c.lenient(Bool.self, forKey: .autocompletePatient) ?? d.autocompletePatient
        autocompletePatientDelay = min(3, max(0.3, c.lenient(Double.self, forKey: .autocompletePatientDelay) ?? d.autocompletePatientDelay))
        autocompleteCaretBubble = c.lenient(Bool.self, forKey: .autocompleteCaretBubble) ?? d.autocompleteCaretBubble
        verboseLog = c.lenient(Bool.self, forKey: .verboseLog) ?? d.verboseLog
        keepWarmMinutes = max(0, c.lenient(Int.self, forKey: .keepWarmMinutes) ?? d.keepWarmMinutes)
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        translateTemperature = clamp(c.lenient(Double.self, forKey: .translateTemperature) ?? d.translateTemperature, 0, 1)
        translateFixedSeed = c.lenient(Bool.self, forKey: .translateFixedSeed) ?? d.translateFixedSeed
        translateCache = c.lenient(Bool.self, forKey: .translateCache) ?? d.translateCache
        autocompleteCustomConfidence = c.lenient(Bool.self, forKey: .autocompleteCustomConfidence) ?? d.autocompleteCustomConfidence
        autocompleteFirstProb = clamp(c.lenient(Double.self, forKey: .autocompleteFirstProb) ?? d.autocompleteFirstProb, 0.05, 0.95)
        autocompleteNextProb = clamp(c.lenient(Double.self, forKey: .autocompleteNextProb) ?? d.autocompleteNextProb, 0.05, 0.95)
        autocompletePatientProb = clamp(c.lenient(Double.self, forKey: .autocompletePatientProb) ?? d.autocompletePatientProb, 0.02, 0.5)
        autocompleteTemperature = clamp(c.lenient(Double.self, forKey: .autocompleteTemperature) ?? d.autocompleteTemperature, 0, 1)
        let ctx = c.lenient(Int.self, forKey: .autocompleteContextSize) ?? d.autocompleteContextSize
        autocompleteContextSize = [2048, 4096, 8192].contains(ctx) ? ctx : d.autocompleteContextSize
        autocompleteBaseRules = c.lenient(String.self, forKey: .autocompleteBaseRules) ?? d.autocompleteBaseRules
        prompts = c.lenient([String: String].self, forKey: .prompts) ?? d.prompts
        let ae = c.lenient(String.self, forKey: .autoEditor) ?? d.autoEditor
        autoEditor = ["off", "formal", "always"].contains(ae) ? ae : d.autoEditor
        autocompleteMinChars = min(20, max(2, c.lenient(Int.self, forKey: .autocompleteMinChars) ?? d.autocompleteMinChars))
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
        try c.encode(autocompletePatient, forKey: .autocompletePatient)
        try c.encode(autocompletePatientDelay, forKey: .autocompletePatientDelay)
        try c.encode(autocompleteCaretBubble, forKey: .autocompleteCaretBubble)
        try c.encode(verboseLog, forKey: .verboseLog)
        try c.encode(keepWarmMinutes, forKey: .keepWarmMinutes)
        try c.encode(translateTemperature, forKey: .translateTemperature)
        try c.encode(translateFixedSeed, forKey: .translateFixedSeed)
        try c.encode(translateCache, forKey: .translateCache)
        try c.encode(autocompleteCustomConfidence, forKey: .autocompleteCustomConfidence)
        try c.encode(autocompleteFirstProb, forKey: .autocompleteFirstProb)
        try c.encode(autocompleteNextProb, forKey: .autocompleteNextProb)
        try c.encode(autocompletePatientProb, forKey: .autocompletePatientProb)
        try c.encode(autocompleteTemperature, forKey: .autocompleteTemperature)
        try c.encode(autocompleteContextSize, forKey: .autocompleteContextSize)
        try c.encode(autocompleteMinChars, forKey: .autocompleteMinChars)
        try c.encode(autocompleteBaseRules, forKey: .autocompleteBaseRules)
        try c.encode(prompts, forKey: .prompts)
        try c.encode(autoEditor, forKey: .autoEditor)
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

    /// A missing file = defaults. A file that cannot be parsed at all is copied to `<name>.corrupt` first (the next
    /// `save()` would overwrite the user's hand-written settings); one bad value only loses that value (see `lenient`).
    public static func load(from path: String = defaultPath) -> TolkConfig {
        let url = URL(fileURLWithPath: expandPath(path))
        guard let data = try? Data(contentsOf: url) else { return TolkConfig() }
        if let cfg = try? JSONDecoder().decode(TolkConfig.self, from: data) { return cfg }
        let backup = url.appendingPathExtension("corrupt")
        if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        return TolkConfig()
    }
}


extension KeyedDecodingContainer {
    /// Like `decodeIfPresent`, but a value of the wrong type / an unknown enum case reads as «absent» instead of
    /// failing the whole config (which used to reset every setting, including the privacy-relevant fallback).
    fileprivate func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
