import Foundation

/// Qwen (Ollama on the home server) first; Google when the home server is off, Ollama is stopped (e.g. while gaming),
/// or the request fails before the first chunk.
public final class DefaultTranslationEngine: TranslationEngine, @unchecked Sendable {
    public let config: TolkConfig
    public let rules: RulesStore
    public let primary: TranslationProvider
    public let fallback: TranslationProvider?
    /// Finished translations of the main model (memory only, never on disk).
    let cache: ResultCache<CachedTranslation>
    let notesCache: ResultCache<[TranslationNote]>

    public convenience init(config: TolkConfig) {
        // Fresh install: the «Дом» file does not exist yet — built-in neutral rules are used in memory.
        let rules = RulesStore(path: config.effectiveRulesPath,
                               builtIn: config.activeProfile.id == "home" ? DefaultRules.home : nil)
        let fallback: TranslationProvider?
        switch config.fallback {
        case .google: fallback = GoogleProvider()
        case .apple: fallback = AppleTranslationProvider()
        case .none: fallback = nil
        }
        self.init(config: config, rules: rules,
                  primary: OllamaProvider(config: config, rules: rules),
                  fallback: fallback)
    }

    public init(config: TolkConfig, rules: RulesStore, primary: TranslationProvider, fallback: TranslationProvider?) {
        PromptCatalog.overrides = config.prompts   // the instructions in force are the ones of the newest engine
        self.config = config; self.rules = rules; self.primary = primary; self.fallback = fallback
        self.cache = ResultCache(); self.notesCache = ResultCache()
    }

    /// Test hook: engine with its own caches (small limits, fake clock).
    init(config: TolkConfig, rules: RulesStore, primary: TranslationProvider, fallback: TranslationProvider?,
         cache: ResultCache<CachedTranslation>, notesCache: ResultCache<[TranslationNote]>) {
        self.config = config; self.rules = rules; self.primary = primary; self.fallback = fallback
        self.cache = cache; self.notesCache = notesCache
    }

    /// Which model answers: part of every cache key.
    var cacheIdentity: String {
        (primary as? OllamaProvider).map { "ollama:\($0.model):t\($0.temperature):s\($0.fixedSeed)" } ?? "provider:" + primary.name
    }

    func systemPrompt(for r: ResolvedRequest) -> String {
        let selector = [r.text, r.replyTo, r.context?.source].compactMap { $0 }.joined(separator: "\n")
        return Prompt.system(for: r, rules: rules.promptBlock(for: selector, target: r.target))
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        ModelUsage.markUsed()
        let resolved = LanguageDetector.resolve(request, config: config)
        let primary = self.primary, fallback = self.fallback
        let cache = self.cache
        let key = TranslationCacheKey.translation(resolved, systemPrompt: systemPrompt(for: resolved), identity: cacheIdentity)
        let isEmpty = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Without a fixed seed a repeat is meant to give a new wording, so the cache would defeat it.
        if !request.bypassCache, config.translateCache, config.translateFixedSeed, !isEmpty, let hit = cache.get(key) {
            return AsyncThrowingStream { c in
                c.yield(.started(provider: hit.provider, source: resolved.source, target: resolved.target))
                c.yield(.delta(hit.text))
                var st = TranslationStats(provider: hit.provider, route: hit.route, firstChunk: 0, total: 0,
                                          outputTokens: hit.outputTokens, tokensExact: false, fallbackReason: nil)
                st.warnings = hit.warnings; st.fromCache = true
                c.yield(.stats(st)); c.yield(.finished); c.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                let t0 = Date()
                var firstAt: Date?
                var chunks = 0
                var produced = ""
                let usage = UsageBox()
                func stats(_ provider: TranslationProvider, reason: String?) -> TranslationStats {
                    let route: TranslationStats.Route
                    switch provider {
                    case let o as OllamaProvider: route = o.isUsingRemote ? .remote : .home
                    case is AppleTranslationProvider: route = .device
                    default: route = .web
                    }
                    let exact = usage.completionTokens
                    var st = TranslationStats(provider: provider.name, route: route,
                                              firstChunk: firstAt.map { $0.timeIntervalSince(t0) },
                                              total: Date().timeIntervalSince(t0),
                                              outputTokens: exact ?? (provider is OllamaProvider ? chunks : nil),
                                              tokensExact: exact != nil, fallbackReason: reason)
                    // Only the new text and its translation are compared when a context was given.
                    if resolved.mode == .translate {
                        st.warnings = TranslationCheck.warnings(source: resolved.text, translation: produced,
                                                                from: resolved.source, to: resolved.target)
                        st.warnings += CalqueDetector.warnings(in: produced, language: resolved.target)
                    }
                    return st
                }
                do {
                    guard !resolved.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.yield(.started(provider: primary.name, source: resolved.source, target: resolved.target))
                        continuation.yield(.finished); continuation.finish(); return
                    }
                    var failure: String?
                    if await primary.isAvailable() {
                        continuation.yield(.started(provider: primary.name, source: resolved.source, target: resolved.target))
                        var gotChunk = false
                        var coldFailure: String?
                        // Cold model: wait for the load in a separate request (never cut by our timeout,
                        // never cancelled by the user closing the popup). Too long -> fall back, load goes on.
                        if let ollama = primary as? OllamaProvider, await ollama.ensureReady(timeout: Self.coldLoadWait) == .stillLoading {
                            try Task.checkCancellation()
                            coldFailure = "модель ещё загружается на сервере (холодный старт), прогрев продолжается"
                        }
                        if coldFailure == nil { do {
                            try await UsageBox.$current.withValue(usage) {
                                for try await chunk in ChatHeaderKeeper.stream(EntityMasking.stream(resolved, provider: primary), source: resolved.text) {
                                    try Task.checkCancellation()
                                    if firstAt == nil { firstAt = Date() }
                                    chunks += 1
                                    gotChunk = true
                                    produced += chunk
                                    continuation.yield(.delta(chunk))
                                }
                            }
                            // Only a fully finished translation of the main model is kept.
                            try Task.checkCancellation()
                            let st = stats(primary, reason: nil)
                            if !produced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                cache.set(key, CachedTranslation(text: produced, provider: primary.name, route: st.route,
                                                                 warnings: st.warnings, outputTokens: st.outputTokens),
                                          cost: produced.utf8.count)
                            }
                            continuation.yield(.stats(st))
                            continuation.yield(.finished); continuation.finish(); return
                        } catch {
                            // Mid-stream failure or cancellation: nothing sensible to fall back to.
                            if error is CancellationError || Task.isCancelled { throw error }
                            if gotChunk { throw TolkError.unavailable("Перевод прервался на середине: \(Self.describe(error))") }
                            failure = Self.describe(error)
                        } } else { failure = coldFailure }
                    } else {
                        failure = "сервер недоступен (Ollama не отвечает)"
                    }
                    // Google can only translate; a polish request has no fallback.
                    guard let fallback, resolved.mode == .translate else {
                        let why = failure ?? "\(primary.name) недоступен"
                        throw TolkError.unavailable(resolved.mode == .polish
                            ? "«Причесать» работает только через модель на сервере, а она сейчас недоступна: \(why)"
                            : "Перевод не получился: \(why). Запасной перевод выключен (Настройки → Перевод).")
                    }
                    try Task.checkCancellation()
                    continuation.yield(.fellBack(from: primary.name, reason: failure ?? ""))
                    continuation.yield(.started(provider: fallback.name, source: resolved.source, target: resolved.target))
                    produced = ""
                    do {
                        for try await chunk in ChatHeaderKeeper.stream(fallback.translate(resolved), source: resolved.text) {
                            try Task.checkCancellation()
                            if firstAt == nil { firstAt = Date() }
                            produced += chunk
                            continuation.yield(.delta(chunk))
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw error }
                        // No silent trip to the cloud: Apple was chosen as the private fallback.
                        throw TolkError.unavailable("\(failure ?? "сервер недоступен"). Запасной перевод \(fallback.name): \(Self.describe(error))" + Self.googleHint(for: fallback))
                    }
                    continuation.yield(.stats(stats(fallback, reason: failure)))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote] {
        // Only if the model is already in memory: an optional footnote must never trigger a 30 s cold load.
        let key = TranslationCacheKey.notes(source: source, translation: translation, from: from, to: to,
                                            rules: rules.promptBlock(for: source), identity: cacheIdentity)
        if let hit = notesCache.get(key) { return hit }
        guard let ollama = primary as? OllamaProvider, await ollama.isModelLoaded() == true else { return [] }
        let result = await ollama.notes(source: source, translation: translation, from: from, to: to)
        // An empty list is also what a failed request returns, so only real answers are kept.
        if !result.isEmpty { notesCache.set(key, result, cost: result.reduce(0) { $0 + $1.note.utf8.count + $1.term.utf8.count + 64 }) }
        return result
    }

    public func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String] {
        guard let ollama = primary as? OllamaProvider, await ollama.isModelLoaded() == true else { return [] }
        return await ollama.alternatives(for: fragment, in: translation, source: source, from: from, to: to)
    }

    /// Dev: the exact system prompt a request would get (CLI --show-prompt).
    public func debugSystemPrompt(for request: TranslationRequest) -> String {
        let r = LanguageDetector.resolve(request, config: config)
        return systemPrompt(for: r)
    }

    public func glossaryHits(in text: String, target: Language) -> [GlossaryHit] {
        rules.glossaryHits(in: text, target: target)
    }

    public func addGlossaryTerm(source: String, translation: String) throws {
        try rules.addTerm(source: source, translation: translation)
    }

    /// How long a user request waits for a cold model before switching to the fallback (the load goes on).
    static let coldLoadWait: TimeInterval = 75

    private static let hintLock = NSLock()
    nonisolated(unsafe) private static var hintShown = false
    /// One-time advice (per launch) when the private fallback (Apple) failed: how to enable Google.
    static func googleHint(for fallback: TranslationProvider) -> String {
        guard fallback is AppleTranslationProvider else { return "" }
        let first = hintLock.withLock { let f = !hintShown; hintShown = true; return f }
        return first ? "\nСовет: если приватность не критична, выберите запасной «Google» в Настройки → Перевод — тогда перевод пойдёт через интернет." : ""
    }

    static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return "модель не отвечает (таймаут)"
            case .networkConnectionLost: return "связь с сервером оборвалась"
            case .cannotConnectToHost, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed:
                return "сервер недоступен (нет связи с сетью или сервером)"
            case .cancelled: return "запрос отменён"
            default: return "ошибка сети (\(u.code.rawValue))"
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}


/// When the user last asked for a translation. The background health check reloads the model on the home server only if the
/// user translated recently: a model that was unloaded on purpose (the home server is used for games) must stay unloaded.
public enum ModelUsage {
    nonisolated(unsafe) private static var last: Date?
    private static let lock = NSLock()
    public static func markUsed(at date: Date = Date()) { lock.lock(); last = date; lock.unlock() }
    public static func usedRecently(within seconds: TimeInterval = 15 * 60, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let last else { return false }
        return now.timeIntervalSince(last) <= seconds
    }
    /// For the self-test.
    public static func reset() { lock.lock(); last = nil; lock.unlock() }
}
