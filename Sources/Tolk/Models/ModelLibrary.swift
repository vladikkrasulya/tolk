// Models the user can pick without touching files or a terminal.
//
//   ModelLibrary  — suggestion models (GGUF files on this Mac): catalogue, download with progress, import, delete.
//   ServerModels  — translation models on the Ollama server: list, download («pull»), prepare for translation, delete.
import AppKit
import TolkCore

// MARK: - Suggestion models (local GGUF)

struct CatalogModel: Identifiable, Equatable {
    var id: String { file }
    let file: String        // name in the models folder
    let title: String
    let url: String
    let bytes: Int64
    let summary: String     // what to expect, in plain words
    let memory: String      // RAM while running
    var recommended = false
}

struct InstalledModel: Identifiable, Equatable {
    var id: String { file }
    let file: String
    let bytes: Int64
}

struct DownloadState: Equatable {
    var received: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0
    var error: String?
    var canResume = false
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    var active: Bool { error == nil }
}

@MainActor
final class ModelLibrary: ObservableObject {
    static let shared = ModelLibrary()

    nonisolated static let folderDisplay = "~/Library/Application Support/Tolk/models"
    nonisolated static var folder: URL { URL(fileURLWithPath: (folderDisplay as NSString).expandingTildeInPath, isDirectory: true) }

    /// Models measured on the project's own test sets (see ARCHITECTURE.md, 2026-11-11).
    static let catalog: [CatalogModel] = [
        CatalogModel(file: "gemma-4-E2B-abl-Q4_K.gguf", title: "Gemma 4 E2B",
                     url: "https://huggingface.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF/resolve/main/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-Q4_K.gguf",
                     bytes: 3_416_118_240,
                     summary: "Основная. Отвечает примерно за 0,1 с и точнее остальных: 28 окончаний слов из 30 и 39 продолжений из 40 на проверочных наборах.",
                     memory: "около 3,6 ГБ памяти", recommended: true),
        CatalogModel(file: "gemma-4-E4B-abl-Q4_K.gguf", title: "Gemma 4 E4B",
                     url: "https://huggingface.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF/resolve/main/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-Q4_K.gguf",
                     bytes: 5_302_272_352,
                     summary: "Крупнее, но вдвое медленнее (0,16–0,25 с) и на тех же наборах слабее: 23 окончания из 30. Стоит пробовать, только если E2B пишет не в вашем стиле.",
                     memory: "около 5,5 ГБ памяти"),
        CatalogModel(file: "qwen3.5-4B-abl-Q4_K_M.gguf", title: "Qwen 3.5 4B",
                     url: "https://huggingface.co/mradermacher/Huihui-Qwen3.5-4B-abliterated-GGUF/resolve/main/Huihui-Qwen3.5-4B-abliterated.Q4_K_M.gguf",
                     bytes: 2_707_514_688,
                     summary: "Самая лёгкая. В сравнении уступила Gemma по русскому языку; вариант для Mac, где мало свободной памяти.",
                     memory: "около 3 ГБ памяти"),
    ]

    @Published private(set) var installed: [InstalledModel] = []
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published var lastError: String?

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private var sources: [String: (url: URL, expected: Int64?)] = [:]
    private var speedMark: [String: (at: Date, bytes: Int64)] = [:]
    private lazy var bridge = DownloadBridge(owner: self)
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 6 * 3600
        c.waitsForConnectivity = true
        return URLSession(configuration: c, delegate: bridge, delegateQueue: nil)
    }()

    init() { refresh() }

    // MARK: State

    func refresh() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: Self.folder.path)) ?? []).filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
        let list = names.map { n in
            InstalledModel(file: n, bytes: Int64((try? fm.attributesOfItem(atPath: Self.folder.appendingPathComponent(n).path)[.size] as? Int) ?? 0))
        }
        if list != installed { installed = list }
    }

    func isInstalled(_ file: String) -> Bool { installed.contains { $0.file == file } }
    static func configPath(for file: String) -> String { folderDisplay + "/" + file }
    static func fileName(ofConfigPath p: String) -> String { (p as NSString).lastPathComponent }

    /// Files in the folder that are not in the catalogue (added by hand or by link).
    var extraInstalled: [InstalledModel] {
        installed.filter { m in !Self.catalog.contains { $0.file == m.file } }
    }

    static var freeDiskBytes: Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static var llamaServerInstalled: Bool { LocalModelServer.binaryPath != nil }

    // MARK: Download

    func download(_ m: CatalogModel) {
        guard let url = URL(string: m.url) else { return }
        start(file: m.file, url: url, expected: m.bytes)
    }

    /// A direct link to a `.gguf` file (Hugging Face «resolve» link). Returns an explanation when the link is not usable.
    @discardableResult
    func download(link: String) -> String? {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // The page link of a file («/blob/») → the file itself («/resolve/»).
        if text.contains("huggingface.co"), text.contains("/blob/") { text = text.replacingOccurrences(of: "/blob/", with: "/resolve/") }
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { return "Нужна ссылка, которая начинается с https://" }
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".gguf") else { return "Ссылка должна вести на файл .gguf" }
        if isInstalled(name) { return "Модель «\(name)» уже скачана" }
        start(file: name, url: url, expected: nil)
        return nil
    }

    private func start(file: String, url: URL, expected: Int64?) {
        guard tasks[file] == nil else { return }
        let need = (expected ?? 3_000_000_000) + 1_000_000_000
        if Self.freeDiskBytes > 0, Self.freeDiskBytes < need {
            downloads[file] = DownloadState(error: "Мало места на диске: нужно \(UsageText.bytes(need)), свободно \(UsageText.bytes(Self.freeDiskBytes))")
            return
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        sources[file] = (url, expected)
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: file) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = file
        tasks[file] = task
        downloads[file] = DownloadState(total: expected ?? 0)
        speedMark[file] = (Date(), 0)
        Diagnostics.log("models: download started \(file) from \(url.host ?? "?")")
        task.resume()
    }

    func resume(_ file: String) {
        guard let s = sources[file] else { return }
        start(file: file, url: s.url, expected: s.expected)
    }

    func cancel(_ file: String) {
        tasks.removeValue(forKey: file)?.cancel()
        resumeData[file] = nil
        downloads[file] = nil
        Diagnostics.log("models: download cancelled \(file)")
    }

    func dismissError(_ file: String) {
        if downloads[file]?.error != nil { downloads[file] = nil; resumeData[file] = nil }
    }

    fileprivate func progress(file: String, received: Int64, total: Int64) {
        guard var s = downloads[file], tasks[file] != nil else { return }
        let now = Date()
        if let mark = speedMark[file], now.timeIntervalSince(mark.at) >= 1 {
            let speed = Double(received - mark.bytes) / now.timeIntervalSince(mark.at)
            s.bytesPerSecond = s.bytesPerSecond == 0 ? speed : s.bytesPerSecond * 0.6 + speed * 0.4
            speedMark[file] = (now, received)
        }
        s.received = received
        if total > 0 { s.total = total }
        downloads[file] = s
    }

    /// `moved` = the finished file, already moved next to the models (nil = the transfer failed).
    fileprivate func finished(file: String, moved: URL?, status: Int?, error: Error?, resume: Data?) {
        tasks[file] = nil
        speedMark[file] = nil
        func fail(_ text: String, canResume: Bool = false) {
            if let moved { try? FileManager.default.removeItem(at: moved) }
            var s = downloads[file] ?? DownloadState()
            s.error = text
            s.canResume = canResume
            downloads[file] = s
            Diagnostics.log("models: download failed \(file): \(text)")
        }
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            if let resume { resumeData[file] = resume }
            fail("Скачивание прервалось: \(error.localizedDescription)", canResume: resume != nil)
            return
        }
        guard let moved else { fail("Файл не получен"); return }
        if let status, !(200..<300).contains(status) {
            fail(status == 401 || status == 403 ? "Сервер не отдал файл (нужен вход на сайте, код \(status))" : "Сервер ответил кодом \(status) — проверьте ссылку")
            return
        }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: moved.path)[.size] as? Int) ?? 0)
        let magic = (try? FileHandle(forReadingFrom: moved))?.readData(ofLength: 4)
        guard magic == Data("GGUF".utf8) else { fail("Скачанный файл не похож на модель (.gguf)"); return }
        if let expected = sources[file]?.expected, size != expected {
            fail("Файл скачан не полностью (\(UsageText.bytes(size)) из \(UsageText.bytes(expected)))")
            return
        }
        let target = Self.folder.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: moved, to: target)
            downloads[file] = nil
            Diagnostics.log("models: downloaded \(file) (\(UsageText.bytes(size)))")
            refresh()
        } catch {
            fail("Не удалось сохранить файл: \(error.localizedDescription)")
        }
    }

    // MARK: Import / delete

    /// Copies a `.gguf` chosen in the open panel into the models folder. Returns the file name.
    func importFile() -> String? {
        let panel = NSOpenPanel()
        panel.message = "Файл модели (.gguf)"
        panel.prompt = "Добавить"
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.pathExtension.lowercased() == "gguf" else { lastError = "Нужен файл с расширением .gguf"; return nil }
        let target = Self.folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: url, to: target) }
            Diagnostics.log("models: imported \(url.lastPathComponent)")
            refresh()
            return url.lastPathComponent
        } catch {
            lastError = "Не удалось добавить файл: \(error.localizedDescription)"
            return nil
        }
    }

    /// Moves the file to the Trash (it can be put back from there).
    func delete(_ file: String) {
        let url = Self.folder.appendingPathComponent(file)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            Diagnostics.log("models: moved to Trash \(file)")
        } catch {
            lastError = "Не удалось удалить «\(file)»: \(error.localizedDescription)"
        }
        refresh()
    }

    #if DEBUG
    /// Dev: `TOLK_DL_TEST=http://127.0.0.1:8000/x.gguf` downloads that file through the real code path, prints the
    /// progress and the outcome, removes the file and quits.
    static func runDownloadTestIfRequested() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["TOLK_DL_TEST"], let url = URL(string: raw) else { return false }
        let lib = ModelLibrary.shared
        let file = "tolk-dl-test.gguf"
        let expected = Int64(ProcessInfo.processInfo.environment["TOLK_DL_SIZE"] ?? "")
        lib.start(file: file, url: url, expected: expected)
        Task { @MainActor in
            var ticks = 0
            while lib.tasks[file] != nil, ticks < 600 {
                try? await Task.sleep(for: .milliseconds(100)); ticks += 1
                if ticks % 3 == 0, let s = lib.downloads[file] { print("[dl-test] \(s.received)/\(s.total) speed=\(Int(s.bytesPerSecond))") }
            }
            print("[dl-test] installed=\(lib.isInstalled(file)) error=\(lib.downloads[file]?.error ?? "-")")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file + ".part"))
            exit(0)
        }
        return true
    }
    #endif

    func revealFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }
}

/// URLSession calls its delegate off the main thread; this object carries the events to `ModelLibrary`.
private final class DownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: ModelLibrary?
    private let lock = NSLock()
    private var moved: [Int: URL] = [:]
    private var lastTick: [Int: Date] = [:]

    init(owner: ModelLibrary) { self.owner = owner }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastTick[downloadTask.taskIdentifier] ?? .distantPast) >= 0.25
        if due { lastTick[downloadTask.taskIdentifier] = now }
        lock.unlock()
        guard due, let file = downloadTask.taskDescription else { return }
        Task { @MainActor [weak owner] in owner?.progress(file: file, received: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns: move it next to the models right away.
        guard let file = downloadTask.taskDescription else { return }
        let part = ModelLibrary.folder.appendingPathComponent(file + ".part")
        try? FileManager.default.removeItem(at: part)
        if (try? FileManager.default.moveItem(at: location, to: part)) != nil {
            lock.lock(); moved[downloadTask.taskIdentifier] = part; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let file = task.taskDescription else { return }
        lock.lock()
        let url = moved.removeValue(forKey: task.taskIdentifier)
        lastTick[task.taskIdentifier] = nil
        lock.unlock()
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor [weak owner] in owner?.finished(file: file, moved: url, status: status, error: error, resume: resume) }
    }
}

// MARK: - Translation models (Ollama server)

struct ServerModel: Identifiable, Equatable {
    var id: String { name }
    let name: String            // without ":latest"
    let bytes: Int64
    let parameters: String      // "25.2B"
    let quantization: String    // "Q4_K_M"
    var isTranslate: Bool { name.hasSuffix("-translate") || name.contains("-translate-") }
}

struct PullState: Equatable {
    var status = "Подключаюсь…"
    var completed: Int64 = 0
    var total: Int64 = 0
    var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}

@MainActor
final class ServerModels: ObservableObject {
    /// The recipe the project's translation models are built with (same as `gemma-translate` on the server).
    static let translateSystem = "You are a professional translator. Translate the user text accurately and naturally, preserving meaning, tone, formatting, code and names. Output only the translation, with no explanations."
    static let translateParameters: [String: Any] = ["temperature": 0.3, "num_ctx": 8192, "num_predict": 8192]

    /// Base models worth offering (name in the Ollama library, what to expect).
    static let suggestions: [(name: String, note: String)] = [
        ("gemma4:26b", "Gemma 26B — основная модель перевода: точные термины, живой русский и украинский. 19 ГБ."),
        ("qwen3.6:35b-a3b", "Qwen 35B — чуть быстрее, но хуже на рабочем жаргоне (290 против 313 из 321). 23 ГБ."),
    ]

    @Published private(set) var models: [ServerModel] = []
    @Published private(set) var loading = false
    @Published private(set) var reachable: Bool?
    @Published private(set) var pulls: [String: PullState] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published var message: String?
    @Published var failed = false

    private var base = ""
    private var headers: [String: String] = [:]
    private var pullTasks: [String: Task<Void, Never>] = [:]

    func configure(base: String, headers: [String: String]) {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        self.base = b.hasSuffix("/") ? String(b.dropLast()) : b
        self.headers = headers
    }

    static func translateName(forBase base: String) -> String {
        let cleaned = base.replacingOccurrences(of: ":latest", with: "").map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }
        return String(cleaned) + "-translate"
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 20) -> URLRequest? {
        guard let url = URL(string: base + "/" + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func say(_ text: String, failed: Bool = false) {
        message = text
        self.failed = failed
        Diagnostics.log("server models: \(text)")
    }

    func refresh() {
        guard let req = request("api/tags", timeout: 6) else { reachable = false; return }
        loading = true
        Task { @MainActor in
            defer { loading = false }
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = obj["models"] as? [[String: Any]] else {
                reachable = false
                return
            }
            reachable = true
            models = list.compactMap { m in
                guard let name = m["name"] as? String else { return nil }
                let d = m["details"] as? [String: Any]
                return ServerModel(name: name.replacingOccurrences(of: ":latest", with: ""), bytes: (m["size"] as? NSNumber)?.int64Value ?? 0,
                                   parameters: d?["parameter_size"] as? String ?? "", quantization: d?["quantization_level"] as? String ?? "")
            }.sorted { ($0.isTranslate ? 0 : 1, $0.name) < ($1.isTranslate ? 0 : 1, $1.name) }
        }
    }

    /// Downloads `name` from the Ollama library to the server, then builds its translation model. `done` gets that model's name.
    func pull(_ name: String, done: ((String) -> Void)? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, pullTasks[name] == nil, let req = request("api/pull", method: "POST", body: ["model": name, "stream": true], timeout: 3600) else { return }
        pulls[name] = PullState()
        Diagnostics.log("server models: pull \(name)")
        pullTasks[name] = Task { @MainActor [weak self] in
            var problem: String?
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 { problem = "сервер ответил кодом \(http.statusCode)" }
                for try await line in bytes.lines {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let e = obj["error"] as? String { problem = e; break }
                    var s = self?.pulls[name] ?? PullState()
                    if let st = obj["status"] as? String { s.status = Self.pullStatus(st) }
                    if let t = (obj["total"] as? NSNumber)?.int64Value, t > 0 {
                        s.total = t
                        s.completed = (obj["completed"] as? NSNumber)?.int64Value ?? 0
                    }
                    self?.pulls[name] = s
                }
            } catch is CancellationError {
                problem = "отменено"
            } catch {
                problem = (error as? URLError)?.code == .cancelled ? "отменено" : error.localizedDescription
            }
            guard let self else { return }
            self.pulls[name] = nil
            self.pullTasks[name] = nil
            if let problem {
                if problem != "отменено" { self.say("Не удалось скачать «\(name)»: \(problem)", failed: true) }
            } else {
                self.say("Модель «\(name)» скачана на сервер.")
                await self.prepare(base: name, done: done)
            }
            self.refresh()
        }
    }

    func cancelPull(_ name: String) {
        pullTasks.removeValue(forKey: name)?.cancel()
        pulls[name] = nil
    }

    private static func pullStatus(_ s: String) -> String {
        if s.hasPrefix("pulling manifest") { return "Читаю описание модели…" }
        if s.hasPrefix("pulling") { return "Скачиваю на сервер…" }
        if s.hasPrefix("verifying") { return "Проверяю файл…" }
        if s.hasPrefix("writing") { return "Записываю…" }
        if s == "success" { return "Готово" }
        return s
    }

    /// Builds `<base>-translate`: the base model plus the translator instruction and parameters.
    func prepare(base: String, done: ((String) -> Void)? = nil) async {
        let name = Self.translateName(forBase: base)
        guard let req = request("api/create", method: "POST", body: [
            "model": name, "from": base, "system": Self.translateSystem, "parameters": Self.translateParameters, "stream": false,
        ], timeout: 300) else { return }
        busy.insert(base)
        defer { busy.remove(base) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if code == 200, err == nil {
                say("Модель перевода «\(name)» готова — её можно выбрать.")
                done?(name)
            } else {
                say("Не удалось подготовить «\(name)»: \(err ?? "код \(code)")", failed: true)
            }
        } catch {
            say("Не удалось подготовить «\(name)»: \(error.localizedDescription)", failed: true)
        }
        refresh()
    }

    func delete(_ name: String) {
        guard let req = request("api/delete", method: "DELETE", body: ["model": name]) else { return }
        busy.insert(name)
        Task { @MainActor in
            defer { busy.remove(name) }
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 { say("Модель «\(name)» удалена с сервера.") } else { say("Сервер не удалил «\(name)» (код \(code)).", failed: true) }
            } catch {
                say("Не удалось удалить «\(name)»: \(error.localizedDescription)", failed: true)
            }
            refresh()
        }
    }
}
