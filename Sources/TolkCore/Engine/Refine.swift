// Editor pass: a second look at a finished translation. One streamed call to the home model with the source and
// the draft; the answer is the improved translation only. Any failure before the first chunk -> the draft as is.
import Foundation

enum RefinePrompt {
    static func system(from: Language, to: Language, tone: Tone, rules: String) -> String {
        var s = """
        You are a careful native-speaking editor of \(to.englishName). You get a SOURCE text in \(from.englishName) and a DRAFT translation of it into \(to.englishName).
        Return ONLY the improved translation: no comments, quotes or explanations.
        Keep exactly: the meaning, all facts, numbers, dates, names, links, e-mails, IDs, emoji, formatting and the glossary terms below. Do not add or drop information, and do not change the speaker's stance or the type of sentence (a statement stays a statement, a question stays a question, a request stays a request and never becomes an order).
        Keep greetings, sign-offs and forms of address as the draft has them: do not swap one greeting for another ("Hello" stays "Hello", not "Good afternoon"), and do not make them more or less formal.
        Improve the wording: remove calques and word-for-word renderings, fix unnatural word order, unnatural collocations, wrong prepositions, articles, gender and case agreement; use the idiom a native speaker would use in this situation.
        \(Prompt.antiCalque(for: to))
        If the draft is already natural and correct, return it unchanged, character for character.
        """
        if !rules.isEmpty { s += "\n\n# Extra translation rules and glossary (follow strictly)\n" + rules }
        s += "\n\n# Tone\n" + Prompt.tone(tone)
        s += "\n\n# Output language\nWrite in \(to.englishName)."
        return s
    }

    static func user(source: String, translation: String) -> String {
        "SOURCE:\n\(source)\n\nDRAFT:\n\(translation)"
    }
}

extension DefaultTranslationEngine {
    public func refine(source: String, translation: String, from: Language, to: Language, tone: Tone) -> AsyncThrowingStream<String, Error> {
        guard let ollama = primary as? OllamaProvider,
              !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              translation.count <= OllamaProvider.chunkLimit else {
            return AsyncThrowingStream { c in c.yield(translation); c.finish() }
        }
        let rulesBlock = rules.promptBlock(for: source, target: to)
        let system = RefinePrompt.system(from: from, to: to, tone: tone, rules: rulesBlock)
        let user = RefinePrompt.user(source: source, translation: translation)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var produced = false
                do {
                    if await ollama.isAvailable() == false { throw TolkError.unavailable("offline") }
                    if await ollama.ensureReady(timeout: Self.coldLoadWait) == .stillLoading { throw TolkError.unavailable("cold") }
                    let req = try ollama.makeChatRequest(system: system, user: user)
                    let inner = AsyncThrowingStream<String, Error> { c in
                        let t = Task {
                            do { try await ollama.streamRequest(req, c); c.finish() } catch { c.finish(throwing: error) }
                        }
                        c.onTermination = { _ in t.cancel() }
                    }
                    for try await chunk in inner {
                        try Task.checkCancellation()
                        produced = true
                        continuation.yield(chunk)
                    }
                    if !produced { continuation.yield(translation) }
                    continuation.finish()
                } catch {
                    if error is CancellationError || Task.isCancelled { continuation.finish(throwing: error); return }
                    // Mid-stream failure: the text shown so far cannot be taken back, end quietly.
                    if !produced { continuation.yield(translation) }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
