import Foundation

/// Qwen (Ollama on vkbox) first; Google when vkbox is off, Ollama is stopped (e.g. while gaming),
/// or the request fails before the first chunk.
public final class DefaultTranslationEngine: TranslationEngine, @unchecked Sendable {
    public let config: TolkConfig
    public let rules: RulesStore
    public let primary: TranslationProvider
    public let fallback: TranslationProvider?

    public convenience init(config: TolkConfig) {
        let rules = RulesStore(path: config.rulesPath)
        self.init(config: config, rules: rules,
                  primary: OllamaProvider(config: config, rules: rules),
                  fallback: config.useGoogleFallback ? GoogleProvider() : nil)
    }

    public init(config: TolkConfig, rules: RulesStore, primary: TranslationProvider, fallback: TranslationProvider?) {
        self.config = config; self.rules = rules; self.primary = primary; self.fallback = fallback
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        let resolved = LanguageDetector.resolve(request, config: config)
        let primary = self.primary, fallback = self.fallback
        return AsyncThrowingStream { continuation in
            let task = Task {
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
                            for try await chunk in primary.translate(resolved) {
                                try Task.checkCancellation()
                                gotChunk = true
                                continuation.yield(.delta(chunk))
                            }
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
                        continuation.yield(.delta(chunk))
                    }
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
        return Prompt.system(for: r, rules: rules.promptBlock(for: r.text + "\n" + (r.replyTo ?? "")))
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
