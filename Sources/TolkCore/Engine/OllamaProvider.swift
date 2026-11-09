import Foundation

/// Qwen on vkbox via Ollama's OpenAI-compatible endpoint, streamed over SSE.
public final class OllamaProvider: TranslationProvider, @unchecked Sendable {
    /// Display name from the model id: "qwen-translate" -> "Qwen", "gemma-translate" -> "Gemma".
    public let name: String
    /// Home address (LAN) and, optionally, the same Ollama from outside (e.g. a Cloudflare Tunnel) with access headers.
    let lanURL: URL
    let remoteURL: URL?
    let remoteHeaders: [String: String]
    private let lock = NSLock()
    private var usingRemote = false
    /// The address that answered the last availability check.
    var baseURL: URL { lock.withLock { usingRemote ? (remoteURL ?? lanURL) : lanURL } }
    let model: String
    let rules: RulesStore
    private let session: URLSession

    public init(config: TolkConfig, rules: RulesStore) {
        self.lanURL = Self.normalize(config.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!
        self.remoteURL = Self.normalize(config.remoteURL)
        self.remoteHeaders = config.remoteHeaders.filter { !$0.key.isEmpty }
        self.model = config.effectiveModel
        self.name = OllamaProvider.displayName(for: config.effectiveModel)
        self.rules = rules
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 90   // max silence between bytes (cold model load can take a while)
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    public static func displayName(for model: String) -> String {
        let m = model.lowercased()
        for (key, title) in [("qwen", "Qwen"), ("gemma", "Gemma"), ("llama", "Llama"), ("mistral", "Mistral")] where m.contains(key) {
            return title
        }
        let base = model.split(separator: ":").first.map(String.init) ?? model
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    static func normalize(_ raw: String) -> URL? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base)
    }

    /// Home first (fast, 0.8 s); if it does not answer and a remote address is set, try that (2 s).
    public func isAvailable() async -> Bool {
        if await ping(lanURL, timeout: 0.8, headers: [:]) {
            lock.withLock { usingRemote = false }
            return true
        }
        if let remoteURL, await ping(remoteURL, timeout: 2, headers: remoteHeaders) {
            lock.withLock { usingRemote = true }
            return true
        }
        return false
    }

    private func ping(_ base: URL, timeout: TimeInterval, headers: [String: String]) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("api/version"))
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// True when the last availability check picked the remote address.
    public var isUsingRemote: Bool { lock.withLock { usingRemote } }

    /// Adds the access headers when talking to the remote address.
    func authorize(_ req: inout URLRequest) {
        guard lock.withLock({ usingRemote }) else { return }
        remoteHeaders.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
    }

    func makeRequest(_ r: ResolvedRequest) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            // Without this Qwen 3.6 thinks for a minute; think:false and /no_think don't work.
            "reasoning_effort": "none",
            // Low temperature: the same phrase should translate the same way every time.
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": Prompt.system(for: r, rules: rules.promptBlock(for: r.text + "\n" + (r.replyTo ?? "")))],
                ["role": "user", "content": r.text],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        authorize(&req)
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
                        if let u = obj["usage"] as? [String: Any], let n = u["completion_tokens"] as? Int {
                            UsageBox.current?.completionTokens = n
                        }
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
