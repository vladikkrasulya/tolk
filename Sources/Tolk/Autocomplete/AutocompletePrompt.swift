// What we send to the local model and how its raw continuation becomes a suggestion.
// Measurements and examples: ~/Translate/test-corpus/autocomplete-eval.md
//
// Chosen after benchmarking Gemma 4 E4B base (Q4_K_M) vs it (QAT q4_0) on 36 adtech/chat fragments (EN+RU):
// the it model with a short "Message in <app>:" header and NO chat template gave the most sensible,
// same-language continuations; the base GGUF drifted into noise ("100%", dates, "<code>") and often
// answered nothing. The prompt must not end with a space: after a trailing space both models jump to
// digits/dates, so the space is stripped here and the model's own leading space is handled in `clean`.
import AppKit
import Foundation
import TolkCore

enum AutocompletePrompt {
    /// Tokens to ask for; the suggestion is cut to a few words anyway (Russian needs ~2 tokens per word).
    /// Set by the [prefs] section from the length setting (`PromptPrefs.maxTokens`): 14 for short/medium, ~27 for long.
    nonisolated(unsafe) static var maxTokens = 14

    // MARK: - Format switches (autocomplete-eval, «healing / prefill» round on 54 fragments, E2B)

    /// Token healing: the half-typed word is cut off the prompt and a GBNF grammar makes the reply start with it
    /// (`AutocompleteHealing`). Endings in mid-word 0 → 9 of 15 right. false = old behaviour.
    nonisolated(unsafe) static var useHealing = true
    /// Chat-template prompt with the typed text as the START OF THE MODEL'S REPLY (assistant prefill): rules, examples and
    /// conversation sit in the user turn, so only the typed tail changes between keystrokes and the whole template stays in
    /// the KV cache (1–6 tokens re-evaluated per request). Used only when the model has a Gemma 4 chat template
    /// (`CompletionClient.probeFormat`); other models keep the raw prompt. false = raw prompt for everyone.
    nonisolated(unsafe) static var useChatPrefill = true
    /// Set by `CompletionClient.probeFormat()` once the server is up.
    nonisolated(unsafe) static var chatTemplateAvailable = false
    /// Letters the reply must start with (healing); `CompletionClient` reads it right after `prompt(...)`.
    nonisolated(unsafe) static var lastHealLiteral: String?

    private static let maxContextChars = 1500
    private static let maxWords = 6

    /// Three short finished messages in the same "Message in X:" format, at the very start of every prompt.
    /// Constant text → llama-server's KV cache keeps it. Made the model write short, neutral, same-language
    /// continuations without markdown/noise (eval: autocomplete-eval.md). Deliberately free of digits and names.
    static let fewShot = "Message in Slack:\nПривет! Ты уже посмотрел логи по вчерашней кампании?\n\n"
        + "Message in Slack:\nCan you check the feed and send me the report today?\n\n"
        + "Message in Slack:\nСпасибо, получилось запустить, завтра скину результаты.\n\n"

    /// Prompt for a raw `/completion` call. `appName` is the frontmost app (e.g. "Telegram").
    /// `context` is the visible conversation around the field (see `ScreenContext`); it goes FIRST and changes
    /// rarely, so llama-server's KV cache keeps the prefix while the user types (warm ≈120 ms, cold ≈400 ms).
    /// Format picked on 10 EN/RU adtech chats (autocomplete-eval.md): "Conversation in X:\n<ctx>\n\nMy next message
    /// in this conversation:\n<typed>" made suggestions continue the thread (names, numbers, "logs", "rate card").
    static func prompt(textBefore: String, appName: String?, context: String?, extras: PromptExtras = PromptExtras()) -> String {
        lastTextBefore = textBefore
        var text = textBefore
        if text.count > maxContextChars {
            // Keep the tail, start on a word boundary.
            text = String(text.suffix(maxContextChars))
            if let sp = text.firstIndex(where: { $0 == " " || $0 == "\n" }) { text = String(text[text.index(after: sp)...]) }
        }
        // No trailing spaces/tabs: the model then supplies its own leading space (see `clean`).
        // With healing the unfinished last word is cut off too and forced back through the grammar.
        if useHealing {
            let plan = AutocompleteHealing.plan(textBefore: text)
            text = plan.head
            lastHealLiteral = plan.literal
        } else {
            while let last = text.last, last == " " || last == "\t" || last == "\u{00A0}" { text.removeLast() }
            lastHealLiteral = nil
        }
        let ctx = (context ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if useChatPrefill && chatTemplateAvailable { return chatPrompt(typed: text, appName: appName, context: ctx, extras: extras) }
        // Instructions / clipboard / examples go FIRST (before the conversation): they change rarely, so the prefix
        // stays byte-stable and llama-server's KV cache keeps it while the user types.
        let pre = fewShot + extrasPrefix(extras)
        guard !ctx.isEmpty else { return pre + header(for: appName) + text }
        return pre + "Conversation in \(place(for: appName)):\n\(ctx)\n\nMy next message in this conversation:\n" + text
    }

    /// Gemma 4 chat template; the typed text is the beginning of the model turn (no thought block: with it the
    /// abliterated models answered less often, 18 of 54 shown vs 40). The user turn is byte-stable except for the
    /// conversation, which is why it goes last.
    static func chatPrompt(typed: String, appName: String?, context ctx: String, extras: PromptExtras) -> String {
        let pl = place(for: appName)
        var body = chatRules + extrasPrefix(extras)
        if !ctx.isEmpty { body += "Conversation in \(pl):\n\(ctx)\n\n" }
        body += "Write the user's next message in \(pl)."
        return "<|turn>user\n" + body + "<turn|>\n<|turn>model\n" + typed
    }

    static let chatRules = "You are the user's typing assistant. Your reply is the message the user is writing right now: it already begins with the words typed so far, and you continue it from exactly where it stops. "
        + "Write only the next few words, in the user's language and tone, no quotes, no markdown. If the text stops in the middle of a word, finish that word first. "
        + "Never invent numbers, names or facts that are not in the conversation.\n\n"
        + "Examples of finished messages:\n- Привет! Ты уже посмотрел логи по вчерашней кампании?\n- Can you check the feed and send me the report today?\n- Спасибо, получилось запустить, завтра скину результаты.\n\n"

    /// "Writing notes / Copied text / My earlier messages" blocks, each followed by a blank line; "" when there are none.
    static func extrasPrefix(_ e: PromptExtras) -> String {
        var out = ""
        if let i = e.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !i.isEmpty {
            out += "Writing notes (follow them):\n" + i.components(separatedBy: "\n").map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        }
        if let c = e.clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            out += "Copied text (may be relevant):\n" + String(c.prefix(500)) + "\n\n"
        }
        let ex = e.examples.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !ex.isEmpty {
            out += "Examples of how I write:\n" + ex.prefix(5).map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    private static func place(for appName: String?) -> String {
        let h = header(for: appName)
        if h.hasPrefix("Message in ") { return String(h.dropFirst("Message in ".count).dropLast(2)) }
        return h == "Email:\n" ? "Email" : "a chat"
    }

    private static func header(for appName: String?) -> String {
        let n = (appName ?? "").lowercased()
        if n.contains("telegram") { return "Message in Telegram:\n" }
        if n.contains("teams") { return "Message in Microsoft Teams:\n" }
        if n.contains("slack") { return "Message in Slack:\n" }
        if n.contains("whatsapp") { return "Message in WhatsApp:\n" }
        if n.contains("mail") || n.contains("outlook") || n.contains("spark") || n.contains("gmail") { return "Email:\n" }
        return "Message:\n"
    }

    /// Turns the raw continuation into what is shown after the caret, or nil if nothing useful.
    static func clean(_ raw: String, textBefore: String, maxWords: Int? = nil) -> String? {
        let maxWords = maxWords ?? Self.maxWords
        var s = raw
        for tok in ["<end_of_turn>", "<start_of_turn>", "<eos>", "<bos>", "<pad>", "</s>"] {
            s = s.replacingOccurrences(of: tok, with: "")
        }
        s = String(s.prefix { $0 != "\n" && $0 != "\r" })
        guard !s.isEmpty else { return nil }

        // Junk: markup, code, URLs, long digit runs, "1.1.1.1" loops.
        if s.contains("<") || s.contains("`") || s.contains("http") { return nil }
        if s.range(of: #"\d{6,}"#, options: .regularExpression) != nil { return nil }
        if s.range(of: #"(\b\S{1,4}\b)(\W+\1){3,}"#, options: .regularExpression) != nil { return nil }
        if s.range(of: #"(\.\s?){4,}"#, options: .regularExpression) != nil { return nil }

        // Invented facts: a number of 2+ digits that the user has not typed (the model copies "906, 1981" from the
        // OCR context or makes one up) is never a good suggestion.
        let typedNumbers = Set(numberRegex.matches(in: textBefore, range: NSRange(textBefore.startIndex..., in: textBefore)).map { (textBefore as NSString).substring(with: $0.range) })
        for m in numberRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let n = (s as NSString).substring(with: m.range)
            if n.count >= 2, !typedNumbers.contains(n) { return nil }
        }
        // The model echoing the prompt header ("Slack:", "Message:") instead of continuing.
        if s.range(of: #"^\s*(Slack|Telegram|WhatsApp|Microsoft Teams|Message|Email)\b\s*:"#, options: .regularExpression) != nil { return nil }
        // Garbage characters (markdown emphasis, other scripts) mean the model went off the rails.
        if s.contains("*") || s.contains("_") || s.unicodeScalars.contains(where: { $0.value > 0x2FF && !(0x400...0x4FF).contains($0.value) && !(0x2000...0x2BFF).contains($0.value) }) { return nil }

        // Space handling. The prompt had its trailing space removed, so the model starts with " ".
        let endsWithSpace = textBefore.last.map { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" } ?? false
        let atWordStart = textBefore.isEmpty || endsWithSpace || textBefore.last == "\n"
        if atWordStart {
            s = String(s.drop { $0 == " " })           // the space is already typed
        }
        // Otherwise the caret is inside a word: the model's own leading space (if any) means a new word.
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        // Drop what the user has already written (model repeating the last 1–3 words).
        s = dropRepeat(s, textBefore: textBefore)

        // Caret inside a word: only a real word may be completed (see `midWord`).
        guard let guarded = midWord(s, textBefore: textBefore) else { return nil }
        s = guarded
        guard !s.isEmpty else { return nil }

        // Cut at the end of a sentence, otherwise at maxWords words.
        s = cut(s, maxWords: maxWords)

        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        var out = s
        while out.last == " " { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    // MARK: - confidence cut

    /// Set by `prompt`; `CompletionClient` uses it to cut the reply (the controller itself needs no change).
    nonisolated(unsafe) static var lastTextBefore = ""
    /// Master switch for the confidence cut.
    nonisolated(unsafe) static var useConfidence = true
    /// Minimum probability of every token after the first (0.35; see autocomplete-eval.md, round 3).
    nonisolated(unsafe) static var minTokenProb = 0.35
    /// The first token decides whether anything is shown at all (the first word is what the user judges): stricter.
    nonisolated(unsafe) static var firstTokenProb = 0.6
    /// Stricter bar for appending letters to a word that is already complete ("вчера" + "шний").
    nonisolated(unsafe) static var wholeWordProb = 0.8

    /// Keeps the confident head of a continuation: stops at the first token whose probability is below
    /// `minTokenProb`, and never leaves half a word (cuts back to the last word boundary). Returns "" when
    /// less than one word survives. `tokens` are the generated tokens with their probabilities
    /// (llama-server `completion_probabilities`, exp(logprob)).
    static func confidentPrefix(_ tokens: [(text: String, prob: Double)], textBefore: String) -> String {
        guard let first = tokens.first else { return "" }
        // Letters glued to a word that is already complete: only when very sure (otherwise the model guesses a suffix).
        if let last = textBefore.last, last.isLetter, let c = first.text.first, c.isLetter {
            let partial = String(textBefore.reversed().prefix { $0.isLetter || $0 == "-" }.reversed())
            if partial.count >= 2, isWord(partial, language: spellLanguage(for: partial, fallback: textBefore)),
               first.prob < wholeWordProb { return "" }
        }
        var out = ""
        var cutAt: Int?
        for (i, t) in tokens.enumerated() {
            if let nl = t.text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) { out += t.text[..<nl]; return out }
            if t.prob < (i == 0 ? firstTokenProb : minTokenProb) || t.text.contains("\u{FFFD}") { cutAt = i; break }
            out += t.text
        }
        guard let k = cutAt else { return out }
        // The unsure token continues a word → drop the unfinished word.
        if let c = tokens[k].text.first, c.isLetter || c.isNumber || c == "-", let l = out.last, l.isLetter || l.isNumber {
            if let idx = out.lastIndex(where: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
                out = String(out[...idx])
            } else {
                out = ""   // the whole kept part is a piece of one word
            }
        }
        return out
    }

    // MARK: - helpers

    private static let numberRegex = try! NSRegularExpression(pattern: #"\d+"#)

    /// Caret is right after a letter (no space typed yet).
    /// - The model continues the word (`s` starts with a letter): suggest ONLY the ending, and only if
    ///   prefix+ending is an existing word (NSSpellChecker). Longer phrases after the ending are dropped —
    ///   there is no confidence signal to say they are reliable. A 1-letter prefix is too ambiguous: silence.
    /// - The model starts a new word (`s` starts with a space/punctuation): fine only if the typed fragment is
    ///   itself a word.
    private static func midWord(_ s: String, textBefore: String) -> String? {
        guard let last = textBefore.last, last.isLetter else { return s }
        let partial = String(textBefore.reversed().prefix { $0.isLetter || $0 == "-" }.reversed())
        let lang = spellLanguage(for: partial.isEmpty ? textBefore : partial, fallback: textBefore)
        guard let first = s.first else { return nil }
        if first.isLetter {
            guard partial.count >= 2 else { return nil }
            let ending = String(s.prefix { $0.isLetter })
            return isWord(partial + ending, language: lang) ? ending : nil
        }
        if partial.count == 1 { return singleLetterWords.contains(partial.lowercased()) ? s : nil }
        return isWord(partial, language: lang) ? s : nil
    }

    private static let singleLetterWords: Set<String> = ["в", "и", "с", "к", "у", "о", "а", "я", "a", "i"]

    private static func spellLanguage(for word: String, fallback: String) -> String {
        let sample = word.contains(where: { $0.isLetter && $0.unicodeScalars.first.map { (0x400...0x4FF).contains($0.value) } == true }) ? word : String(fallback.suffix(40))
        let cyr = sample.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        if !cyr { return "en" }
        return sample.contains(where: { "іїєґІЇЄҐ".contains($0) }) ? "uk" : "ru"
    }

    /// NSSpellChecker is main-thread only. Unknown language / no dictionary → accept (do not silence).
    private static func isWord(_ w: String, language: String) -> Bool {
        let check: () -> Bool = {
            let sc = NSSpellChecker.shared
            guard sc.availableLanguages.contains(where: { $0 == language || $0.hasPrefix(language + "_") || $0.hasPrefix(language + "-") }) else { return true }
            let r = sc.checkSpelling(of: w, startingAt: 0, language: language, wrap: false,
                                     inSpellDocumentWithTag: 0, wordCount: nil)
            return r.location == NSNotFound
        }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    private static func words(_ s: String) -> [Substring] { s.split(whereSeparator: { $0 == " " || $0 == "\t" }) }

    private static func dropRepeat(_ s: String, textBefore: String) -> String {
        let before = words(textBefore).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        guard !before.isEmpty else { return s }
        let leading = s.prefix { $0 == " " }
        let ws = words(s)
        let wl = ws.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        for n in stride(from: min(3, wl.count, before.count), through: 1, by: -1) {
            if Array(wl.prefix(n)) == Array(before.suffix(n)), !wl.prefix(n).allSatisfy({ $0.isEmpty }),
               !leading.isEmpty || textBefore.last == " " || textBefore.last == "\n" {
                let rest = ws.dropFirst(n).joined(separator: " ")
                return rest.isEmpty ? "" : " " + rest
            }
        }
        return s
    }

    private static func cut(_ s: String, maxWords: Int) -> String {
        // Sentence end: keep the terminator, drop everything after.
        var result = ""
        var wordCount = 0
        var inWord = false
        var prev: Character = " "
        for ch in s {
            if ch == " " {
                if inWord { wordCount += 1; inWord = false }
                if wordCount >= maxWords { break }
            } else {
                inWord = true
            }
            result.append(ch)
            if (ch == "." || ch == "!" || ch == "?" || ch == "…") && prev != "." && !(ch == "." && prev.isNumber) {
                // Terminator at the end of a word: stop here.
                break
            }
            prev = ch
        }
        return result
    }
}
