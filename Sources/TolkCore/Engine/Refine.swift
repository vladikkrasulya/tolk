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

/// Cheap safety net against the editor's known failure modes: a question turned into a statement/order and a swapped
/// greeting. When it trips, the original translation is kept.
enum RefineGuard {
    static let greetings: Set<String> = [
        "hello", "hi", "hey", "dear", "good", "greetings", "привет", "здравствуйте", "здравствуй", "добрый", "доброе", "добрая",
        "доброго", "приветствую", "вітаю", "привіт", "доброго", "добрий", "добре", "доброї", "вітання",
    ]

    static func firstWord(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = t.prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
        return word.lowercased()
    }

    /// Text up to and including the first line/sentence start words that make a greeting: first word + second for "Good …".
    static func greetingKey(_ s: String) -> String? {
        let words = s.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace })
        guard let w0 = words.first else { return nil }
        let a = firstWord(String(w0))
        guard greetings.contains(a) else { return nil }
        if ["good", "добрый", "доброе", "добрая", "доброго", "добрий", "добре", "доброї"].contains(a), words.count > 1 {
            return a + " " + firstWord(String(words[1]))
        }
        return a
    }

    static func endsWithQuestion(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'»”)")))
        return t.hasSuffix("?")
    }

    static func accepts(draft: String, edited: String) -> Bool {
        if edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if endsWithQuestion(draft) && !endsWithQuestion(edited) { return false }
        if let g = greetingKey(draft), greetingKey(edited) != g { return false }
        return true
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
                    // Buffered: the guard below may reject the whole edit, which cannot be done after chunks are shown.
                    var edited = ""
                    for try await chunk in inner {
                        try Task.checkCancellation()
                        edited += chunk
                    }
                    produced = true
                    continuation.yield(RefineGuard.accepts(draft: translation, edited: edited) ? edited : translation)
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
