import Foundation

/// Qwen on vkbox via Ollama's OpenAI-compatible endpoint, streamed over SSE.
public final class OllamaProvider: TranslationProvider, @unchecked Sendable {
    public let name = "Qwen"
    let baseURL: URL
    let model: String
    let rules: RulesStore
    private let session: URLSession

    public init(config: TolkConfig, rules: RulesStore) {
        var base = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        self.baseURL = URL(string: base) ?? URL(string: "http://127.0.0.1:11434")!
        self.model = config.model
        self.rules = rules
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 90   // max silence between bytes (cold model load can take a while)
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    public func isAvailable() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        req.timeoutInterval = 0.8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func makeRequest(_ r: ResolvedRequest) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            // Without this Qwen 3.6 thinks for a minute; think:false and /no_think don't work.
            "reasoning_effort": "none",
            // Low temperature: the same phrase should translate the same way every time.
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": Prompt.system(for: r, rules: rules.promptBlock(for: r.text))],
                ["role": "user", "content": r.text],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func translate(_ request: ResolvedRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: makeRequest(request))
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 4096 { break } }
                        throw TolkError.http(provider: name, status: status, message: Self.errorMessage(data))
                    }
                    var leading = true
                    var produced = false
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if let err = obj["error"] {
                            throw TolkError.badResponse("\(name): \(Self.describe(err))")
                        }
                        guard let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              var piece = delta["content"] as? String, !piece.isEmpty
                        else { continue }
                        if leading {
                            piece = String(piece.drop(while: \.isWhitespace))
                            if piece.isEmpty { continue }
                            leading = false
                        }
                        produced = true
                        continuation.yield(piece)
                    }
                    if !produced { throw TolkError.emptyTranslation(name) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = obj["error"] {
            return describe(e)
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    static func describe(_ e: Any) -> String {
        if let d = e as? [String: Any], let m = d["message"] as? String { return m }
        return "\(e)"
    }
}
