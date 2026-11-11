// Настройки → Модели: pick, download and delete models without a terminal.
import SwiftUI
import AppKit
import TolkCore

struct ModelsTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var library: ModelLibrary
    @ObservedObject var server: ServerModels

    @State private var link = ""
    @State private var linkError: String?
    @State private var pullName = ""
    @State private var deleteLocal: String?
    @State private var deleteServer: String?

    var body: some View {
        SSections(tab: .models) { section in
            Group {
                if section == 0 {
                    installedCard
                    addCard
                    testedCard.fullSpan()
                } else {
                    serverCard
                }
            }
        }
        .confirmationDialog("Удалить модель «\(deleteLocal ?? "")»?", isPresented: Binding(get: { deleteLocal != nil }, set: { if !$0 { deleteLocal = nil } }), titleVisibility: .visible) {
            Button("Переместить в Корзину", role: .destructive) { if let f = deleteLocal { library.delete(f) }; deleteLocal = nil }
            Button("Отмена", role: .cancel) { deleteLocal = nil }
        } message: {
            Text("Файл попадёт в Корзину — оттуда его можно вернуть. Скачать заново тоже можно в любой момент.")
        }
        .confirmationDialog("Удалить «\(deleteServer ?? "")» с сервера?", isPresented: Binding(get: { deleteServer != nil }, set: { if !$0 { deleteServer = nil } }), titleVisibility: .visible) {
            Button("Удалить с сервера", role: .destructive) { if let n = deleteServer { server.delete(n) }; deleteServer = nil }
            Button("Отмена", role: .cancel) { deleteServer = nil }
        } message: {
            Text("Модель исчезнет с диска сервера. Вернуть можно только повторным скачиванием.")
        }
    }

    private var selectedFile: String { ModelLibrary.fileName(ofConfigPath: model.config.autocompleteModel) }

    // MARK: Local

    /// What is on the disk now: choose or delete.
    private var installedCard: some View {
        SCard("Скачаны на этот Mac", symbol: "internaldrive",
              subtitle: "Модель подсказок работает прямо на Mac. Выберите одну; лишние можно удалить — они переедут в Корзину.") {
            Text("Свободно \(UsageText.bytes(ModelLibrary.freeDiskBytes))").font(.callout).foregroundStyle(.secondary)
        } content: {
            SExample(label: "Ваш Mac", text: MacHardware.summary)
            if !ModelLibrary.llamaServerInstalled {
                warning("Не установлена программа llama-server — без неё модели не запускаются. Откройте Терминал и выполните команду:", command: "brew install llama.cpp")
                    .padding(.top, 8)
            }
            if library.installed.isEmpty {
                SHint("Пока ни одной. Скачайте модель из списка проверенных или добавьте свою.").padding(.top, 8)
            }
            ForEach(library.installed) { m in
                let known = ModelLibrary.catalog.first { $0.file == m.file }
                let selected = m.file == selectedFile
                VStack(alignment: .leading, spacing: 4) {
                    Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 4)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(known?.title ?? ACStats.shortModel(m.file)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        if selected { SPill(text: "используется", symbol: "checkmark", role: .ok) }
                        if known == nil { SPill(text: "ваша") }
                        Spacer(minLength: 8)
                        if !selected {
                            Button("Выбрать") { model.config.autocompleteModel = ModelLibrary.configPath(for: m.file) }
                                .help("Tolk перезапустит модель подсказок — это займёт несколько секунд")
                        }
                        Button(role: .destructive) { deleteLocal = m.file } label: { Image(systemName: "trash") }
                            .disabled(selected)
                            .help(selected ? "Эта модель используется. Сначала выберите другую." : "Удалить файл модели (в Корзину)")
                    }
                    Text("занимает \(UsageText.bytes(m.bytes)) на диске · \(m.file)").font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                .padding(.top, 8)
            }
            if let err = library.lastError { Text(err).font(.callout).foregroundStyle(.red).padding(.top, 6) }
        }
        .onAppear { library.refresh() }
    }

    /// The models measured on the project's test sets — the reference for judging any other model.
    private var testedCard: some View {
        let best = ModelLibrary.recommended()
        return SCard("Проверенные модели", symbol: "checklist",
                     subtitle: "Модели, которые мы замеряли на проверочных наборах (Mac с M1 Max). Это не «лучшие в мире», а точки отсчёта: по ним можно прикинуть, чего ждать от другой модели похожего размера.") {
            ForEach(ModelLibrary.catalog) { m in testedRow(m, best: best.file == m.file) }
            ForEach(library.downloads.keys.sorted().filter { f in !ModelLibrary.catalog.contains { $0.file == f } && !library.isInstalled(f) }, id: \.self) { f in
                VStack(alignment: .leading, spacing: 5) {
                    Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 4)
                    HStack {
                        Text(ACStats.shortModel(f)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        SPill(text: "по вашей ссылке")
                        Spacer()
                        localButtons(file: f, installed: false, selected: false, state: library.downloads[f], catalog: nil)
                    }
                    if let st = library.downloads[f] { downloadState(st) }
                }
                .padding(.top, 8)
            }
        }
    }

    private func testedRow(_ m: CatalogModel, best: Bool) -> some View {
        let installed = library.isInstalled(m.file)
        let selected = installed && m.file == selectedFile
        let fit = MacHardware.fit(modelGB: m.memoryGB)
        return VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 2)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.title).fontWeight(.medium)
                if best { SPill(text: "лучшая для этого Mac", symbol: "star", role: .accent) }
                if selected { SPill(text: "используется", symbol: "checkmark", role: .ok) }
                else if installed { SPill(text: "скачана") }
                Spacer(minLength: 8)
                if installed, !selected {
                    Button("Выбрать") { model.config.autocompleteModel = ModelLibrary.configPath(for: m.file) }
                } else if !installed {
                    localButtons(file: m.file, installed: false, selected: false, state: library.downloads[m.file], catalog: m)
                }
            }
            Text(m.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            STileGrid(minTile: 150) {
                STile(caption: "Одна подсказка", value: m.speed, note: "чем меньше, тем живее")
                STile(caption: "Окончания слов", value: m.endings, note: "верных на наборе")
                STile(caption: "Продолжения", value: m.continuations, note: "показано на наборе")
                STile(caption: "Память", value: String(format: "%.1f ГБ", m.memoryGB).replacingOccurrences(of: ".", with: ","), note: fit.text)
            }
            Text(installed ? "файл \(UsageText.bytes(m.bytes)), уже на диске" : "скачается \(UsageText.bytes(m.bytes))")
                .font(.caption).foregroundStyle(.tertiary)
            if let st = library.downloads[m.file] { downloadState(st) }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func downloadState(_ state: DownloadState) -> some View {
        if let err = state.error {
            Label(err, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else {
            SProgress(fraction: state.fraction, caption: downloadCaption(state))
        }
    }

    private func warning(_ text: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            HStack {
                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(TolkStyle.tile, in: RoundedRectangle(cornerRadius: 6))
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func localButtons(file: String, installed: Bool, selected: Bool, state: DownloadState?, catalog: CatalogModel?) -> some View {
        if let state {
            if state.error != nil {
                if state.canResume { Button("Продолжить") { library.resume(file) } }
                else if let catalog { Button("Повторить") { library.dismissError(file); library.download(catalog) } }
                Button("Скрыть") { library.dismissError(file) }
            } else {
                Button("Отмена") { library.cancel(file) }
            }
        } else if installed {
            if !selected {
                Button("Выбрать") { model.config.autocompleteModel = ModelLibrary.configPath(for: file) }
                    .help("Tolk перезапустит модель подсказок — это займёт несколько секунд")
            }
            Button(role: .destructive) { deleteLocal = file } label: { Image(systemName: "trash") }
                .disabled(selected)
                .help(selected ? "Эта модель используется. Сначала выберите другую." : "Удалить файл модели (в Корзину)")
        } else if let catalog {
            Button("Скачать \(UsageText.bytes(catalog.bytes))") { library.download(catalog) }
        }
    }

    private func downloadCaption(_ s: DownloadState) -> String {
        var parts = [s.total > 0 ? "\(UsageText.bytes(s.received)) из \(UsageText.bytes(s.total))" : UsageText.bytes(s.received)]
        if s.bytesPerSecond > 0 {
            parts.append(UsageText.bytes(Int64(s.bytesPerSecond)) + "/с")
            if s.total > s.received {
                let left = Double(s.total - s.received) / s.bytesPerSecond
                parts.append(left < 90 ? "осталось меньше 2 минут" : "осталось около \(Int((left / 60).rounded())) мин")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Add

    private var addCard: some View {
        let roomy = max(2, Int(MacHardware.comfortableFileGB()))
        return SCard("Другая модель", symbol: "plus.circle",
              subtitle: "Подойдёт любая модель в формате GGUF. Проверенные модели выше — мерка, по которой её можно оценить заранее.") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Как прикинуть для своего Mac").font(.callout).fontWeight(.medium)
                rule("Память", "модели нужно примерно столько же памяти, сколько весит её файл, плюс 0,3–0,5 ГБ. На вашем Mac (\(Int(MacHardware.memoryGB.rounded())) ГБ) без тесноты поместится файл до \(roomy) ГБ.")
                rule("Скорость", "время растёт вместе с размером: файл 1,3 ГБ даёт подсказку за 0,1 с, 3,4 ГБ — за 0,15 с, 5,3 ГБ — за 0,2 с. Дольше 0,3 с подсказка приходит уже после того, как вы продолжили печатать. На Mac новее и мощнее M1 Max будет быстрее, на слабее — медленнее.")
                rule("Качество", "размер ничего не гарантирует: E4B крупнее E2B и проиграла ей, а маленькие Qwen 2B быстрее, но слабее в русском. Смотрите на замеры, а не на число в названии.")
                rule("Проверка", "поставьте модель, попользуйтесь день и сравните долю принятых подсказок во вкладке «Статистика» — там есть разбивка по моделям.")
            }
            .padding(.bottom, 10)
            SRow("По ссылке", hint: "Прямая ссылка на файл .gguf, например со страницы модели на huggingface.co (вкладка Files → нужный файл → Copy download link).", divider: false) {
                HStack {
                    TextField("", text: $link, prompt: Text("https://huggingface.co/…/model.gguf")).textFieldStyle(.roundedBorder).frame(minWidth: 180, maxWidth: 300)
                    Button("Скачать") {
                        linkError = library.download(link: link)
                        if linkError == nil { link = "" }
                    }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let linkError { Text(linkError).font(.callout).foregroundStyle(.red).padding(.bottom, 6) }
            SRow("Из файла", hint: "Файл .gguf, который уже лежит на этом Mac, копируется в папку моделей.") {
                HStack {
                    Button("Выбрать файл…") {
                        if let f = library.importFile() { model.config.autocompleteModel = ModelLibrary.configPath(for: f) }
                    }
                    Button("Открыть папку") { library.revealFolder() }
                }
            }
        }
    }

    private func rule(_ name: String, _ text: String) -> some View {
        (Text(name + ": ").fontWeight(.medium) + Text(text)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Server

    private var serverCard: some View {
        SCard("Модели на сервере", symbol: "server.rack",
              subtitle: "Переводит большая модель на домашнем сервере (Ollama). Здесь видно, что на нём лежит; модель для перевода выбирается из готовых («…-translate»).") {
            Button { model.configureServer(); server.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Обновить список")
        } content: {
            if server.reachable == false {
                Label("Сервер не отвечает. Проверьте адрес во вкладке «Перевод».", systemImage: "xmark.circle").foregroundStyle(.red).font(.callout)
            } else if server.models.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Читаю список моделей…").font(.callout).foregroundStyle(.secondary) }
            }
            ForEach(server.models) { m in serverRow(m) }
            ForEach(server.pulls.keys.sorted(), id: \.self) { name in
                VStack(alignment: .leading, spacing: 5) {
                    Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 4)
                    HStack {
                        Text(name).fontWeight(.medium)
                        Spacer()
                        Button("Отмена") { server.cancelPull(name) }
                    }
                    let s = server.pulls[name] ?? PullState()
                    SProgress(fraction: s.fraction, caption: s.total > 0 ? "\(s.status) \(UsageText.bytes(s.completed)) из \(UsageText.bytes(s.total))" : s.status)
                }
                .padding(.bottom, 8)
            }
            if let msg = server.message {
                Label(msg, systemImage: server.failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(server.failed ? .red : .secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
            }
            Rectangle().fill(TolkStyle.hairline).frame(height: 0.5)
            Text("Скачать на сервер ещё одну").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            ForEach(ServerModels.suggestions.filter { s in !server.models.contains { $0.name == s.name } }, id: \.name) { s in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).fontWeight(.medium)
                        Text(s.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Скачать") { startPull(s.name) }.disabled(server.pulls[s.name] != nil)
                }
                .padding(.top, 6)
            }
            SRow("Другая модель", hint: "Имя из библиотеки ollama.com, например gemma4:26b. После скачивания Tolk сам подготовит её для перевода и предложит выбрать. Нужна модель не меньше 12B — мелкие переводят заметно хуже.", divider: false) {
                HStack {
                    TextField("", text: $pullName, prompt: Text("имя:размер")).textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 200)
                    Button("Скачать") { startPull(pullName); pullName = "" }
                        .disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.top, 8)
        }
        .onAppear { model.configureServer(); server.refresh() }
    }

    private func startPull(_ name: String) {
        model.configureServer()
        server.pull(name) { ready in
            // The new translation model appears in the pickers right away.
            if !model.availableModels.contains(ready) { model.availableModels.append(ready) }
        }
    }

    private func inUse(_ name: String) -> Bool {
        name == model.config.model || model.config.profiles.contains { $0.model == name }
    }

    private func serverRow(_ m: ServerModel) -> some View {
        let used = inUse(m.name)
        // A translation model built from this base shares its weights: same size, same parameters.
        let hasTwin = server.models.contains { $0.isTranslate && $0.bytes == m.bytes && $0.parameters == m.parameters }
        return VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if used { SPill(text: "переводит", symbol: "checkmark", role: .ok) }
                else if m.isTranslate { SPill(text: "готова для перевода") }
                else { SPill(text: "основа") }
                Spacer(minLength: 8)
                if server.busy.contains(m.name) {
                    ProgressView().controlSize(.small)
                } else {
                    if m.isTranslate, !used {
                        Button("Выбрать") { model.config.model = m.name }.help("Сделать моделью перевода по умолчанию")
                    }
                    if !m.isTranslate, !hasTwin {
                        Button("Подготовить") { Task { await server.prepare(base: m.name) } }
                            .help("Создать на сервере «\(ServerModels.translateName(forBase: m.name))»: эта модель с инструкцией переводчика")
                    }
                    Button(role: .destructive) { deleteServer = m.name } label: { Image(systemName: "trash") }
                        .disabled(used)
                        .help(used ? "Эта модель используется для перевода. Сначала выберите другую." : "Удалить с сервера")
                }
            }
            Text(serverNote(m)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }

    private func serverNote(_ m: ServerModel) -> String {
        var parts: [String] = []
        if m.isTranslate {
            let d = ModelPicker.describe(m.name)
            if d != m.name { parts.append(d) }
        } else {
            parts.append("Исходная модель, из неё собрана модель перевода. Места почти не занимает: общие файлы сервер хранит один раз.")
        }
        parts.append([UsageText.bytes(m.bytes), m.parameters, m.quantization].filter { !$0.isEmpty }.joined(separator: " · "))
        return parts.joined(separator: "\n")
    }
}
