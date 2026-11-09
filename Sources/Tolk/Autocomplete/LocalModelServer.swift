// Local model for autocomplete: llama.cpp's `llama-server` started by Tolk on 127.0.0.1.
// Autocomplete must answer in ~100–300 ms, so it runs on this Mac (no network, unlike translation).
// One small model (Gemma E4B), one slot, prompt cache on: typing a few letters reuses the KV cache.
import Foundation

@MainActor
final class LocalModelServer {
    enum State: Equatable {
        case stopped, starting, ready
        case failed(String)
    }

    static let port = 8178
    let baseURL = URL(string: "http://127.0.0.1:\(LocalModelServer.port)")!
    private(set) var state: State = .stopped { didSet { if state != oldValue { onStateChange?(state) } } }
    var onStateChange: ((State) -> Void)?

    private(set) var modelPath: String
    private var process: Process?
    private var startTask: Task<Void, Never>?

    init(modelPath: String) { self.modelPath = (modelPath as NSString).expandingTildeInPath }

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
        state = .starting
        startTask = Task { [weak self] in await self?.boot() }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    func stop() {
        startTask?.cancel()
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        state = .stopped
    }

    private func boot() async {
        // A server left over from a previous run (Tolk crashed or was killed) is reused.
        if await healthy() { state = .ready; Diagnostics.log("autocomplete: reusing running llama-server"); return }
        guard let bin = Self.binaryPath else { state = .failed("нет llama-server (brew install llama.cpp)"); return }
        guard FileManager.default.fileExists(atPath: modelPath) else { state = .failed("нет файла модели"); return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", modelPath, "--host", "127.0.0.1", "--port", "\(Self.port)",
                       "-c", "4096", "-ngl", "99", "-fa", "on", "-np", "1",
                       "--cache-reuse", "64", "--no-webui"]
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tolk")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("llama-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                if self.state != .stopped {
                    Diagnostics.log("autocomplete: llama-server exited (\(code))")
                    self.state = .failed("модель остановилась (код \(code))")
                }
            }
        }
        do { try p.run() } catch { state = .failed("не запустился llama-server"); return }
        process = p
        Diagnostics.log("autocomplete: starting llama-server with \((modelPath as NSString).lastPathComponent)")

        let started = Date()
        while !Task.isCancelled, Date().timeIntervalSince(started) < 90 {
            if await healthy() {
                state = .ready
                Diagnostics.log("autocomplete: model ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                await warmUp()
                return
            }
            if process == nil { return } // exited, terminationHandler set .failed
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !Task.isCancelled { state = .failed("модель не загрузилась за 90 с") }
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// First request compiles Metal kernels; do it now, not on the user's first keystroke.
    private func warmUp() async {
        _ = try? await CompletionClient(baseURL: baseURL).complete(prompt: "Hello, how are", maxTokens: 2)
    }
}

/// `/completion` of llama-server: raw text in, continuation out.
/// llama-server answered with a non-2xx status (e.g. 503 while the slot is busy).
struct HTTPStatusError: Error { let status: Int }

struct CompletionClient {
    let baseURL: URL

    struct Result { let text: String; let ms: Int }

    func complete(prompt: String, maxTokens: Int) async throws -> Result {
        var req = URLRequest(url: baseURL.appendingPathComponent("completion"))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "prompt": prompt,
            "n_predict": maxTokens,
            "temperature": 0,
            "top_k": 1,
            "stop": ["\n"],
            "cache_prompt": true,
            "n_probs": 1,   // per-token probabilities → AutocompletePrompt.confidentPrefix
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw HTTPStatusError(status: http.statusCode) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var text = json?["content"] as? String ?? ""
        if AutocompletePrompt.useConfidence, let probs = json?["completion_probabilities"] as? [[String: Any]], !probs.isEmpty {
            let toks: [(text: String, prob: Double)] = probs.compactMap {
                guard let t = $0["token"] as? String, let lp = $0["logprob"] as? Double else { return nil }
                return (t, exp(lp))
            }
            if toks.count == probs.count { text = AutocompletePrompt.confidentPrefix(toks, textBefore: AutocompletePrompt.lastTextBefore) }
        }
        return Result(text: text, ms: Int(Date().timeIntervalSince(t0) * 1000))
    }
}
