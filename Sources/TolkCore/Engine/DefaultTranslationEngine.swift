import Foundation

/// Qwen (Ollama on vkbox) first; Google when vkbox is off, Ollama is stopped (e.g. while gaming),
/// or the request fails before the first chunk.
public final class DefaultTranslationEngine: TranslationEngine, @unchecked Sendable {
    public let config: TolkConfig
    public let rules: RulesStore
    public let primary: TranslationProvider
    public let fallback: TranslationProvider?

    public convenience init(config: TolkConfig) {
        let rules = RulesStore(path: config.effectiveRulesPath)
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
        self.config = config; self.rules = rules; self.primary = primary; self.fallback = fallback
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        let resolved = LanguageDetector.resolve(request, config: config)
        let primary = self.primary, fallback = self.fallback
        return AsyncThrowingStream { continuation in
            let task = Task {
                let t0 = Date()
                var firstAt: Date?
                var chunks = 0
                let usage = UsageBox()
                func stats(_ provider: TranslationProvider, reason: String?) -> TranslationStats {
                    let route: TranslationStats.Route
                    switch provider {
                    case let o as OllamaProvider: route = o.isUsingRemote ? .remote : .home
                    case is AppleTranslationProvider: route = .device
                    default: route = .web
                    }
                    let exact = usage.completionTokens
                    return TranslationStats(provider: provider.name, route: route,
                                            firstChunk: firstAt.map { $0.timeIntervalSince(t0) },
                                            total: Date().timeIntervalSince(t0),
                                            outputTokens: exact ?? (provider is OllamaProvider ? chunks : nil),
                                            tokensExact: exact != nil, fallbackReason: reason)
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
                        do {
                            try await UsageBox.$current.withValue(usage) {
                                for try await chunk in primary.translate(resolved) {
                                    try Task.checkCancellation()
                                    if firstAt == nil { firstAt = Date() }
                                    chunks += 1
                                    gotChunk = true
                                    continuation.yield(.delta(chunk))
                                }
                            }
                            continuation.yield(.stats(stats(primary, reason: nil)))
                            continuation.yield(.finished); continuation.finish(); return
                        } catch {
                            // Mid-stream failure or cancellation: nothing sensible to fall back to.
                            if gotChunk || error is CancellationError || Task.isCancelled { throw error }
                            failure = Self.describe(error)
                        }
                    } else {
                        failure = "vkbox недоступен (Ollama не отвечает)"
                    }
                    // Google can only translate; a polish request has no fallback.
                    guard let fallback, resolved.mode == .translate else {
                        throw TolkError.unavailable(failure ?? "\(primary.name) недоступен")
                    }
                    try Task.checkCancellation()
                    continuation.yield(.fellBack(from: primary.name, reason: failure ?? ""))
                    continuation.yield(.started(provider: fallback.name, source: resolved.source, target: resolved.target))
                    for try await chunk in fallback.translate(resolved) {
                        try Task.checkCancellation()
                        if firstAt == nil { firstAt = Date() }
                        continuation.yield(.delta(chunk))
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
        guard let ollama = primary as? OllamaProvider, await ollama.isAvailable() else { return [] }
        return await ollama.notes(source: source, translation: translation, from: from, to: to)
    }

    public func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String] {
        guard let ollama = primary as? OllamaProvider, await ollama.isAvailable() else { return [] }
        return await ollama.alternatives(for: fragment, in: translation, source: source, from: from, to: to)
    }

    /// Dev: the exact system prompt a request would get (CLI --show-prompt).
    public func debugSystemPrompt(for request: TranslationRequest) -> String {
        let r = LanguageDetector.resolve(request, config: config)
        return Prompt.system(for: r, rules: rules.promptBlock(for: r.text + "\n" + (r.replyTo ?? ""), target: r.target))
    }

    public func addGlossaryTerm(source: String, translation: String) throws {
        try rules.addTerm(source: source, translation: translation)
    }

    static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return "Модель: таймаут"
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost:
                return "vkbox недоступен (\(u.localizedDescription))"
            default: return "Модель: \(u.localizedDescription)"
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
