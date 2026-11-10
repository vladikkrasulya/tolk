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
    case translate, autocomplete, general
    var id: String { rawValue }
    var title: String {
        switch self { case .translate: "Перевод"; case .autocomplete: "Автодополнение"; case .general: "Общие" }
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

    func refreshStats() {
        guard tab == .autocomplete else { return }
        let d = ACStatsSource.provider()
        if d != acStats { acStats = d }
    }

    func resetStats() {
        ACStatsSource.reset()
        acStats = ACStatsData()
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

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            Form {
                switch model.tab {
                case .translate:
                    serverSection
                    fallbackSection
                    remoteSection
                    languageSection
                    rulesSection
                    toneSection
                    copySection
                case .autocomplete:
                    autocompleteSection
                    ACStatsSection(model: model)
                    acInstructionsSection
                    acContextSection
                    acTypingSection
                    typeTranslateSection
                    acStyleSection
                    acOffAppsSection
                case .general:
                    launchSection
                    HotKeysSection()
                    accessSection
                    aboutSection
                }
            }
            .formStyle(.grouped)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) { footer }
        .onChange(of: model.tab) { _, _ in model.refreshStats() }
    }

    /// Short explanation under a setting.
    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Перевод

    private var serverSection: some View {
        Section {
            TextField("Адрес в домашней сети", text: $model.config.ollamaURL, prompt: Text("http://192.168.1.13:11434"))
            hint("Где работает Ollama с моделью перевода. Сначала Tolk пробует этот адрес, затем адрес вне дома.")
            ModelPicker(title: "Модель перевода", selection: $model.config.model, models: model.translateModels)
            hint("Какая модель переводит. Для профиля глоссария можно выбрать свою (см. «Профили глоссария»).")
            HStack(alignment: .firstTextBaseline) {
                Button("Проверить соединение") { model.checkConnection() }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    CheckLabel(title: "Дома", state: model.lanCheck)
                    if !model.config.remoteURL.trimmingCharacters(in: .whitespaces).isEmpty {
                        CheckLabel(title: "Вне дома", state: model.remoteCheck)
                    }
                }
            }
        } header: {
            Text("Сервер и модель перевода")
                .onAppear { if model.availableModels.isEmpty { model.checkConnection() } }
        }
    }

    private var fallbackSection: some View {
        Section {
            Picker("Если сервер недоступен", selection: $model.config.fallback) {
                ForEach(FallbackProvider.allCases, id: \.self) { f in
                    Text(f.title).tag(f)
                        .disabled(f == .apple && !AppleTranslationProvider.isSupportedOnThisMac)
                }
            }
            hint(fallbackHint(model.config.fallback))
        } header: {
            Text("Запасной перевод")
        }
    }

    private var remoteSection: some View {
        Section {
            TextField("Адрес вне дома", text: $model.config.remoteURL, prompt: Text("https://tolk.example.com"))
            hint("Необязательно. Например, адрес Cloudflare Tunnel. Пустой адрес — только домашняя сеть.")
            ForEach($model.headers) { $row in
                HStack(spacing: 8) {
                    TextField("", text: $row.key, prompt: Text("Заголовок"))
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    SecureField("", text: $row.value, prompt: Text("Значение"))
                        .labelsHidden()
                    Button {
                        model.headers.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Удалить заголовок")
                }
            }
            Button {
                model.headers.append(HeaderRow(key: "", value: ""))
            } label: {
                Label("Добавить заголовок доступа", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            hint("Заголовки для адреса вне дома, например CF-Access-Client-Id и CF-Access-Client-Secret.")
        } header: {
            Text("Доступ из дома")
        }
    }

    private var languageSection: some View {
        Section {
            languagePicker("Основной язык", selection: $model.config.primaryLanguage)
            languagePicker("Второй язык", selection: $model.config.secondaryLanguage)
            hint("Текст на основном языке (и на украинском) переводится на второй, всё остальное — на основной.")
        } header: {
            Text("Языки по умолчанию")
        }
    }

    private func languagePicker(_ title: String, selection: Binding<Language>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Language.allCases, id: \.self) { Text("\($0.flag)  \(UIText.capitalized($0))").tag($0) }
        }
    }

    private var copySection: some View {
        Section {
            LabeledContent("Двойное ⌘C") {
                HStack {
                    Slider(value: $model.config.doubleCopyInterval, in: 0.2...0.8, step: 0.05)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.2f с", model.config.doubleCopyInterval))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            hint("Сколько секунд может пройти между двумя нажатиями ⌘C, чтобы Tolk показал перевод выделенного.")
        } header: {
            Text("Двойной ⌘C")
        }
    }

    // MARK: Общие

    private var launchSection: some View {
        Section {
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            .disabled(!LaunchAgent.canEnable && !model.launchAtLogin)
            hint("Tolk сам запустится в строке меню после входа в систему.")
            if let err = model.launchError {
                Text(err).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Запуск")
        }
    }

    // MARK: Автодополнение

    @ViewBuilder private var autocompleteSection: some View {
        Section {
            Toggle("Автодополнение (Tab)", isOn: $model.config.autocomplete)
            if model.config.autocomplete, let err = model.acError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Модель не работает: \(err)").font(.callout).foregroundStyle(.red)
                    Spacer()
                    Button("Повторить") { model.onRetryAutocomplete?() }
                }
            }
            hint("Серый текст у курсора в любой программе: Tab принимает слово, → всё, Esc скрывает. Модель работает локально на этом Mac.")
            HStack {
                Picker("Модель", selection: $model.config.autocompleteModel) {
                    ForEach(model.ggufModels(), id: \.self) { path in
                        Text((path as NSString).lastPathComponent).tag(path)
                    }
                }
                Button("Показать в Finder") { model.revealAutocompleteModel() }
            }
            hint("Файлы .gguf из папки ~/Library/Application Support/Tolk/models.")
            Picker("Длина подсказки", selection: $model.config.autocompleteLength) {
                Text("Короткая (до 3 слов)").tag("short")
                Text("Средняя (до 6)").tag("medium")
                Text("Длинная (до 12)").tag("long")
            }
            hint("Чем длиннее подсказка, тем дольше модель её считает.")
            Picker("Частота подсказок", selection: $model.config.autocompleteFrequency) {
                Text("Реже, но точнее").tag("rare")
                Text("Обычно").tag("normal")
                Text("Чаще").tag("often")
            }
            hint("Реже — подсказка появляется, только когда модель уверена (около 2 из 3 первых слов верные). Чаще — подсказок больше, но больше промахов.")
            Toggle("Контекст со снимка экрана (распознавание текста)", isOn: $model.config.autocompleteScreenContext)
            hint("Если текст окна не читается напрямую (Slack, Telegram, Teams), Tolk распознаёт его на снимке экрана. Нужно разрешение «Запись экрана».")
        } header: {
            Text("Основное")
        }
        Section {
            Toggle("Подсказывать реже", isOn: $model.config.autocompleteBatteryRare)
            Toggle("Без снимков экрана", isOn: $model.config.autocompleteBatteryNoScreen)
            Toggle("Короткие подсказки", isOn: $model.config.autocompleteBatteryShort)
            hint("Действует, пока Mac работает от батареи: меньше нагрузка, тише вентилятор.")
        } header: {
            Text("На батарее")
        }
    }

    private var acInstructionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Общие инструкции").font(.callout)
                TextEditor(text: $model.config.autocompleteInstructions)
                    .font(.body).frame(minHeight: 54, maxHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                hint("Например: «пиши коротко», «на Вы», «без эмодзи». Действуют везде.")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Инструкции по программам").font(.callout)
                    Spacer()
                    Menu("Добавить программу") {
                        ForEach(SettingsModel.runningApps(), id: \.id) { app in
                            Button(app.name) { model.addAppInstruction(app.id) }
                                .disabled(model.config.autocompleteAppInstructions[app.id] != nil)
                        }
                    }
                    .fixedSize()
                }
                if model.config.autocompleteAppInstructions.isEmpty {
                    hint("Нет. Выберите запущенную программу, чтобы задать ей свои инструкции.")
                }
                ForEach(model.config.autocompleteAppInstructions.keys.sorted(), id: \.self) { id in
                    HStack {
                        Text(SettingsModel.appName(id)).frame(width: 120, alignment: .leading).lineLimit(1)
                        TextField("Инструкции для этой программы", text: Binding(
                            get: { model.config.autocompleteAppInstructions[id] ?? "" },
                            set: { model.config.autocompleteAppInstructions[id] = $0 }))
                        Button(role: .destructive) {
                            model.config.autocompleteAppInstructions[id] = nil
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Инструкции")
        }
    }

    private var acContextSection: some View {
        Section {
            Toggle("Глоссарий и тон", isOn: $model.config.autocompleteUseGlossary)
            hint("Подсказки используют термины активного профиля глоссария и тон программы (см. вкладку «Перевод»).")
            Toggle("Буфер обмена", isOn: $model.config.autocompleteClipboard)
            hint("Недавно скопированный короткий текст попадает в подсказку. Пароли и ключи отбрасываются.")
        } header: {
            Text("Что учитывать")
        }
    }

    private var acTypingSection: some View {
        Section {
            Toggle("Эмодзи (:fire → 🔥)", isOn: $model.config.autocompleteEmoji)
            hint("Набрали двоеточие и слово, например :fire или :спасибо, — Tab вставит эмодзи.")
            Toggle("Исправлять опечатки", isOn: $model.config.autocorrect)
            hint("Опечатка в последнем слове показывается серым исправлением, Tab применяет.")
        } header: {
            Text("Помощь при наборе")
        }
    }

    private var typeTranslateSection: some View {
        let names = model.config.typeTranslateApps.filter(\.value).keys.sorted()
        return Section {
            Toggle("Включать автоматически, если собеседник пишет на другом языке", isOn: $model.config.typeTranslateAuto)
            hint("Пишете по-русски — под полем появляется перевод на язык собеседника, Tab вставляет его вместо вашего текста, Esc оставляет ваш. Tolk сам ничего не отправляет. Включить или выключить для текущего приложения: горячая клавиша (по умолчанию ⌃⌥R, меняется во вкладке «Общие») или пункт в меню строки меню.")
            if !names.isEmpty {
                HStack {
                    Text("Включено в: " + names.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Выключить везде") { model.config.typeTranslateApps = [:] }
                }
            }
        } header: {
            Text("Перевод при наборе")
        }
    }

    private var acStyleSection: some View {
        Section {
            Toggle("Учиться на моих сообщениях", isOn: $model.config.autocompleteLearnStyle)
            hint("Запоминаются только на этом Mac: сообщения, в которых вы приняли подсказку, и сами принятые фразы. Они подсказывают модели ваш стиль и слова.")
            Toggle("Запоминать все отправленные сообщения", isOn: $model.config.autocompleteRecordAll)
            hint("По умолчанию выключено: в память попадают только сообщения с принятой подсказкой.")
            Picker("Выбор слов", selection: $model.config.autocompleteWordPreference) {
                Text("Выключен").tag("off")
                Text("Средний").tag("medium")
                Text("Сильный").tag("strong")
            }
            hint("Модель охотнее предлагает слова, которые вы часто пишете сами. Работает, только пока включено «Учиться на моих сообщениях».")
            Button("Удалить выученное…", role: .destructive) { model.confirmDeleteLearned() }
        } header: {
            Text("Ваш стиль")
        }
    }

    private var acOffAppsSection: some View {
        Section {
            if model.config.autocompleteOffApps.isEmpty {
                Text("Выключенных программ нет.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.config.autocompleteOffApps, id: \.self) { id in
                    HStack {
                        Text(SettingsModel.appName(id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            model.config.autocompleteOffApps.removeAll { $0 == id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            hint("В этих программах автодополнение молчит (терминалы, редакторы кода). Быстро выключить в текущей — в меню Tolk.")
        } header: {
            Text("Выключено в программах")
        }
    }

    // Тон по программам

    private var toneSection: some View {
        Section {
            if model.config.toneByApp.isEmpty {
                Text("Нет. Тон выбирается автоматически по тексту.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.config.toneByApp.keys.sorted(), id: \.self) { id in
                HStack {
                    Text(SettingsModel.appName(id))
                    Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.config.toneByApp[id] ?? .auto },
                        set: { model.config.toneByApp[id] = $0 })) {
                        Text("Авто").tag(Tone.auto)
                        Text("Чат").tag(Tone.chat)
                        Text("Письмо").tag(Tone.formal)
                    }
                    .labelsHidden().fixedSize()
                    Button(role: .destructive) { model.config.toneByApp[id] = nil } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Menu("Добавить программу") {
                ForEach(SettingsModel.runningApps(), id: \.id) { app in
                    Button(app.name) { model.addToneApp(app.id) }
                        .disabled(model.config.toneByApp[app.id] != nil)
                }
            }
            .fixedSize()
        } header: {
            Text("Тон по программам")
        } footer: {
            Text("Общее для перевода и подсказок автодополнения. Какой тон использовать, когда активна эта программа: Чат — разговорно, Официально — вежливо.")
                .foregroundStyle(.secondary)
        }
    }

    // Правила

    private var rulesSection: some View {
        Section {
            Picker("Активный профиль", selection: $model.config.activeProfileID) {
                ForEach(model.config.profiles) { p in Text(p.name).tag(p.id) }
            }
            .pickerStyle(.segmented)
            ForEach($model.config.profiles) { $p in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Название", text: $p.name).frame(maxWidth: 160)
                        if p.id == model.config.activeProfileID {
                            Text("активный").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        if model.config.profiles.count > 1 {
                            Button(role: .destructive) { model.removeProfile(p.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Удалить профиль (файл глоссария останется)")
                        }
                    }
                    HStack {
                        Text(p.rulesPath).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Файл…") { model.chooseRulesFile(forProfile: p.id) }
                    }
                    ModelPicker(title: "Модель профиля", selection: Binding(
                        get: { p.model ?? "" }, set: { p.model = $0.isEmpty ? nil : $0 }),
                        models: model.translateModels, allowDefault: true)
                }
                .padding(.vertical, 2)
            }
            Button { model.addProfile() } label: { Label("Добавить профиль", systemImage: "plus") }
                .buttonStyle(.borderless)
        } header: {
            Text("Профили глоссария")
        } footer: {
            Text("У каждого профиля свой глоссарий и стиль — например, «Работа» со сленгом adtech и «Дом» для книг и документов. Переключать можно и из меню Tolk. Редактировать глоссарий активного профиля — в разделе «Глоссарий».")
                .foregroundStyle(.secondary)
        }
    }

    private func fallbackHint(_ f: FallbackProvider) -> String {
        switch f {
        case .google:
            return "Быстро и бесплатно, но текст уходит в Google. Без глоссария, тона и «причесать»."
        case .apple:
            return AppleTranslationProvider.isSupportedOnThisMac
                ? "Прямо на этом Mac, без интернета, текст никуда не уходит. Качество проще Google. Нужны скачанные языки: Системные настройки → Основные → Язык и регион → Языки перевода."
                : "Нужна macOS 26 или новее."
        case .none:
            return "Без домашнего сервера Tolk покажет ошибку — ничего не уходит в интернет."
        }
    }

    // Доступ

    private var accessSection: some View {
        Section {
            HStack {
                Image(systemName: model.hasAccessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.hasAccessibility ? .green : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Универсальный доступ")
                    Text(model.hasAccessibility ? "Есть — двойное ⌘C работает в любых приложениях"
                                                : "Нет — без него двойное ⌘C не сработает")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.hasAccessibility {
                    Button("Открыть настройки…") { model.openAccessibilitySettings() }
                }
            }
        } header: {
            Text("Разрешения")
        }
    }

    // О программе

    private var aboutSection: some View {
        Section {
            HStack {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tolk \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    Text(Diagnostics.version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Сообщить о проблеме…") { Diagnostics.copyProblemReport() }
            }
        } header: {
            Text("О программе")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !model.saveStatus.isEmpty {
                Image(systemName: model.saveFailed ? "xmark.octagon.fill" : "checkmark.circle")
                    .foregroundStyle(model.saveFailed ? .red : .secondary)
            }
            Text(model.saveStatus.isEmpty ? "Изменения сохраняются автоматически" : model.saveStatus)
                .foregroundStyle(model.saveFailed ? .red : .secondary)
            Spacer()
            Text((TolkConfig.defaultPath as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct CheckLabel: View {
    let title: String
    let state: CheckState

    var body: some View {
        HStack(spacing: 5) {
            switch state {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
                Text("\(title): проверяю…").foregroundStyle(.secondary)
            case let .ok(text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(title): \(text)").foregroundStyle(.secondary)
            case let .failed(text):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("\(title): \(text)").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(2)
    }
}

/// Picker of translation models with human descriptions; «Другая…» reveals a free text field.
struct ModelPicker: View {
    let title: String
    @Binding var selection: String
    let models: [String]
    var allowDefault = false
    @State private var custom = false

    static func describe(_ id: String) -> String {
        let m = id.lowercased()
        if m.contains("qwen") { return "Qwen 35B — чуть быстрее, но хуже на рабочем жаргоне (290 против 313 из 321 на корпусе)" }
        if m.contains("gemma") { return "Gemma 26B — основная: точнее термины, меньше калек, живее русский и украинский" }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: Binding(
                get: { custom ? "__custom" : selection },
                set: { v in if v == "__custom" { custom = true } else { custom = false; selection = v } })) {
                if allowDefault { Text("Как по умолчанию").tag("") }
                ForEach(models, id: \.self) { m in Text(Self.describe(m)).tag(m) }
                Divider()
                Text("Другая…").tag("__custom")
            }
            if custom || (!selection.isEmpty && !models.contains(selection)) {
                TextField("Имя модели на сервере", text: $selection, prompt: Text("qwen-translate"))
                    .font(.callout)
            }
        }
    }
}
