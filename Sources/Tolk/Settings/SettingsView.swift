// Настройки: tab bar, status strip, and the «Перевод» and «Общие» tabs. The other tabs live next to this file.
// Every tab is a set of cards in a `MasonryLayout`, so the page fills a window of any width.
import SwiftUI
import AppKit
import TolkCore

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                MasonryLayout {
                    switch model.tab {
                    case .translate: TranslateTab(model: model)
                    case .autocomplete: AutocompleteTab(model: model)
                    case .models: ModelsTab(model: model, library: model.library, server: model.server)
                    case .stats: StatsTab(model: model)
                    case .log: LogTab(model: model)
                    case .general: GeneralTab(model: model)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .background(TolkStyle.page)
        .safeAreaInset(edge: .bottom) { footer }
        .onChange(of: model.tab) { _, _ in model.refreshStats() }
    }

    // MARK: Header: tabs + status

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Narrow window: the tab icons go first, so the bar stays on one line.
            let problems = statuses.filter { $0.0.2 != .ok }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { tabBar(icons: true); Spacer(minLength: 8); if problems.isEmpty { allGood } }
                tabBar(icons: true)
                tabBar(icons: false)
                FlowLayout(spacing: 2) { tabButtons(icons: false) }
            }
            if !problems.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(0..<problems.count, id: \.self) { statusPill(problems[$0].0, tab: problems[$0].1) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TolkStyle.page)
        .overlay(alignment: .bottom) { Rectangle().fill(TolkStyle.hairline).frame(height: 0.5) }
        .onAppear { if model.lanCheck == .idle { model.checkConnection() } }
    }

    private var allGood: some View {
        SPill(text: "Всё работает", symbol: "checkmark", role: .ok)
            .help("Сервер перевода на связи, модель подсказок готова, разрешения macOS выданы")
    }

    private func tabBar(icons: Bool) -> some View {
        HStack(spacing: 2) { tabButtons(icons: icons) }
    }

    private func tabButtons(icons: Bool) -> some View {
        ForEach(SettingsTab.allCases) { tab in
            let on = model.tab == tab
            Button { model.tab = tab } label: {
                HStack(spacing: 5) {
                    if icons { Image(systemName: tab.symbol).imageScale(.small) }
                    Text(tab.title).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .fontWeight(on ? .medium : .regular)
                .background(on ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: TolkStyle.controlRadius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var statuses: [((String, String, SRole), SettingsTab)] {
        [(serverStatus, .translate), (suggestStatus, .models),
         (model.hasAccessibility ? ("Универсальный доступ", "checkmark", .ok) : ("Нет универсального доступа", "exclamationmark.triangle", .warn), .general),
         (model.hasScreenRecording ? ("Запись экрана", "checkmark", .ok) : ("Нет записи экрана", "exclamationmark.triangle", .warn), .general)]
    }

    private func statusPill(_ s: (String, String, SRole), tab: SettingsTab) -> some View {
        Button { model.open(tab, section: 0) } label: { SPill(text: s.0, symbol: s.1, role: s.2) }
            .buttonStyle(.plain)
            .help("Открыть вкладку «\(tab.title)»")
    }

    private var serverStatus: (String, String, SRole) {
        switch model.lanCheck {
        case .ok:
            return ("Сервер перевода на связи", "checkmark", .ok)
        case .failed(let why):
            if case .ok = model.remoteCheck { return ("Сервер перевода: вне дома", "checkmark", .ok) }
            return ("Сервер перевода: \(why)", "xmark", .bad)
        case .checking:
            return ("Проверяю сервер…", "arrow.triangle.2.circlepath", .neutral)
        case .idle:
            return ("Сервер перевода", "circle", .neutral)
        }
    }

    private var suggestStatus: (String, String, SRole) {
        if !model.config.autocomplete { return ("Автодополнение выключено", "pause", .neutral) }
        if model.acError != nil { return ("Модель подсказок не работает", "exclamationmark.triangle", .warn) }
        return model.acReady ? ("Модель подсказок готова", "checkmark", .ok) : ("Модель подсказок загружается…", "arrow.triangle.2.circlepath", .neutral)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(TolkStyle.page)
        .overlay(alignment: .top) { Rectangle().fill(TolkStyle.hairline).frame(height: 0.5) }
    }
}

// MARK: - Перевод

struct TranslateTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SSections(tab: .translate) { section in
            switch section {
            case 0:
                serverCard
                modelCard
                fallbackCard
                remoteCard
            case 1:
                languageCard
                profilesCard
                toneCard
            case 2:
                samplingCard
                copyCard
            default:
                TranslatePromptCards(model: model)
            }
        }
    }

    private var serverCard: some View {
        SCard("Сервер перевода", symbol: "server.rack") {
            SRow("Адрес в домашней сети", hint: "Компьютер, на котором работает Ollama с моделью перевода. Tolk сначала пробует этот адрес, затем адрес вне дома.", divider: false) {
                TextField("", text: $model.config.ollamaURL, prompt: Text("http://192.168.1.10:11434"))
                    .textFieldStyle(.roundedBorder).frame(minWidth: 200, maxWidth: 280)
            }
            SRow("Соединение") {
                Button("Проверить") { model.checkConnection() }
            }
            VStack(alignment: .leading, spacing: 4) {
                CheckLabel(title: "Дома", state: model.lanCheck)
                if !model.config.remoteURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    CheckLabel(title: "Вне дома", state: model.remoteCheck)
                }
            }
            .padding(.bottom, 8)
            SRow("Держать модель загруженной", hint: keepWarmHint) {
                Picker("", selection: $model.config.keepWarmMinutes) {
                    Text("Не держать").tag(0)
                    Text("15 минут").tag(15)
                    Text("1 час").tag(60)
                    Text("8 часов").tag(480)
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private var keepWarmHint: String {
        switch model.config.keepWarmMinutes {
        case 0: "Сервер сам выгружает модель после простоя. Первый перевод после паузы ждёт загрузки — до минуты. Видеопамять сервера свободна для другого."
        case 15: "Если модель выгрузилась, а вы переводили в последние 15 минут, Tolk загрузит её заранее. Дольше перерыв — первый перевод ждёт до минуты."
        case 60: "В течение часа после последнего перевода модель возвращается в память сама: переводы всегда быстрые, но видеопамять сервера занята этот час."
        default: "Весь рабочий день модель остаётся в памяти сервера. Переводы без ожидания; для игр или другой модели на сервере места не будет."
        }
    }

    private var modelCard: some View {
        SCard("Модель перевода", symbol: "brain") {
            ModelPicker(title: "Переводит", selection: $model.config.model, models: model.translateModels)
            SHint("Какая модель на сервере переводит текст. У профиля глоссария может быть своя — см. «Профили глоссария».")
                .padding(.top, 6)
            HStack {
                SHint("Скачать другую модель на сервер или удалить лишнюю можно во вкладке «Модели».")
                Button("Модели…") { model.open(.models, section: 1) }
            }
            .padding(.top, 8)
        }
    }

    private var fallbackCard: some View {
        SCard("Если сервер недоступен", symbol: "arrow.triangle.branch") {
            SRow("Запасной перевод", hint: fallbackHint(model.config.fallback), divider: false) {
                Picker("", selection: $model.config.fallback) {
                    ForEach(FallbackProvider.allCases, id: \.self) { f in
                        Text(f.title).tag(f).disabled(f == .apple && !AppleTranslationProvider.isSupportedOnThisMac)
                    }
                }
                .labelsHidden().fixedSize()
            }
            if model.config.fallback == .apple, AppleTranslationProvider.isSupportedOnThisMac {
                AppleLanguagesRow(a: model.config.primaryLanguage, b: model.config.secondaryLanguage)
            }
            if model.config.fallback != .none {
                SToggle("Глоссарий в запасном переводе", isOn: $model.config.fallbackGlossary,
                        hint: "Термины из глоссария вставляются в текст до отправки: «капа», «фид», «флор» вместо «лимит», «лента», «нижний предел». Работает только для русского и английского. Проверено на 9 рабочих фразах: 5 стали лучше, 2 не изменились, в 2 переводчик исковеркал соседнее слово («аккаунт был причинён из-за фрода») — такой перевод стоит перечитывать.",
                        offHint: "Запасной переводчик получает текст как есть и переводит своими словами: «лимит» вместо «капа», «лента» вместо «фид». Зато без случайных искажений рядом с терминами.")
            }
        }
    }

    private func fallbackHint(_ f: FallbackProvider) -> String {
        switch f {
        case .google:
            return "Перевод придёт быстро и бесплатно, но текст уйдёт в Google. Тон и «причесать» в запасном переводе не работают, глоссарий — только с переключателем ниже."
        case .apple:
            return AppleTranslationProvider.isSupportedOnThisMac
                ? "Перевод делается на этом Mac, без интернета — текст никуда не уходит. Качество проще, чем у Google. Языки нужно скачать: Системные настройки → Основные → Язык и регион → Языки перевода."
                : "Нужна macOS 26 или новее."
        case .none:
            return "Tolk покажет ошибку и ничего не отправит в интернет. Выбирайте, если тексты нельзя показывать посторонним сервисам."
        }
    }

    private var languageCard: some View {
        SCard("Языки", symbol: "globe") {
            SRow("Основной язык", divider: false) { languagePicker($model.config.primaryLanguage) }
            SRow("Второй язык", hint: "Текст на основном языке (и на украинском) переводится на второй, всё остальное — на основной.") {
                languagePicker($model.config.secondaryLanguage)
            }
            SExample(text: "написали на «\(model.config.primaryLanguage.russianName)» → получите «\(model.config.secondaryLanguage.russianName)»; пришло на любом другом → «\(model.config.primaryLanguage.russianName)».")
        }
    }

    private func languagePicker(_ selection: Binding<Language>) -> some View {
        Picker("", selection: selection) {
            ForEach(Language.allCases, id: \.self) { Text("\($0.flag)  \(UIText.capitalized($0))").tag($0) }
        }
        .labelsHidden().fixedSize()
    }

    private var profilesCard: some View {
        SCard("Профили глоссария", symbol: "book.closed",
              subtitle: "У каждого профиля свой глоссарий и стиль — например, «Работа» с рабочим жаргоном и «Дом» для книг и документов. Переключать можно и из меню Tolk.") {
            Picker("", selection: $model.config.activeProfileID) {
                ForEach(model.config.profiles) { p in Text(p.name).tag(p.id) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.bottom, 8)
            ForEach($model.config.profiles) { $p in
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle().fill(TolkStyle.hairline).frame(height: 0.5)
                    HStack {
                        TextField("Название", text: $p.name).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                        if p.id == model.config.activeProfileID { SPill(text: "активный", role: .ok) }
                        Spacer()
                        if model.config.profiles.count > 1 {
                            Button(role: .destructive) { model.removeProfile(p.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Удалить профиль (файл глоссария останется на диске)")
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
                .padding(.bottom, 8)
            }
            Button { model.addProfile() } label: { Label("Добавить профиль", systemImage: "plus") }
                .buttonStyle(.borderless)
        }
    }

    private var toneCard: some View {
        SCard("Тон по программам", symbol: "theatermasks",
              subtitle: "Какой тон брать, когда активна эта программа. «Чат» — разговорно, на «ты». «Письмо» — вежливо, на «Вы». «Авто» — как в исходном тексте. Действует и на перевод, и на подсказки.") {
            if model.config.toneByApp.isEmpty {
                SHint("Программ нет: тон выбирается по самому тексту.")
            }
            ForEach(model.config.toneByApp.keys.sorted(), id: \.self) { id in
                HStack {
                    Text(SettingsModel.appName(id)).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.config.toneByApp[id] ?? .auto },
                        set: { model.config.toneByApp[id] = $0 })) {
                        Text("Авто").tag(Tone.auto)
                        Text("Чат").tag(Tone.chat)
                        Text("Письмо").tag(Tone.formal)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    Button(role: .destructive) { model.config.toneByApp[id] = nil } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Убрать программу из списка")
                }
                .padding(.vertical, 2)
            }
            AppMenu(title: "Добавить программу", isUsed: { model.config.toneByApp[$0] != nil }) { model.addToneApp($0) }
                .padding(.top, 6)
            SExample(text: "«Can you check this?» в Slack → «Глянешь?», в Почте → «Не могли бы Вы проверить?»").padding(.top, 8)
        }
    }

    private var remoteCard: some View {
        SCard("Доступ вне дома", symbol: "network",
              subtitle: "Необязательно. Если сервер виден из интернета (например, через Cloudflare Tunnel), Tolk будет переводить и вне домашней сети.") {
            SRow("Адрес вне дома", hint: "Пусто — перевод через сервер работает только дома, в остальное время действует запасной перевод.", divider: false) {
                TextField("", text: $model.config.remoteURL, prompt: Text("https://tolk.example.com"))
                    .textFieldStyle(.roundedBorder).frame(minWidth: 200, maxWidth: 280)
            }
            ForEach($model.headers) { $row in
                HStack(spacing: 8) {
                    TextField("", text: $row.key, prompt: Text("Заголовок")).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    SecureField("", text: $row.value, prompt: Text("Значение")).textFieldStyle(.roundedBorder)
                    Button { model.headers.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Удалить заголовок")
                }
                .padding(.bottom, 4)
            }
            Button { model.headers.append(HeaderRow(key: "", value: "")) } label: { Label("Добавить заголовок доступа", systemImage: "plus") }
                .buttonStyle(.borderless)
            SHint("Заголовки отправляются только на адрес вне дома — например, CF-Access-Client-Id и CF-Access-Client-Secret.").padding(.top, 4)
        }
    }

    private var samplingCard: some View {
        SCard("Параметры модели перевода", symbol: "dial.medium") {
            SSlider(title: "Температура", value: $model.config.translateTemperature, range: 0...1, step: 0.05,
                    format: { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") },
                    hint: temperatureHint, divider: false)
            SToggle("Одинаковый перевод для одинакового текста", isOn: $model.config.translateFixedSeed,
                    hint: "Тот же текст всегда переводится теми же словами (проверено: 3 из 3 совпадают).",
                    offHint: "Каждый раз перевод может быть сформулирован по-другому — удобно перебирать варианты кнопкой «заново», но результат нельзя воспроизвести. Кэш в этом режиме не используется.")
            SToggle("Кэш переводов", isOn: $model.config.translateCache,
                    hint: "Повторный перевод того же текста отдаётся мгновенно, без обращения к модели. Хранится сутки, только в памяти программы.",
                    offHint: "Каждый перевод заново считается моделью, даже если текст только что переводился.")
            SChoice(title: "Редактор после перевода", selection: $model.config.autoEditor, options: [
                .init(value: "off", title: "Выкл.", effect: "Редактор запускается только кнопкой. Перевод готов быстрее, но в длинных официальных текстах модель иногда ошибается в падежах."),
                .init(value: "formal", title: "Официальные", effect: "Для договоров, лицензий и официальных уведомлений длиннее 200 знаков готовый перевод сразу перечитывают редактор (кальки, термины) и корректор (падежи, опечатки). Действует и на странице «Документы»: если файл похож на официальный, так читается каждый его абзац. Такой перевод занимает в два-три раза больше времени."),
                .init(value: "always", title: "Всегда", effect: "Редактор перечитывает каждый перевод длиннее 200 знаков и каждый абзац любого документа. Качество ровнее, но всё вдвое медленнее."),
            ])
            SRow("Стандартные значения", hint: "Температура 0,10, одинаковый перевод и кэш включены, редактор — для официальных текстов.") {
                Button("Сбросить") { model.resetModelTuning(autocomplete: false) }
            }
        }
    }

    private var temperatureHint: String {
        let t = model.config.translateTemperature
        if t <= 0.15 { return "Низкая (стандартно 0,10): перевод точный и ближе к оригиналу, термины стабильны." }
        if t <= 0.5 { return "Средняя: формулировки свободнее и живее, но модель чаще отходит от глоссария и может потерять деталь." }
        return "Высокая: перевод заметно вольный, возможны выдуманные подробности. Для рабочей переписки не подходит."
    }

    private var copyCard: some View {
        SCard("Двойное ⌘C", symbol: "doc.on.doc") {
            SSlider(title: "Пауза между нажатиями", value: $model.config.doubleCopyInterval, range: 0.2...0.8, step: 0.05,
                    format: { String(format: "%.2f с", $0).replacingOccurrences(of: ".", with: ",") },
                    hint: copyHint, divider: false)
        }
    }

    private var copyHint: String {
        let v = model.config.doubleCopyInterval
        if v <= 0.3 { return "Нажимать ⌘C дважды нужно очень быстро. Случайных срабатываний почти нет, но перевод может не открыться с первого раза." }
        if v >= 0.6 { return "Сработает и при неторопливом двойном нажатии. Зато перевод может открыться, когда вы просто дважды скопировали текст." }
        return "Обычная скорость двойного нажатия: выделили текст, дважды нажали ⌘C — открылся перевод."
    }
}

// MARK: - Общие

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        SSections(tab: .general) { section in
            if section == 0 {
                launchCard
                permissionsCard
                hotKeysCard
            } else {
                storageCard
                resetCard
                aboutCard
            }
        }
    }

    private var launchCard: some View {
        SCard("Запуск", symbol: "power") {
            SRow("Запускать при входе в систему", hint: model.launchAtLogin
                 ? "Tolk сам появится в строке меню после включения Mac."
                 : "После перезагрузки Tolk нужно будет открыть вручную — до этого перевод по ⌘C и подсказки не работают.", divider: false) {
                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!LaunchAgent.canEnable && !model.launchAtLogin)
            }
            if let err = model.launchError { Text(err).font(.callout).foregroundStyle(.red) }
        }
    }

    private var permissionsCard: some View {
        SCard("Разрешения macOS", symbol: "lock.shield") {
            permission("Универсальный доступ", granted: model.hasAccessibility,
                       yes: "Есть. Двойное ⌘C, подсказки и вставка ответа работают в любых программах.",
                       no: "Нет. Без него не работают двойное ⌘C, подсказки и вставка текста в другие программы.",
                       divider: false) { model.openAccessibilitySettings() }
            permission("Запись экрана", granted: model.hasScreenRecording,
                       yes: "Есть. Работают перевод области экрана (⌥⇧S), контекст для подсказок в Slack и Telegram и плашка у курсора в браузере.",
                       no: "Нет. Перевод области экрана не работает; подсказки в Slack, Telegram и браузере хуже понимают, о чём разговор.") { model.requestScreenRecording() }
            SHint("Снимки экрана обрабатываются на этом Mac и никуда не отправляются.")
        }
    }

    private func permission(_ title: String, granted: Bool, yes: String, no: String, divider: Bool = true, open: @escaping () -> Void) -> some View {
        SRow(title, hint: granted ? yes : no, divider: divider) {
            if granted { SPill(text: "разрешено", symbol: "checkmark", role: .ok) }
            else { Button("Разрешить…") { open() } }
        }
    }

    private var hotKeysCard: some View {
        SCard("Горячие клавиши", symbol: "keyboard",
              subtitle: "Нажмите на сочетание и введите новое. Нужен ⌃ или ⌥. Esc — отмена, ⌫ — выключить сочетание. Снимок экрана — всегда ⌥⇧S.") {
            HotKeysList()
        }
    }

    private var storageCard: some View {
        SCard("Данные на диске", symbol: "internaldrive", subtitle: "Всё хранится на этом Mac. Здесь видно, что где лежит и сколько занимает.") {
            ForEach(model.storage) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 4)
                    HStack {
                        Text(item.title)
                        Spacer()
                        Text(item.bytes > 0 ? UsageText.bytes(item.bytes) : "пусто").monospacedDigit().foregroundStyle(.secondary)
                        Button { model.reveal(item.path) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Показать в Finder: \(item.path)")
                    }
                    Text(item.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 6)
            }
        }
        .onAppear { model.refreshStorage() }
    }

    private var resetCard: some View {
        SCard("Вернуть как было", symbol: "arrow.uturn.backward",
              subtitle: "Если после экспериментов стало хуже. Стандартные значения подобраны по замерам.") {
            SRow("Подсказки", hint: "Частота, длина, пауза, контекст, батарея. Инструкции, модель и списки программ остаются.", divider: false) {
                Button("Сбросить") { model.resetAutocompleteTuning() }
            }
            SRow("Перевод", hint: "Пауза двойного ⌘C, удержание модели и тон по программам. Адреса, модель, языки и профили остаются.") {
                Button("Сбросить") { model.resetTranslateTuning() }
            }
        }
    }

    private var aboutCard: some View {
        SCard("О программе", symbol: "info.circle") {
            HStack {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tolk \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    Text(Diagnostics.version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
            }
            HStack {
                SHint("Что-то сломалось? Отчёт с последними событиями (без переводимых текстов) копируется в буфер обмена.")
                Button("Скопировать отчёт") { Diagnostics.copyProblemReport() }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Shared small views

/// «Добавить программу»: running apps.
struct AppMenu: View {
    let title: String
    let isUsed: (String) -> Bool
    let add: (String) -> Void

    var body: some View {
        Menu {
            ForEach(SettingsModel.runningApps(), id: \.id) { app in
                Button(app.name) { add(app.id) }.disabled(isUsed(app.id))
            }
        } label: {
            Label(title, systemImage: "plus")
        }
        .fixedSize()
        .help("Список запущенных сейчас программ. Нужной нет — откройте её и вернитесь сюда.")
    }
}

struct CheckLabel: View {
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
        .fixedSize(horizontal: false, vertical: true)
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
        if m == "qwen-translate" { return "Qwen 35B — чуть быстрее, но хуже на рабочем жаргоне" }
        if m == "gemma-translate" { return "Gemma 26B — основная: точнее термины, живее русский и украинский" }
        if m == "gemma-translate-32k" { return "Gemma 26B, длинный контекст — для больших документов" }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { custom ? "__custom" : selection },
                    set: { v in if v == "__custom" { custom = true } else { custom = false; selection = v } })) {
                    if allowDefault { Text("Как по умолчанию").tag("") }
                    ForEach(models, id: \.self) { m in Text(Self.describe(m)).tag(m) }
                    Divider()
                    Text("Другая…").tag("__custom")
                }
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            if custom || (!selection.isEmpty && !models.contains(selection)) {
                TextField("Имя модели на сервере", text: $selection, prompt: Text("gemma-translate"))
                    .textFieldStyle(.roundedBorder).font(.callout)
            }
        }
    }
}


/// «Запасной перевод: Apple» works only with the language packs downloaded in System Settings. Without this row the
/// user learned about it from a failed translation.
private struct AppleLanguagesRow: View {
    let a: Language, b: Language
    @State private var installed: Bool?
    @State private var checked = false

    var body: some View {
        SRow("Языки Apple: \(a.label) ↔ \(b.label)", hint: hint) {
            HStack(spacing: 8) {
                SPill(text: checked ? (installed == true ? "скачаны" : installed == false ? "не скачаны" : "неизвестно") : "проверяю…",
                      role: installed == true ? .ok : installed == false ? .warn : .neutral)
                if installed != true {
                    Button("Открыть настройки…") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(u) }
                    }
                }
            }
        }
        .task(id: "\(a.rawValue)-\(b.rawValue)") {
            checked = false
            let there = await AppleTranslationProvider.installed(from: a, to: b)
            let back = await AppleTranslationProvider.installed(from: b, to: a)
            installed = (there == nil || back == nil) ? nil : (there == true && back == true)
            checked = true
        }
    }

    private var hint: String {
        installed == true
            ? "Перевод Apple готов к работе без интернета."
            : "Пока языки не скачаны, запасной перевод Apple не работает совсем. Системные настройки → Основные → Язык и регион → Языки перевода: скачайте оба языка, затем вернитесь сюда."
    }
}
