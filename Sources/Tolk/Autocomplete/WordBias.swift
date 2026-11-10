// «Выбор слов»: the words the user writes most often get a small `logit_bias` on the first token of " word" in every
// completion request, so the model leans to them. Built from style memory (sent messages with an accepted suggestion,
// accepted phrases) and the words accepted in this session; never written anywhere, never sent off the Mac.
// Token ids come from llama-server's own /tokenize, so they always match the loaded model.
import Foundation
import TolkCore

@MainActor
final class WordBias {
    private var cache: [String: Int?] = [:]      // word → first token id of " word" (nil = not worth a bias)
    private var cacheModel = ""
    private var building = false
    private var builtKey = ""
    private var sessionWords: [String] = []

    func noteAccepted(_ text: String) {
        sessionWords.append(text)
        if sessionWords.count > 500 { sessionWords.removeFirst(sessionWords.count - 500) }
        builtKey = ""    // rebuild at the next request
    }

    /// Rebuilds the bias in the background when the word list changed. Cheap when nothing changed.
    func refreshIfNeeded(baseURL: URL, model: String, mode: String, texts: (() -> [String])?) {
        let strength = AutocompleteTuning.biasStrength(mode)
        guard strength > 0, let texts else {
            if !AutocompletePrompt.logitBias.isEmpty { AutocompletePrompt.logitBias = [] }
            return
        }
        let all = texts() + sessionWords
        let key = "\(model)|\(mode)|\(all.count)|\(all.last?.count ?? 0)"
        guard key != builtKey, !building else { return }
        building = true
        if cacheModel != model { cache = [:]; cacheModel = model }
        let top = AutocompleteTuning.topWords(AutocompleteTuning.wordCounts(in: all))
        let known = cache
        Task { [weak self] in
            var ids: [String: Int?] = [:]
            for (w, _) in top where known[w] == nil {
                ids[w] = await Self.firstToken(of: " " + w, baseURL: baseURL)
            }
            guard let self else { return }
            for (w, id) in ids { self.cache[w] = id }
            var bias: [Int: Double] = [:]
            for (w, n) in top {
                guard let id = self.cache[w] ?? nil else { continue }
                bias[id] = max(bias[id] ?? 0, AutocompleteTuning.biasWeight(count: n, strength: strength))
            }
            AutocompletePrompt.logitBias = bias.map { (token: $0.key, bias: $0.value) }
            self.builtKey = key
            self.building = false
            Diagnostics.log("autocomplete: word bias \(mode) words=\(top.count) tokens=\(bias.count)")
        }
    }

    /// First token of `text`, if its text is at least 3 characters (a one-letter or two-letter piece would shift too much).
    nonisolated private static func firstToken(of text: String, baseURL: URL) async -> Int? {
        guard let tokens = await post("tokenize", ["content": text, "add_special": false], baseURL)?["tokens"] as? [Int],
              let id = tokens.first,
              let piece = await post("detokenize", ["tokens": [id]], baseURL)?["content"] as? String,
              piece.trimmingCharacters(in: .whitespaces).count >= 3 else { return nil }
        return id
    }

    nonisolated private static func post(_ path: String, _ body: [String: Any], _ baseURL: URL) async -> [String: Any]? {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
