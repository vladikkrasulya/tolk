// What we send to the local model and how its raw continuation becomes a suggestion.
// Owned by the "model eval" session. Measurements and examples: ~/Translate/test-corpus/autocomplete-eval.md
//
// Chosen after benchmarking Gemma 4 E4B base (Q4_K_M) vs it (QAT q4_0) on 36 adtech/chat fragments (EN+RU):
// the it model with a short "Message in <app>:" header and NO chat template gave the most sensible,
// same-language continuations; the base GGUF drifted into noise ("100%", dates, "<code>") and often
// answered nothing. The prompt must not end with a space: after a trailing space both models jump to
// digits/dates, so the space is stripped here and the model's own leading space is handled in `clean`.
import Foundation

enum AutocompletePrompt {
    /// Tokens to ask for; the suggestion is cut to a few words anyway (Russian needs ~2 tokens per word).
    /// Set by the [prefs] section from the length setting (`PromptPrefs.maxTokens`): 14 for short/medium, ~27 for long.
    nonisolated(unsafe) static var maxTokens = 14

    /// Model file used by default (in ~/Library/Application Support/Tolk/models).
    static let defaultModelPath = "~/Library/Application Support/Tolk/models/gemma-4-E4B-it-q4_0.gguf"

    private static let maxContextChars = 1500
    private static let maxWords = 6

    /// Prompt for a raw `/completion` call. `appName` is the frontmost app (e.g. "Telegram").
    /// `context` is the visible conversation around the field (see `ScreenContext`); it goes FIRST and changes
    /// rarely, so llama-server's KV cache keeps the prefix while the user types (warm ≈120 ms, cold ≈400 ms).
    /// Format picked on 10 EN/RU adtech chats (autocomplete-eval.md): "Conversation in X:\n<ctx>\n\nMy next message
    /// in this conversation:\n<typed>" made suggestions continue the thread (names, numbers, "logs", "rate card").
    static func prompt(textBefore: String, appName: String?, context: String?, extras: PromptExtras = PromptExtras()) -> String {
        var text = textBefore
        if text.count > maxContextChars {
            // Keep the tail, start on a word boundary.
            text = String(text.suffix(maxContextChars))
            if let sp = text.firstIndex(where: { $0 == " " || $0 == "\n" }) { text = String(text[text.index(after: sp)...]) }
        }
        // No trailing spaces/tabs: the model then supplies its own leading space (see `clean`).
        while let last = text.last, last == " " || last == "\t" || last == "\u{00A0}" { text.removeLast() }
        let ctx = (context ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Instructions / clipboard / examples go FIRST (before the conversation): they change rarely, so the prefix
        // stays byte-stable and llama-server's KV cache keeps it while the user types.
        let pre = extrasPrefix(extras)
        guard !ctx.isEmpty else { return pre + header(for: appName) + text }
        return pre + "Conversation in \(place(for: appName)):\n\(ctx)\n\nMy next message in this conversation:\n" + text
    }

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

        // Cut at the end of a sentence, otherwise at maxWords words.
        s = cut(s, maxWords: maxWords)

        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        var out = s
        while out.last == " " { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    // MARK: - helpers

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
