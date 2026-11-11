// Настройки → Автодополнение. Every control says what changes when it is switched, with an example.
import SwiftUI
import TolkCore

struct AutocompleteTab: View {
    @ObservedObject var model: SettingsModel

    /// Ready-made instructions (a click adds the line).
    static let instructionChips = [
        "Пиши коротко, без воды", "Обращайся на «Вы»", "Обращайся на «ты»", "Без эмодзи", "Деловой тон",
        "Без точки в конце сообщения", "Не используй англицизмы",
    ]
    static let appChips = ["Коротко и неформально", "Вежливо, на «Вы»", "Без эмодзи", "Пиши по-английски"]

    var body: some View {
        mainCard
        frequencyCard
        instructionsCard
        contextCard
        typingCard
        typeTranslateCard
        styleCard
        batteryCard
        offAppsCard
    }

    private var cfg: Binding<TolkConfig> { $model.config }

    // MARK: Основное

    private var mainCard: some View {
        SCard("Автодополнение", symbol: "text.cursor") {
            SToggle("Подсказывать продолжение", isOn: cfg.autocomplete,
                    hint: "Серый текст у курсора в любой программе. Tab принимает одно слово, → всю подсказку, Esc прячет её. Модель работает на этом Mac — текст никуда не уходит.",
                    offHint: "Выключено: модель подсказок не запущена и память не занимает. Исправление опечаток и эмодзи ниже работают сами по себе.",
                    example: SExample(text: "Давай созвонимся ", ghost: "завтра утром"), divider: false)
            if model.config.autocomplete, let err = model.acError {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Модель не работает: \(err)").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Повторить") { model.onRetryAutocomplete?() }
                }
                .padding(.bottom, 8)
            }
            SRow("Модель", hint: "Скачать другую, выбрать или удалить — во вкладке «Модели».") {
                HStack(spacing: 8) {
                    Text(ACStats.shortModel(ModelLibrary.fileName(ofConfigPath: model.config.autocompleteModel)))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Модели…") { model.tab = .models }
                }
            }
        }
    }

    // MARK: Частота и длина

    private var frequencyCard: some View {
        SCard("Как часто и как длинно", symbol: "slider.horizontal.3") {
            SChoice(title: "Частота подсказок", selection: cfg.autocompleteFrequency, options: [
                .init(value: "rare", title: "Реже", effect: "Подсказка появляется, только когда модель уверена: примерно 2 из 3 верные, но часто у курсора пусто. Показ после паузы в этом режиме не работает."),
                .init(value: "normal", title: "Обычно", effect: "Середина: подсказок заметно больше, верных около 60 %."),
                .init(value: "often", title: "Чаще", effect: "Подсказка есть почти всегда, но примерно каждая вторая мимо — её просто не принимают и печатают дальше."),
            ], divider: false)
            SToggle("Показывать после паузы", isOn: cfg.autocompletePatient,
                    hint: "Остановились посреди фразы, а подсказки нет — Tolk подождёт и покажет вариант, в котором модель сомневалась. На замерах все такие продолжения были осмысленными.",
                    offHint: "Выключено: если модель не уверена сразу, у курсора останется пусто, сколько бы вы ни ждали.",
                    example: SExample(text: "Давай завтра, если ", ghost: "будет время."))
            if model.config.autocompletePatient {
                SSlider(title: "Сколько ждать", value: cfg.autocompletePatientDelay, range: 0.3...2.0, step: 0.05,
                        format: { String(format: "%.2f с", $0).replacingOccurrences(of: ".", with: ",") },
                        hint: model.config.autocompletePatientDelay < 0.5
                            ? "Почти сразу: подсказка будет мелькать и во время обычных коротких остановок."
                            : (model.config.autocompletePatientDelay > 1.2 ? "Долго: подсказка появится, только если вы действительно задумались." : "Стандартно 0,65 с: обычная заминка при наборе."))
            }
            SChoice(title: "Длина подсказки", selection: cfg.autocompleteLength, options: [
                .init(value: "short", title: "Короткая", effect: "До 3 слов. Считается быстрее всего и реже ошибается."),
                .init(value: "medium", title: "Средняя", effect: "До 6 слов. Обычный выбор."),
                .init(value: "long", title: "Длинная", effect: "До 12 слов. Модель считает дольше, а хвост длинной подсказки чаще неточен — принимайте по слову (Tab)."),
            ], example: { v in
                SExample(text: "Давай созвонимся ", ghost: v == "short" ? "завтра утром" : (v == "long" ? "завтра утром и обсудим детали по новому проекту, если тебе удобно" : "завтра утром и обсудим детали"))
            })
        }
    }

    // MARK: Инструкции

    private var instructionsCard: some View {
        SCard("Инструкции", symbol: "pencil.and.list.clipboard",
              subtitle: "Пожелания к подсказкам обычными словами, по одному в строке. Пусто — модель просто продолжает ваш текст в вашем стиле.") {
            Text("Для всех программ").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: cfg.autocompleteInstructions)
                .font(.body).frame(minHeight: 58, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(TolkStyle.tile, in: RoundedRectangle(cornerRadius: TolkStyle.controlRadius, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if model.config.autocompleteInstructions.isEmpty {
                        Text("Например: пиши коротко, без эмодзи").foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                    }
                }
            SChips(items: Self.instructionChips, isUsed: { model.config.autocompleteInstructions.localizedCaseInsensitiveContains($0) }) { add($0) }
                .padding(.top, 6)
            SHint("Нажмите на вариант, чтобы добавить его. Маленькая модель слушается простых указаний (коротко, на «Вы», без эмодзи) и плохо — сложных.")
                .padding(.top, 4).padding(.bottom, 10)

            Rectangle().fill(TolkStyle.hairline).frame(height: 0.5)
            HStack {
                Text("Отдельно для программы").font(.callout).foregroundStyle(.secondary)
                Spacer()
                AppMenu(title: "Добавить программу", isUsed: { model.config.autocompleteAppInstructions[$0] != nil }) { model.addAppInstruction($0) }
            }
            .padding(.top, 8)
            if model.config.autocompleteAppInstructions.isEmpty {
                SHint("Пока нет. Например, для Slack — «коротко и неформально», для Почты — «вежливо, на Вы». Добавляются к общим.")
                    .padding(.top, 4)
            }
            ForEach(model.config.autocompleteAppInstructions.keys.sorted(), id: \.self) { id in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(SettingsModel.appName(id)).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Button(role: .destructive) { model.config.autocompleteAppInstructions[id] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Убрать инструкции для этой программы")
                    }
                    TextField("", text: Binding(
                        get: { model.config.autocompleteAppInstructions[id] ?? "" },
                        set: { model.config.autocompleteAppInstructions[id] = $0 }),
                              prompt: Text("Например: коротко и неформально"), axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    SChips(items: Self.appChips, isUsed: { (model.config.autocompleteAppInstructions[id] ?? "").localizedCaseInsensitiveContains($0) }) { chip in
                        let cur = (model.config.autocompleteAppInstructions[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        model.config.autocompleteAppInstructions[id] = cur.isEmpty ? chip : cur + ". " + chip
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func add(_ chip: String) {
        let cur = model.config.autocompleteInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        model.config.autocompleteInstructions = cur.isEmpty ? chip : cur + "\n" + chip
    }

    // MARK: Контекст

    private var contextCard: some View {
        SCard("Что учитывать", symbol: "eye", subtitle: "Чем больше модель знает о разговоре, тем точнее продолжение.") {
            SToggle("Глоссарий и тон", isOn: cfg.autocompleteUseGlossary,
                    hint: "Подсказки берут термины активного профиля глоссария и тон программы из вкладки «Перевод».",
                    offHint: "Выключено: подсказки не знают ваших терминов и пишут одним тоном во всех программах.", divider: false)
            SToggle("Буфер обмена", isOn: cfg.autocompleteClipboard,
                    hint: "Короткий текст, скопированный за последние две минуты, попадает в подсказку — удобно отвечать на скопированный вопрос. Пароли и ключи отбрасываются.",
                    offHint: "Выключено: буфер обмена не читается вообще.")
            SToggle("Текст окна со снимка экрана", isOn: cfg.autocompleteScreenContext,
                    hint: "Slack, Telegram и Teams не отдают переписку напрямую — Tolk читает её со снимка окна. Нужно разрешение «Запись экрана»; снимок не покидает Mac.",
                    offHint: "Выключено: в таких программах модель видит только то, что вы печатаете, и отвечает общими словами.")
            SToggle("Плашка у курсора в браузере", isOn: cfg.autocompleteCaretBubble,
                    hint: "Поля на сайтах часто не сообщают, где курсор. Tolk находит набранный текст на снимке поля и ставит подсказку рядом. Работает вместе со снимками экрана.",
                    offHint: "Выключено: в таких полях подсказка появляется плашкой в левом нижнем углу поля.")
        }
    }

    // MARK: Помощь при наборе

    private var typingCard: some View {
        SCard("Помощь при наборе", symbol: "keyboard", subtitle: "Работает без модели, даже когда автодополнение выключено.") {
            SToggle("Исправлять опечатки", isOn: cfg.autocorrect,
                    hint: "Опечатка в последнем слове показывается серым исправлением, Tab применяет его.",
                    offHint: "Выключено: опечатки остаются как набраны.",
                    example: SExample(text: "превет → ", ghost: "привет"), divider: false)
            SToggle("Эмодзи по названию", isOn: cfg.autocompleteEmoji,
                    hint: "Двоеточие и слово — по-русски или по-английски — и Tab вставит эмодзи.",
                    offHint: "Выключено: «:fire» остаётся текстом.",
                    example: SExample(text: ":fire → 🔥   :спасибо → 🙏"))
        }
    }

    private var typeTranslateCard: some View {
        let names = model.config.typeTranslateApps.filter(\.value).keys.sorted().map { SettingsModel.appName($0) }
        return SCard("Перевод при наборе", symbol: "arrow.left.arrow.right",
                     subtitle: "Пишете по-русски — под полем появляется перевод на язык собеседника. Tab заменяет ваш текст переводом, Esc оставляет как есть. Tolk сам ничего не отправляет.") {
            SToggle("Включать самому", isOn: cfg.typeTranslateAuto,
                    hint: "Если последнее сообщение собеседника на другом языке, режим включится в этой программе без вашего участия.",
                    offHint: "Выключено: режим включается только вручную — горячей клавишей (⌃⌥R, меняется во вкладке «Общие») или из меню Tolk.", divider: false)
            if !names.isEmpty {
                SRow("Сейчас включено", hint: names.joined(separator: ", ")) {
                    Button("Выключить везде") { model.config.typeTranslateApps = [:] }
                }
            }
        }
    }

    // MARK: Стиль

    private var styleCard: some View {
        SCard("Ваш стиль", symbol: "person.text.rectangle") {
            SToggle("Учиться на моих сообщениях", isOn: cfg.autocompleteLearnStyle,
                    hint: "Tolk запоминает сообщения, в которых вы приняли подсказку, и показывает модели похожие как образец. Хранится зашифрованно и только на этом Mac.",
                    offHint: "Выключено: подсказки не подстраиваются под вашу манеру, «Выбор слов» тоже не действует.", divider: false)
            SToggle("Запоминать все отправленные", isOn: cfg.autocompleteRecordAll,
                    hint: "В память попадает каждое отправленное сообщение: стиль выучивается быстрее, но хранится больше вашей переписки.",
                    offHint: "Запоминаются только сообщения, где вы приняли подсказку.")
            SChoice(title: "Выбор слов", selection: cfg.autocompleteWordPreference, options: [
                .init(value: "off", title: "Выкл.", effect: "Модель выбирает слова сама."),
                .init(value: "medium", title: "Средний", effect: "Модель чуть охотнее предлагает слова, которые вы часто пишете."),
                .init(value: "strong", title: "Сильный", effect: "Ваши частые слова предлагаются настойчиво — иногда не к месту."),
            ])
            SRow("Стереть выученное", hint: "Удаляет все сохранённые примеры. Отменить нельзя.") {
                Button("Удалить…", role: .destructive) { model.confirmDeleteLearned() }
            }
        }
    }

    private var batteryCard: some View {
        SCard("На батарее", symbol: "battery.50", subtitle: "Действует, пока Mac не подключён к питанию: меньше нагрузка, тише вентилятор, дольше заряд.") {
            SToggle("Подсказывать реже", isOn: cfg.autocompleteBatteryRare, hint: "Как режим «Реже»: только уверенные подсказки.", divider: false)
            SToggle("Без снимков экрана", isOn: cfg.autocompleteBatteryNoScreen, hint: "Не распознавать текст окна: в Slack и Telegram подсказки станут менее точными.")
            SToggle("Короткие подсказки", isOn: cfg.autocompleteBatteryShort, hint: "До 3 слов — модель считает меньше.")
        }
    }

    private var offAppsCard: some View {
        SCard("Где не подсказывать", symbol: "nosign", subtitle: "В этих программах автодополнение молчит — например, в терминалах и редакторах кода. Быстро выключить в текущей программе можно из меню Tolk.") {
            if model.config.autocompleteOffApps.isEmpty { SHint("Список пуст: подсказки работают везде.") }
            ForEach(model.config.autocompleteOffApps, id: \.self) { id in
                HStack {
                    Text(SettingsModel.appName(id)).lineLimit(1)
                    Spacer()
                    Button(role: .destructive) { model.config.autocompleteOffApps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Снова подсказывать в этой программе")
                }
                .padding(.vertical, 2)
            }
            AppMenu(title: "Добавить программу", isUsed: { model.config.autocompleteOffApps.contains($0) }) { model.addOffApp($0) }
                .padding(.top, 6)
        }
    }
}
