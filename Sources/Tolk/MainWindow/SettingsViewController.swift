// Owned by the "main window" session.
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

    override func viewWillAppear() {
        super.viewWillAppear()
        model.refreshStatus()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        model.saveNow() // don't lose a pending debounced save
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
    @Published var saveStatus = ""
    @Published var saveFailed = false
    @Published var lanCheck: CheckState = .idle
    @Published var remoteCheck: CheckState = .idle
    @Published var availableModels: [String] = []
    @Published var hasAccessibility = AXIsProcessTrusted()
    @Published var launchAtLogin = LaunchAgent.isEnabled
    @Published var launchError: String?

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

    func refreshStatus() {
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

    var rulesURL: URL { URL(fileURLWithPath: (config.effectiveRulesPath as NSString).expandingTildeInPath) }
    var rulesExists: Bool { FileManager.default.fileExists(atPath: rulesURL.path) }

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

    func chooseRulesFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Выберите файл правил и глоссария (Markdown)"
        panel.prompt = "Выбрать"
        panel.directoryURL = rulesURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.rulesPath = (url.path as NSString).abbreviatingWithTildeInPath
    }

    func revealRules() {
        if rulesExists { NSWorkspace.shared.activateFileViewerSelecting([rulesURL]) }
        else { NSSound.beep() }
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
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            serverSection
            remoteSection
            languageSection
            behaviorSection
            rulesSection
            accessSection
            aboutSection
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { footer }
        .onReceive(timer) { _ in model.refreshStatus() }
    }

    // Сервер

    private var serverSection: some View {
        Section {
            TextField("Адрес в домашней сети", text: $model.config.ollamaURL, prompt: Text("http://192.168.1.13:11434"))
            ModelPicker(title: "Модель", selection: $model.config.model, models: model.translateModels)
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
            Text("Сервер перевода")
                .onAppear { if model.availableModels.isEmpty { model.checkConnection() } }
        } footer: {
            Text("Ollama на домашнем сервере. Сначала Tolk пробует этот адрес, затем — адрес вне дома.")
                .foregroundStyle(.secondary)
        }
    }

    // Вне дома

    private var remoteSection: some View {
        Section {
            TextField("Адрес вне дома", text: $model.config.remoteURL, prompt: Text("https://tolk.example.com"))
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
        } header: {
            Text("Доступ вне дома")
        } footer: {
            Text("Необязательно. Например, адрес Cloudflare Tunnel и заголовки CF-Access-Client-Id / CF-Access-Client-Secret. Пустой адрес — только домашняя сеть.")
                .foregroundStyle(.secondary)
        }
    }

    // Языки

    private var languageSection: some View {
        Section {
            Picker("Основной язык", selection: $model.config.primaryLanguage) {
                ForEach(Language.allCases, id: \.self) { Text("\($0.flag)  \(UIText.capitalized($0))").tag($0) }
            }
            Picker("Второй язык", selection: $model.config.secondaryLanguage) {
                ForEach(Language.allCases, id: \.self) { Text("\($0.flag)  \(UIText.capitalized($0))").tag($0) }
            }
        } header: {
            Text("Языки")
        } footer: {
            Text("Текст на основном языке (и на украинском) переводится на второй, всё остальное — на основной.")
                .foregroundStyle(.secondary)
        }
    }

    // Поведение

    private var behaviorSection: some View {
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
            Picker("Если сервер недоступен", selection: $model.config.fallback) {
                ForEach(FallbackProvider.allCases, id: \.self) { f in
                    Text(f.title).tag(f)
                        .disabled(f == .apple && !AppleTranslationProvider.isSupportedOnThisMac)
                }
            }
            Text(fallbackHint(model.config.fallback))
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            .disabled(!LaunchAgent.canEnable && !model.launchAtLogin)
            if let err = model.launchError {
                Text(err).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Поведение")
        } footer: {
            Text("Интервал — сколько секунд может пройти между двумя нажатиями ⌘C.")
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
        if m.contains("qwen") { return "Qwen 35B — быстрее, лучше английский, деловые и юридические тексты" }
        if m.contains("gemma") { return "Gemma 26B — меньше калек, живее русский и украинский, книги" }
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
