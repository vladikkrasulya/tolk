// Local model for autocomplete: llama.cpp's `llama-server` started by Tolk on 127.0.0.1.
// Autocomplete must answer in ~100–300 ms, so it runs on this Mac (no network, unlike translation).
// One small model (Gemma E4B), one slot, prompt cache on: typing a few letters reuses the KV cache.
import Foundation
import TolkCore

@MainActor
final class LocalModelServer {
    enum State: Equatable {
        case stopped, starting, ready
        case failed(String)
    }

    let port: Int
    let baseURL: URL
    private(set) var state: State = .stopped { didSet { if state != oldValue { onStateChange?(state) } } }
    var onStateChange: ((State) -> Void)?
    /// When the next automatic restart happens (nil = none scheduled); shown next to the error.
    private(set) var nextRetryAt: Date?

    private(set) var modelPath: String
    private var process: Process?
    private var startTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var failures = 0

    init(modelPath: String, port: Int = 8178) {
        self.modelPath = (modelPath as NSString).expandingTildeInPath
        self.port = port
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    static var binaryPath: String? {
        ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var modelName: String {
        let f = (modelPath as NSString).lastPathComponent.lowercased()
        if f.contains("e4b") { return "Gemma E4B" }
        if f.contains("e2b") { return "Gemma E2B" }
        return (f as NSString).deletingPathExtension
    }

    func setModel(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        guard p != modelPath else { return }
        modelPath = p
        if state != .stopped { stop(); start() }
    }

    func start() {
        guard state == .stopped || isFailed else { return }
        retryTask?.cancel(); nextRetryAt = nil
        state = .starting
        startTask = Task { [weak self] in await self?.boot() }
    }

    /// Manual «Повторить»: forget the failure count and start again right now.
    func retry() {
        guard isFailed else { return }
        failures = 0
        start()
    }

    var isFailedState: Bool { isFailed }
    private var isFailed: Bool { if case .failed = state { return true }; return false }

    func stop() {
        startTask?.cancel()
        retryTask?.cancel(); nextRetryAt = nil
        failures = 0
        let p = process
        process = nil // the termination handler ignores a process we already let go
        if let p, p.isRunning {
            p.terminate() // SIGTERM → the wrapper's trap stops llama-server
            // The pid file stays: a quick restart (model switch) may meet the dying server and must recognise it as ours.
        } else {
            ServerLifecycle.removeRecord()
        }
        state = .stopped
    }

    /// Records the reason (log + state). `retryable`: the process died or did not load — try again 2, 10, 60 s later.
    private func fail(_ reason: String, retryable: Bool) {
        Diagnostics.log("autocomplete: \(reason)")
        process = nil
        ServerLifecycle.removeRecord()
        state = .failed(reason)
        guard retryable else { return }
        failures += 1
        guard let delay = ServerLifecycle.retryDelay(afterFailures: failures) else {
            Diagnostics.log("autocomplete: automatic restarts exhausted — waiting for «Повторить»")
            return
        }
        nextRetryAt = Date().addingTimeInterval(delay)
        Diagnostics.log("autocomplete: restart in \(Int(delay)) s (attempt \(failures))")
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.nextRetryAt = nil
            self.start()
        }
    }

    private func boot() async {
        guard let bin = Self.binaryPath else { fail("нет llama-server (brew install llama.cpp)", retryable: false); return }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            fail("нет файла модели: \((modelPath as NSString).lastPathComponent)", retryable: false); return
        }

        // Who is on the port? Ours from a previous run (pid file matches) → stop it; anyone else → leave alone.
        let port = self.port
        let decision: PortDecision = await Task.detached {
            let l = ServerLifecycle.listener(onPort: port)
            return ServerLifecycle.decide(listenerPid: l?.pid, listenerIsLlama: l?.isLlama ?? false,
                                          record: ServerLifecycle.readRecord(), port: port)
        }.value
        guard !Task.isCancelled else { return }
        switch decision {
        case .portBusy:
            fail("порт \(port) занят другой программой", retryable: false); return
        case .killOrphanThenStart(let pid):
            Diagnostics.log("autocomplete: stopping a llama-server left by a previous Tolk (pid \(pid))")
            await Task.detached { ServerLifecycle.terminate(pid: pid) }.value
            ServerLifecycle.removeRecord()
        case .startOwn:
            ServerLifecycle.removeRecord()
        }
        guard !Task.isCancelled else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let command = [bin, "-m", modelPath, "--host", "127.0.0.1", "--port", "\(port)",
                       "-c", "4096", "-ngl", "99", "-fa", "on", "-np", "1",
                       "--cache-reuse", "64", "--no-webui"]
        p.arguments = ServerLifecycle.wrapperArguments(command: command) // dies with Tolk even on kill -9
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tolk")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("llama-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.fail("модель остановилась (код \(code), см. llama-server.log)", retryable: true)
            }
        }
        do { try p.run() } catch { fail("не запустился llama-server: \(error.localizedDescription)", retryable: true); return }
        process = p
        Diagnostics.log("autocomplete: starting llama-server with \((modelPath as NSString).lastPathComponent)")

        let started = Date()
        while !Task.isCancelled, Date().timeIntervalSince(started) < 90 {
            if process == nil { return } // exited: the termination handler reported it
            if await healthy() {
                state = .ready
                failures = 0
                let model = modelPath
                await Task.detached {
                    if let l = ServerLifecycle.listener(onPort: port) {
                        ServerLifecycle.writeRecord(ServerRecord(pid: l.pid, port: port, model: model))
                    }
                }.value
                Diagnostics.log("autocomplete: model ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                await warmUp()
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !Task.isCancelled, process != nil {
            let proc = process
            process = nil // timeout: not an exit report
            proc?.terminate()
            fail("модель не загрузилась за 90 с", retryable: true)
        }
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// First request compiles Metal kernels; do it now, not on the user's first keystroke.
    private func warmUp() async {
        let client = CompletionClient(baseURL: baseURL)
        await client.probeFormat()
        _ = try? await client.complete(prompt: "Hello, how are", maxTokens: 2, healLiteral: nil)
    }
}

/// `/completion` of llama-server: raw text in, continuation out.
/// llama-server answered with a non-2xx status (e.g. 503 while the slot is busy).
struct HTTPStatusError: Error { let status: Int }

struct CompletionClient {
    let baseURL: URL

    struct Result { let text: String; let ms: Int }

    /// Does this model have a Gemma 4 chat template (`<|turn>`)? Decides between the chat-prefill and the raw prompt.
    func probeFormat() async {
        var req = URLRequest(url: baseURL.appendingPathComponent("props"))
        req.timeoutInterval = 3
        var gemma4 = false
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tpl = json["chat_template"] as? String { gemma4 = tpl.contains("<|turn>") }
        AutocompletePrompt.chatTemplateAvailable = gemma4
    }

    /// `healLiteral`: the cut-off word the grammar forces at the start of the reply (see `AutocompleteHealing`); it is
    /// read when the call is made, right after `AutocompletePrompt.prompt(...)`.
    func complete(prompt: String, maxTokens: Int, healLiteral: String? = AutocompletePrompt.lastHealLiteral) async throws -> Result {
        var req = URLRequest(url: baseURL.appendingPathComponent("completion"))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "prompt": prompt,
            "n_predict": maxTokens,
            "temperature": 0,
            "top_k": 1,
            "stop": ["\n"],
            "cache_prompt": true,
            "n_probs": 1,   // per-token probabilities → AutocompletePrompt.confidentPrefix
        ]
        if !AutocompletePrompt.logitBias.isEmpty {
            body["logit_bias"] = AutocompletePrompt.logitBias.map { [$0.token, $0.bias] as [Any] }   // «Выбор слов» (WordBias)
        }
        if let lit = healLiteral, !lit.isEmpty {
            body["grammar"] = AutocompleteHealing.grammar(forLiteral: lit)
            body["n_probs"] = 20   // alternatives for the first free token (renormalised in AutocompleteHealing.strip)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw HTTPStatusError(status: http.statusCode) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var text = json?["content"] as? String ?? ""
        let probs = json?["completion_probabilities"] as? [[String: Any]] ?? []
        var tokens: [AutocompleteHealing.Token] = probs.compactMap {
            guard let t = $0["token"] as? String, let lp = $0["logprob"] as? Double else { return nil }
            let top = ($0["top_logprobs"] as? [[String: Any]] ?? []).compactMap { e -> (text: String, prob: Double)? in
                guard let tt = e["token"] as? String, let l = e["logprob"] as? Double else { return nil }
                return (tt, exp(l))
            }
            return AutocompleteHealing.Token(text: t, prob: exp(lp), top: top)
        }
        if tokens.count != probs.count { tokens = [] }
        if let lit = healLiteral, !lit.isEmpty {
            // The reply begins with the forced letters of the word being typed: drop them, keep the continuation.
            let stripped = AutocompleteHealing.strip(literal: lit, content: text, tokens: tokens)
            text = stripped.content
            tokens = stripped.tokens
        }
        if AutocompletePrompt.useConfidence, !tokens.isEmpty {
            text = AutocompletePrompt.confidentPrefix(tokens.map { ($0.text, $0.prob) }, textBefore: AutocompletePrompt.lastTextBefore)
        }
        return Result(text: text, ms: Int(Date().timeIntervalSince(t0) * 1000))
    }
}
