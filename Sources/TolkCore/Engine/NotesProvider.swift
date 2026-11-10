import Foundation

/// Second, short Qwen request after a translation: finds debatable industry terms ("scale up",
/// "разжать QPS") and explains the choice, so the user can pin the right variant in the glossary.
enum NotesPrompt {
    static func system(from: Language, to: Language, rules: String) -> String {
        var s = """
        You review a \(from.englishName) → \(to.englishName) translation.
        Find at most 3 terms or phrases in the SOURCE that are specialist jargon, slang, idioms or ambiguous words,
        where a generic translator often gets it wrong or inconsistent (the field comes from the user's glossary and the text itself).
        Skip ordinary words, names, IDs and numbers.
        The user's glossary below is authoritative: never suggest anything that contradicts it, and skip terms it already covers.
        Suggest only what a native speaker would really write in a chat or email;
        if you are not sure a variant is better, leave "suggestion" empty — a confirmed correct choice is a useful note too.
        If nothing is debatable, return an empty list — do not invent notes.
        For each note:
        - "term": exact phrase from the source;
        - "used": how the translation rendered it (exact words from the translation);
        - "suggestion": a clearly better variant in \(to.englishName), or "";
        - "note": in Russian, at most 15 words: what it means and why this variant.
        Answer with JSON only: {"notes":[{"term":"","used":"","suggestion":"","note":""}]}
        """
        if !rules.isEmpty { s += "\n\n# User's rules and glossary\n" + rules }
        return s
    }
}

extension OllamaProvider {
    /// One short JSON request; shared by notes and alternatives.
    func jsonChat(system: String, user: String, timeout: TimeInterval = 60) async -> [String: Any]? {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        let body: [String: Any] = [
            "model": model, "stream": false, "reasoning_effort": "none", "temperature": 0.3,
            "response_format": ["type": "json_object"], "max_tokens": 300,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data
        authorize(&req)
        guard let (resp, http) = try? await URLSession.shared.data(for: req),
              (http as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var content = message["content"] as? String
        else { return nil }
        content = Self.jsonObjectText(content)
        return (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any]
    }

    func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String] {
        let system = """
        You help a translator from \(from.englishName) to \(to.englishName).
        Give 3 or 4 alternative ways to render the FRAGMENT inside the TRANSLATION, in \(to.englishName),
        each fitting the sentence grammatically (same case/number/tense) so it can replace the fragment as is.
        Prefer natural, idiomatic wording (and the user's glossary terms if relevant). Do not repeat the fragment itself.
        Answer JSON only: {"alternatives":["...","..."]}
        """
        let user = "SOURCE:\n\(source)\n\nTRANSLATION:\n\(translation)\n\nFRAGMENT:\n\(fragment)"
        guard let obj = await jsonChat(system: system, user: user, timeout: 30),
              let list = obj["alternatives"] as? [String] else { return [] }
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != fragment.lowercased() && seen.insert($0.lowercased()).inserted }
            .prefix(4).map { $0 }
    }

    func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote] {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "reasoning_effort": "none",
            "temperature": 0.2, "max_tokens": 500,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": NotesPrompt.system(from: from, to: to, rules: rules.promptBlock(for: source))],
                ["role": "user", "content": "SOURCE:\n\(source)\n\nTRANSLATION:\n\(translation)"],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        req.httpBody = data
        authorize(&req)
        guard let (resp, http) = try? await URLSession.shared.data(for: req),
              (http as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return [] }
        return Self.parseNotes(content, source: source)
    }

    /// The `{…}` part of a model reply. Garbage like "} … {" (closing brace first) used to trap on `a...b`.
    static func jsonObjectText(_ s: String) -> String {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a <= b else { return s }
        return String(s[a...b])
    }

    static func parseNotes(_ content: String, source: String) -> [TranslationNote] {
        var json = content.trimmingCharacters(in: .whitespacesAndNewlines)
        json = Self.jsonObjectText(json)
        // Element by element: one malformed note must not throw away the good ones.
        guard let d = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let raw = root["notes"] as? [[String: Any]] else { return [] }
        func str(_ v: Any?) -> String? { (v as? String) }
        let decoded: [TranslationNote] = raw.compactMap { o in
            guard let term = str(o["term"]), let note = str(o["note"]) else { return nil }
            return TranslationNote(term: term, used: str(o["used"]) ?? "", suggestion: str(o["suggestion"]), note: note)
        }
        struct Wrapper { var notes: [TranslationNote]? }
        let w = Wrapper(notes: decoded)
        let lowered = source.lowercased()
        return (w.notes ?? []).compactMap { n in
            var n = n
            n.term = n.term.trimmingCharacters(in: .whitespacesAndNewlines)
            n.used = n.used.trimmingCharacters(in: .whitespacesAndNewlines)
            n.note = n.note.trimmingCharacters(in: .whitespacesAndNewlines)
            n.suggestion = n.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.suggestion?.isEmpty == true || n.suggestion?.lowercased() == n.used.lowercased() { n.suggestion = nil }
            // Drop hallucinated terms that are not in the source.
            guard !n.term.isEmpty, !n.note.isEmpty, lowered.contains(n.term.lowercased()) else { return nil }
            return n
        }.prefix(3).map { $0 }
    }
}
