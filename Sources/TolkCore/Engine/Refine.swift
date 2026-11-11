// Editor pass: a second look at a finished translation. One streamed call to the home model with the source and
// the draft; the answer is the improved translation only. Any failure before the first chunk -> the draft as is.
import Foundation

enum RefinePrompt {
    static func system(from: Language, to: Language, tone: Tone, rules: String, calques: [CalqueDetector.Hit] = [], formal: Bool = false) -> String {
        var s = """
        You are a careful native-speaking editor of \(to.englishName). You get a SOURCE text in \(from.englishName) and a DRAFT translation of it into \(to.englishName).
        Return ONLY the improved translation: no comments, quotes or explanations.
        \(calques.isEmpty ? "If there is nothing to fix, reply with exactly: OK" : "")
        \(PromptCatalog.text("refine.rules"))
        \(Prompt.antiCalque(for: to))
        \(calques.isEmpty ? "If the draft is already natural and correct, reply with exactly the two letters OK and nothing else (do not repeat the text). Change the draft only for a real error or a clear calque, never for style or taste." : "If the draft is already natural and correct, return it unchanged, character for character.")
        """
        // An official text: the editor works by the same rules as the translator (established formulas, agreement).
        let formalNote = PromptCatalog.filled("translate.formal", ["target": to.englishName])
        if formal, !formalNote.isEmpty { s += "\n\n# Official text\n" + formalNote }
        if !calques.isEmpty { s += "\n\n" + CalqueDetector.promptHint(for: calques) }
        if !rules.isEmpty { s += "\n\n# Extra translation rules and glossary (follow strictly)\n" + rules }
        s += "\n\n# Tone\n" + Prompt.tone(tone)
        s += "\n\n# Output language\nWrite in \(to.englishName)."
        return s
    }

    static func user(source: String, translation: String) -> String {
        "SOURCE:\n\(source)\n\nDRAFT:\n\(translation)"
    }
}

/// The proofreader may only touch grammar: a result that is much shorter or longer, lost a paragraph or a number is
/// not a proofreading and is thrown away.
enum Proofread {
    static func accepts(before: String, after: String) -> Bool {
        let a = after.trimmingCharacters(in: .whitespacesAndNewlines), b = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let ratio = Double(a.count) / Double(b.count)
        guard ratio > 0.9, ratio < 1.1 else { return false }
        guard a.components(separatedBy: "\n").count == b.components(separatedBy: "\n").count else { return false }
        func digits(_ s: String) -> String { s.filter(\.isNumber) }
        return digits(a) == digits(b)
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

    /// The editor's «nothing to fix» answer.
    static func isOK(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!\"'«»`")))
        return t.caseInsensitiveCompare("OK") == .orderedSame
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
        let calques = CalqueDetector.detect(in: translation, language: to)
        let formal = FormalText.looksFormal(source)
        let system = RefinePrompt.system(from: from, to: to, tone: tone, rules: rulesBlock, calques: calques, formal: formal)
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
                    var result = RefineGuard.isOK(edited) ? translation : (RefineGuard.accepts(draft: translation, edited: edited) ? edited : translation)
                    // Official text: a last grammar-only reading. The editor works on meaning and wording and lets
                    // agreement slips through («прилагаться ко всех копиях»); a proofreader that sees only the
                    // translation and may change nothing but grammar catches them.
                    if formal {
                        let proof = PromptCatalog.filled("refine.proofread", ["target": to.englishName])
                        if !proof.isEmpty,
                           let fixed = try? await ollama.chatContent(system: proof, user: result, json: false, maxTokens: 3000, temperature: 0.1, timeout: 90),
                           Proofread.accepts(before: result, after: fixed) {
                            result = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    continuation.yield(result)
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
