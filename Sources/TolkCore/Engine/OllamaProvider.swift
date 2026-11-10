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
    /// Address AND its access headers from ONE lock acquisition: a concurrent availability check flipping `usingRemote`
    /// between two separate reads used to send the LAN URL with the remote headers (or the other way round).
    func endpoint() -> (url: URL, headers: [String: String]) {
        lock.withLock { usingRemote ? (remoteURL ?? lanURL, remoteHeaders) : (lanURL, [:]) }
    }
    let model: String
    let rules: RulesStore
    private let session: URLSession
    /// Separate session for loading the model: long silence is normal while 26B weights come off the disk.
    private let warmSession: URLSession
    private var warmTask: Task<Bool, Never>?
    private var warmFailedAt: Date?

    public init(config: TolkConfig, rules: RulesStore) {
        self.lanURL = Self.normalize(config.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!
        self.remoteURL = Self.normalize(config.remoteURL)
        self.remoteHeaders = config.remoteHeaders.filter { !$0.key.isEmpty }
        self.model = config.effectiveModel
        self.name = OllamaProvider.displayName(for: config.effectiveModel)
        self.rules = rules
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60   // max silence between bytes (the cold load is done separately by warmUp)
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
        let w = URLSessionConfiguration.ephemeral
        w.timeoutIntervalForRequest = 600   // not tied to any caller: a cold load must never be cut by us
        w.timeoutIntervalForResource = 900
        w.waitsForConnectivity = false
        self.warmSession = URLSession(configuration: w)
    }

    // MARK: - Warm-up (cold model)

    /// Is the model in memory right now (GET /api/ps, 2 s)? nil = could not find out.
    public func isModelLoaded() async -> Bool? {
        let ep = endpoint()
        var req = URLRequest(url: ep.url.appendingPathComponent("api/ps"))
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        ep.headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return nil }
        return models.contains { m in
            let n = (m["name"] as? String) ?? (m["model"] as? String) ?? ""
            return n == model || n.hasPrefix(model + ":")
        }
    }

    /// Starts loading the model (one shared load for everybody) and returns its task. The load is an
    /// independent Task: closing a popup or cancelling a translation never aborts it. An empty prompt
    /// only loads the weights and does not take a generation slot (NUM_PARALLEL).
    @discardableResult
    public func warmUp() -> Task<Bool, Never> {
        if let t = lock.withLock({ warmTask }) { return t }
        let base = baseURL, remote = isUsingRemote   // take the lock separately: NSLock is not recursive
        lock.lock(); defer { lock.unlock() }
        if let t = warmTask { return t }
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "prompt": "", "stream": false])
        if remote { remoteHeaders.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) } }
        let session = warmSession
        let t = Task<Bool, Never> { [weak self] in
            var ok = false
            if let (_, resp) = try? await session.data(for: req) { ok = (resp as? HTTPURLResponse)?.statusCode == 200 }
            self?.lock.withLock { self?.warmTask = nil; self?.warmFailedAt = ok ? nil : Date() }
            return ok
        }
        warmTask = t
        return t
    }

    /// Cheap check for health timers: if the model is gone from memory, start loading it (no more often
    /// than every 2 minutes after a failure).
    public func warmUpIfNeeded() async {
        if let f = lock.withLock({ warmFailedAt }), Date().timeIntervalSince(f) < 120 { return }
        if await isModelLoaded() == false { warmUp() }
    }

    public enum Readiness: Sendable { case ready, failed, stillLoading }

    /// Waits until the model is in memory, at most `timeout` s. `.failed` = the load request itself failed fast (the real request will report why).
    /// The load continues in the background even if we give up or the caller is cancelled.
    public func ensureReady(timeout: TimeInterval) async -> Readiness {
        guard await isModelLoaded() == false else { return .ready }
        let load = warmUp()
        // Race "load finished" against the timeout. Not a task group: a group would wait for the
        // (uncancellable) load child and the timeout would never fire.
        let once = NSLock(); var done = false
        return await withCheckedContinuation { (c: CheckedContinuation<Readiness, Never>) in
            func finish(_ v: Readiness) { once.lock(); defer { once.unlock() }; if !done { done = true; c.resume(returning: v) } }
            let sleeper = Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); if !Task.isCancelled { finish(.stillLoading) } }
            Task { finish(await load.value ? .ready : .failed); sleeper.cancel() } // the timer must not linger for the full timeout
        }
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
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        // A captive portal / Cloudflare Access login page also answers 200: only Ollama's JSON counts.
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["version"] is String
    }

    /// True when the last availability check picked the remote address.
    public var isUsingRemote: Bool { lock.withLock { usingRemote } }

    /// Adds the access headers when talking to the remote address.
    func authorize(_ req: inout URLRequest) {
        guard lock.withLock({ usingRemote }) else { return }
        remoteHeaders.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
    }

    func makeRequest(_ r: ResolvedRequest) throws -> URLRequest {
        // Glossary lines are chosen by the new text, the reply context and the already translated beginning.
        let selector = [r.text, r.replyTo, r.context?.source].compactMap { $0 }.joined(separator: "\n")
        return try makeChatRequest(system: Prompt.system(for: r, rules: rules.promptBlock(for: selector, target: r.target)),
                                   user: r.text)
    }

    /// One streamed chat completion with the sampling settings shared by translation and the editor pass.
    func makeChatRequest(system: String, user: String) throws -> URLRequest {
        let ep = endpoint()
        var req = URLRequest(url: ep.url.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            // Without this Qwen 3.6 thinks for a minute; think:false and /no_think don't work.
            "reasoning_effort": "none",
            // Low temperature + fixed seed: the same text gets the same translation every time
            // (verified with Gemma: 3/3 identical with a seed, 3 different without).
            "temperature": 0.1,
            "seed": 42,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        ep.headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        return req
    }

    /// Texts longer than this are translated paragraph by paragraph: the model context is 32k tokens and
    /// the answer is capped (num_predict 8192), so one huge request would be cut silently.
    static let chunkLimit = 6000

    public func translate(_ request: ResolvedRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let parts = Self.split(request.text, limit: Self.chunkLimit)
                    for (i, part) in parts.enumerated() {
                        try Task.checkCancellation()
                        var r = request
                        r.text = part.body
                        try await streamRequest(makeRequest(r), continuation)
                        if i < parts.count - 1, !part.tail.isEmpty { continuation.yield(part.tail) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Splits at line breaks (then sentences, then spaces) into pieces of at most `limit` characters.
    /// `tail` is the whitespace that followed the piece, so the output keeps the original paragraph layout.
    static func split(_ text: String, limit: Int) -> [(body: String, tail: String)] {
        guard text.count > limit else { return [(text, "")] }
        var pieces: [String] = []   // lines with their "\n"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            while rest.count > limit {
                var cut = rest.index(rest.startIndex, offsetBy: limit)
                let window = rest[rest.startIndex..<cut]
                if let i = window.lastIndex(where: { ".!?。".contains($0) }), window.distance(from: window.startIndex, to: i) > limit / 2 {
                    cut = rest.index(after: i)
                } else if let i = window.lastIndex(of: " ") { cut = rest.index(after: i) }
                pieces.append(String(rest[rest.startIndex..<cut])); rest = rest[cut...]
            }
            pieces.append(String(rest) + "\n")
        }
        if pieces.last?.hasSuffix("\n") == true, !text.hasSuffix("\n") { pieces[pieces.count - 1].removeLast() }
        var chunks: [String] = [], cur = ""
        for p in pieces {
            if !cur.isEmpty, cur.count + p.count > limit { chunks.append(cur); cur = "" }
            cur += p
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks.compactMap { c in
            let body = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { return nil }
            let tail = String(c.suffix(from: c.index(c.endIndex, offsetBy: -(c.count - c.reversed().drop(while: \.isWhitespace).count))))
            return (body, tail.contains("\n") ? "\n" + (tail.filter { $0 == "\n" }.count > 1 ? "\n" : "") : " ")
        }
    }

    func streamRequest(_ urlRequest: URLRequest, _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let (bytes, resp) = try await session.bytes(for: urlRequest)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 4096 { break } }
            throw TolkError.http(provider: name, status: status, message: Self.errorMessage(data))
        }
        var leading = true
        var produced = false
        var truncated = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let u = obj["usage"] as? [String: Any], let n = u["completion_tokens"] as? Int {
                UsageBox.current?.completionTokens = (UsageBox.current?.completionTokens ?? 0) + n
            }
            if let err = obj["error"] {
                throw TolkError.badResponse("\(name): \(Self.describe(err))")
            }
            guard let choices = obj["choices"] as? [[String: Any]] else { continue }
            if choices.first?["finish_reason"] as? String == "length" { truncated = true }
            guard let delta = choices.first?["delta"] as? [String: Any],
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
        if truncated { throw TolkError.badResponse("\(name): перевод обрезан — текст слишком длинный для модели. Переведите его частями.") }
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
