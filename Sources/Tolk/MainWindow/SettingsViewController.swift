import AppKit
import ApplicationServices
import SwiftUI
import TolkCore

/// "Настройки" page: edits `TolkConfig` and saves it with `TolkConfig.save()` (auto-save, debounced).
@MainActor
final class SettingsViewController: NSViewController {
    let model: SettingsModel

    init(config: TolkConfig) {
        model = SettingsModel(config: config)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.sizingOptions = []
        view = host
    }

    // The 2-second poll (Accessibility / launch-at-login / autocomplete statistics) runs only while the page is on
    // screen: started when it appears, stopped when it goes away or its window is covered / minimised.
    private var ticker: Timer?
    private var occlusionObserver: NSObjectProtocol?

    override func viewWillAppear() {
        super.viewWillAppear()
        model.refreshStatus()
        model.refreshStats()
        updateTicker()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: view.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTicker() }
        }
        updateTicker()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        model.saveNow() // don't lose a pending debounced save
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        stopTicker()
    }

    private func updateTicker() {
        let onScreen = view.window?.occlusionState.contains(.visible) ?? false
        if onScreen { startTicker() } else { stopTicker() }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshStatus(); self?.model.refreshStats() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case translate, autocomplete, models, stats, log, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .translate: "Перевод"
        case .autocomplete: "Автодополнение"
        case .models: "Модели"
        case .stats: "Статистика"
        case .log: "Журнал"
        case .general: "Общие"
        }
    }
    var symbol: String {
        switch self {
        case .translate: "character.bubble"
        case .autocomplete: "text.cursor"
        case .models: "cpu"
        case .stats: "chart.bar"
        case .log: "list.bullet.rectangle"
        case .general: "gearshape"
        }
    }
    static let key = "settingsTab"
    static var saved: SettingsTab {
        var t: SettingsTab = .translate
        if let r = UserDefaults.standard.string(forKey: key), let v = SettingsTab(rawValue: r) { t = v }
        #if DEBUG
        if let e = ProcessInfo.processInfo.environment["TOLK_SETTINGS_TAB"], let v = SettingsTab(rawValue: e) { t = v }
        #endif
        return t
    }
}

// MARK: - Model

struct HeaderRow: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

enum CheckState: Equatable {
    case idle, checking
    case ok(String)
    case failed(String)
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: TolkConfig { didSet { if config != oldValue { scheduleSave() } } }
    @Published var headers: [HeaderRow] { didSet { if headers != oldValue { syncHeaders() } } }
    @Published var tab: SettingsTab = SettingsTab.saved { didSet { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key) } }
    @Published var saveStatus = ""
    @Published var saveFailed = false
    @Published var lanCheck: CheckState = .idle
    @Published var remoteCheck: CheckState = .idle
    @Published var availableModels: [String] = []
    @Published var hasAccessibility = AXIsProcessTrusted()
    @Published var launchAtLogin = LaunchAgent.isEnabled
    @Published var launchError: String?
    /// Why the autocomplete model is not running (nil = fine); set by AppDelegate. «Повторить» calls `onRetryAutocomplete`.
    @Published var acError: String?
    var onRetryAutocomplete: (() -> Void)?
    /// Autocomplete statistics for the «Статистика» block (numbers only).
    @Published var acStats = ACStatsData()

    /// Translator usage for the «Статистика» tab (numbers only).
    @Published var usage = UsageData()
    /// «Статистика»: period in days (nil = all time).
    @Published var statsPeriod: Int? = 7
    /// Is the suggestion model loaded and answering (set by AppDelegate)?
    @Published var acReady = false
    @Published var hasScreenRecording = CGPreflightScreenCaptureAccess()
    /// «Журнал» tab.
    @Published var logLines: [String] = []
    @Published var logFilter = LogFilter.all
    @Published var logSearch = ""
    private var logStamp: Date?
    /// «Общие → Данные на диске».
    @Published var storage: [StorageItem] = []
    let library = ModelLibrary.shared
    let server = ServerModels()

    func refreshStats() {
        switch tab {
        case .stats:
            let d = ACStatsSource.provider()
            if d != acStats { acStats = d }
            if !UsageStore.shared.data.importedHistory { UsageStore.shared.importHistoryIfNeeded(HistoryStore().all()) }
            let u = UsageStore.shared.data
            if u != usage { usage = u }
        case .log:
            refreshLog()
        case .models:
            library.refresh()
        default:
            break
        }
    }

    func resetStats() {
        ACStatsSource.reset()
        acStats = ACStatsData()
        UsageStore.shared.reset()
        usage = UsageStore.shared.data
    }

    // MARK: Log

    func refreshLog(force: Bool = false) {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Diagnostics.logURL.path))?[.modificationDate] as? Date
        guard force || stamp != logStamp || logLines.isEmpty else { return }
        logStamp = stamp
        let lines = Diagnostics.tail(limit: 800)
        if lines != logLines { logLines = lines }
    }

    var shownLogLines: [String] {
        let q = logSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return logLines.filter { logFilter.matches($0) && (q.isEmpty || $0.lowercased().contains(q)) }
    }

    func clearLog() {
        Diagnostics.clearLog()
        logLines = []
        logStamp = nil
        refreshStorage()
    }

    // MARK: Storage

    func refreshStorage() {
        let fm = FileManager.default
        func size(_ path: String) -> Int64 {
            let p = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return 0 }
            if !isDir.boolValue { return Int64((try? fm.attributesOfItem(atPath: p)[.size] as? Int) ?? 0) }
            var total: Int64 = 0
            if let e = fm.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: [.fileSizeKey]) {
                for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
            return total
        }
        let support = "~/Library/Application Support/Tolk"
        let items: [(String, String, String)] = [
            ("Настройки", TolkConfig.defaultPath, "Всё, что на этой странице. Можно скопировать на другой Mac."),
            ("Глоссарий и правила", config.effectiveRulesPath, "Активный профиль; редактируется в разделе «Глоссарий»."),
            ("История переводов", HistoryStore.defaultPath, "Только на этом Mac. Выключается и очищается в разделе «История»."),
            ("Память стиля", support + "/style.db", "Зашифрованные примеры ваших сообщений для подсказок."),
            ("Статистика", support + "/usage-stats.json", "Только числа — без текста."),
            ("Модели подсказок", ModelLibrary.folderDisplay, "Файлы .gguf; управление во вкладке «Модели»."),
            ("Журнал", "~/Library/Logs/Tolk", "События работы программы, без переводимых текстов."),
        ]
        let out = items.map { StorageItem(title: $0.0, path: $0.1, note: $0.2, bytes: size($0.1)) }
        if out != storage { storage = out }
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
    }

    // MARK: Defaults

    /// Back to the measured defaults; instructions, the model and the app lists stay.
    func resetAutocompleteTuning() {
        let d = TolkConfig()
        config.autocompleteFrequency = d.autocompleteFrequency
        config.autocompleteLength = d.autocompleteLength
        config.autocompletePatient = d.autocompletePatient
        config.autocompletePatientDelay = d.autocompletePatientDelay
        config.autocompleteCaretBubble = d.autocompleteCaretBubble
        config.autocompleteScreenContext = d.autocompleteScreenContext
        config.autocompleteUseGlossary = d.autocompleteUseGlossary
        config.autocompleteEmoji = d.autocompleteEmoji
        config.autocorrect = d.autocorrect
        config.autocompleteWordPreference = d.autocompleteWordPreference
        config.autocompleteBatteryRare = d.autocompleteBatteryRare
        config.autocompleteBatteryNoScreen = d.autocompleteBatteryNoScreen
        config.autocompleteBatteryShort = d.autocompleteBatteryShort
    }

    func resetTranslateTuning() {
        let d = TolkConfig()
        config.doubleCopyInterval = d.doubleCopyInterval
        config.keepWarmMinutes = d.keepWarmMinutes
        config.toneByApp = TolkConfig.defaultToneByApp
    }

    // MARK: Server models

    /// Address the «Модели» tab talks to: the home one, or the outside one (with its headers) when home is empty.
    func configureServer() {
        let lan = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if lan.isEmpty { server.configure(base: config.remoteURL, headers: config.remoteHeaders) }
        else { server.configure(base: lan, headers: [:]) }
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func addOffApp(_ id: String) {
        if !config.autocompleteOffApps.contains(id) { config.autocompleteOffApps.append(id) }
    }

    private let path: String
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    init(config: TolkConfig, path: String = TolkConfig.defaultPath) {
        self.config = config
        self.path = path
        headers = config.remoteHeaders.sorted { $0.key < $1.key }.map { HeaderRow(key: $0.key, value: $0.value) }
    }

    // MARK: Saving

    private func syncHeaders() {
        var dict: [String: String] = [:]
        for h in headers {
            let k = h.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { dict[k] = h.value }
        }
        config.remoteHeaders = dict // triggers scheduleSave if changed
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard dirty else { return }
        dirty = false
        var c = config
        c.ollamaURL = c.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        c.remoteURL = c.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        c.model = c.model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try c.save(to: path)
            saveFailed = false
            saveStatus = "Сохранено"
        } catch {
            saveFailed = true
            saveStatus = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    // MARK: Status

    #if DEBUG
    /// Dev: how many times the 2-second poll ran (idle measurement, TOLK_IDLE_TICKS).
    nonisolated(unsafe) static var debugRefreshCount = 0
    #endif

    func refreshStatus() {
        #if DEBUG
        Self.debugRefreshCount += 1
        #endif
        // Assign only on change: every @Published write re-lays out the whole Form (was ~5% CPU at idle).
        let access = AXIsProcessTrusted()
        if access != hasAccessibility { hasAccessibility = access }
        let login = LaunchAgent.isEnabled
        if login != launchAtLogin { launchAtLogin = login }
        let screen = CGPreflightScreenCaptureAccess()
        if screen != hasScreenRecording { hasScreenRecording = screen }
    }

    func openAccessibilitySettings() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAgent.setEnabled(on)
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = LaunchAgent.isEnabled
    }

    // MARK: Connection check

    func checkConnection() {
        let lan = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = config.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = config.remoteHeaders
        let model = config.model
        lanCheck = lan.isEmpty ? .failed("адрес не указан") : .checking
        remoteCheck = remote.isEmpty ? .idle : .checking
        if !lan.isEmpty {
            Task { @MainActor in
                let r = await OllamaProbe.check(base: lan, headers: [:], model: model)
                lanCheck = r.state
                if !r.models.isEmpty { availableModels = r.models }
            }
        }
        if !remote.isEmpty {
            Task { @MainActor in
                let r = await OllamaProbe.check(base: remote, headers: headers, model: model)
                remoteCheck = r.state
                if availableModels.isEmpty, !r.models.isEmpty { availableModels = r.models }
            }
        }
    }

    // MARK: Rules file

    /// Translation models on the server (`*-translate`), plus the ones already configured.
    var translateModels: [String] {
        var names = availableModels.map { $0.replacingOccurrences(of: ":latest", with: "") }
            .filter { $0.hasSuffix("-translate") }
        for m in [config.model] + config.profiles.compactMap(\.model) where !m.isEmpty && !names.contains(m) {
            names.append(m)
        }
        return names.sorted()
    }

    func chooseRulesFile(forProfile id: String) {
        guard let i = config.profiles.firstIndex(where: { $0.id == id }) else { return }
        let current = URL(fileURLWithPath: (config.profiles[i].rulesPath as NSString).expandingTildeInPath)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Файл правил и глоссария для профиля «\(config.profiles[i].name)» (Markdown)"
        panel.prompt = "Выбрать"
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.profiles[i].rulesPath = (url.path as NSString).abbreviatingWithTildeInPath
    }

    func addProfile() {
        var n = config.profiles.count + 1
        while config.profiles.contains(where: { $0.id == "p\(n)" }) { n += 1 }
        config.profiles.append(GlossaryProfile(id: "p\(n)", name: "Профиль \(n)", rulesPath: "~/Translate/profile-\(n).md"))
    }

    func removeProfile(_ id: String) {
        guard config.profiles.count > 1 else { return }
        config.profiles.removeAll { $0.id == id }
        if config.activeProfileID == id { config.activeProfileID = config.profiles[0].id }
    }

    func revealAutocompleteModel() {
        let url = URL(fileURLWithPath: (config.autocompleteModel as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
    }

    /// Running regular apps (name, bundle id) for "add instructions for an app", sorted by name.
    static func runningApps() -> [(name: String, id: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a -> (String, String)? in
                guard let id = a.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return (a.localizedName ?? id, id)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    /// `.gguf` files in the models folder (paths with ~), plus the current one if it lives elsewhere.
    func ggufModels() -> [String] {
        let dir = (("~/Library/Application Support/Tolk/models") as NSString).expandingTildeInPath
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
            .map { "~/Library/Application Support/Tolk/models/" + $0 }
        var out = files
        if !out.contains(config.autocompleteModel) { out.insert(config.autocompleteModel, at: 0) }
        return out
    }

    func addToneApp(_ id: String) {
        if config.toneByApp[id] == nil { config.toneByApp[id] = .chat }
    }

    func addAppInstruction(_ id: String) {
        if config.autocompleteAppInstructions[id] == nil { config.autocompleteAppInstructions[id] = "" }
    }

    /// Asks, then tells the style feature to forget everything it learned.
    func confirmDeleteLearned() {
        let a = NSAlert()
        a.messageText = "Удалить выученное?"
        a.informativeText = "Примеры ваших сообщений, по которым подсказки подстраиваются под ваш стиль, будут стёрты. Это нельзя отменить."
        a.addButton(withTitle: "Удалить")
        a.addButton(withTitle: "Отмена")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: Notification.Name("TolkStyleMemoryDeleteAll"), object: nil)
        }
    }

    /// Names for apps that are often not installed (the system lookup fails for them).
    static let knownAppNames: [String: String] = [
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm2", "com.apple.dt.Xcode": "Xcode",
        "com.microsoft.VSCode": "Visual Studio Code", "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.microsoft.Outlook": "Outlook", "com.readdle.smartemail-Mac": "Spark", "net.whatsapp.WhatsApp": "WhatsApp",
        "com.microsoft.teams2": "Microsoft Teams", "com.tinyspeck.slackmacgap": "Slack", "ru.keepcoder.Telegram": "Telegram",
        "com.hnc.Discord": "Discord", "com.apple.mail": "Mail",
    ]

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return knownAppNames[bundleID] ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Ollama probe

enum OllamaProbe {
    struct Result { var state: CheckState; var models: [String] }

    static func check(base: String, headers: [String: String], model: String) async -> Result {
        guard let root = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base),
              root.scheme == "http" || root.scheme == "https" else {
            return Result(state: .failed("неверный адрес"), models: [])
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        func request(_ path: String) -> URLRequest {
            var r = URLRequest(url: root.appendingPathComponent(path))
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            return r
        }

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request("api/version"))
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else { return Result(state: .failed("нет ответа"), models: []) }
            guard http.statusCode == 200 else {
                let hint = (http.statusCode == 401 || http.statusCode == 403) ? " — проверьте заголовки доступа" : ""
                return Result(state: .failed("HTTP \(http.statusCode)\(hint)"), models: [])
            }
            let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String
            guard let version else { return Result(state: .failed("ответ не похож на Ollama"), models: []) }

            var models: [String] = []
            if let (tagsData, _) = try? await session.data(for: request("api/tags")),
               let obj = try? JSONSerialization.jsonObject(with: tagsData) as? [String: Any],
               let list = obj["models"] as? [[String: Any]] {
                models = list.compactMap { $0["name"] as? String }.sorted()
            }
            var text = "Ollama \(version) · \(ms) мс"
            if !models.isEmpty {
                let names = Set(models.flatMap { [$0, $0.replacingOccurrences(of: ":latest", with: "")] })
                text += names.contains(model) ? " · модель на месте" : " · модели «\(model)» нет на сервере"
            }
            return Result(state: .ok(text), models: models)
        } catch let e as URLError {
            let msg: String
            switch e.code {
            case .timedOut: msg = "сервер не ответил за 4 с"
            case .cannotConnectToHost: msg = "сервер не принимает подключения"
            case .cannotFindHost, .dnsLookupFailed: msg = "адрес не найден"
            case .notConnectedToInternet: msg = "нет сети"
            case .secureConnectionFailed, .serverCertificateUntrusted: msg = "ошибка HTTPS-сертификата"
            default: msg = e.localizedDescription
            }
            return Result(state: .failed(msg), models: [])
        } catch {
            return Result(state: .failed(error.localizedDescription), models: [])
        }
    }
}

// MARK: - Launch at login (LaunchAgent, same format as scripts/install.sh)

enum LaunchAgent {
    static let label = "local.vk.tolk"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Running from a real .app bundle (not `swift run`)?
    static var canEnable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Writes / removes the agent. It is not loaded now (that would `open` the running app and pop
    /// the main window via reopen); launchd picks it up at the next login.
    static func setEnabled(_ on: Bool) throws {
        if on {
            guard canEnable else {
                throw NSError(domain: "Tolk", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Tolk запущен не из приложения (.app) — автозапуск включается в установленной версии"])
            }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--background"],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if isEnabled { try FileManager.default.removeItem(at: plistURL) }
        }
    }
}

// MARK: - Small models of the page

struct StorageItem: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let path: String
    let note: String
    let bytes: Int64
}

enum LogFilter: String, CaseIterable, Identifiable {
    case all, problems, translate, autocomplete, capture, models
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Всё"
        case .problems: "Проблемы"
        case .translate: "Перевод"
        case .autocomplete: "Подсказки"
        case .capture: "Снимки экрана"
        case .models: "Модели"
        }
    }

    static func isProblem(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["failed", "error", "unavailable", "crash", "exception", "остановилась", "не запустился", "не загрузилась", "занят",
                "no effect", "refused", "not created", "exhausted", "taken", "not readable"].contains { l.contains($0) }
    }

    func matches(_ line: String) -> Bool {
        switch self {
        case .all: true
        case .problems: Self.isProblem(line)
        case .translate: ["translate:", "double cmd+c", "reply", "quick ", "vkbox", "incremental:", "type-translate:", "mask:"].contains { line.lowercased().contains($0) }
        case .autocomplete: line.contains("autocomplete:") || line.contains("style:")
        case .capture: line.contains("capture")
        case .models: line.contains("models:") || line.contains("llama-server") || line.contains("model ready") || line.contains("vkbox")
        }
    }
}
