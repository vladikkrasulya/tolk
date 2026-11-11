// Настройки → «Инструкции модели»: every built-in instruction (`PromptCatalog`) can be read, reworded and reset.
import SwiftUI
import TolkCore

/// One instruction block: folded by default, shows whether it is the built-in text or the user's.
struct PromptEditor: View {
    @ObservedObject var model: SettingsModel
    let block: PromptBlock
    var minHeight: CGFloat = 90
    @State private var open = false

    private var custom: Bool { model.config.prompts[block.id] != nil }

    private var text: Binding<String> {
        Binding(
            get: { model.config.prompts[block.id] ?? block.defaultText },
            set: { new in
                let same = new.trimmingCharacters(in: .whitespacesAndNewlines) == block.defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
                model.config.prompts[block.id] = same ? nil : new
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(TolkStyle.hairline).frame(height: 0.5)
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 6) {
                    SHint(block.about)
                    TextEditor(text: text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: minHeight, maxHeight: 260)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(TolkStyle.tile, in: RoundedRectangle(cornerRadius: TolkStyle.controlRadius, style: .continuous))
                    if !block.placeholders.isEmpty {
                        let missing = block.placeholders.filter { !text.wrappedValue.contains("{\($0)}") }
                        SHint("Слова в фигурных скобках подставляются сами: " + block.placeholders.map { "{\($0)}" }.joined(separator: ", ") + ". Не удаляйте их.")
                        if !missing.isEmpty, !text.wrappedValue.isEmpty {
                            Label("В тексте нет " + missing.map { "{\($0)}" }.joined(separator: ", ") + " — модель не узнает язык.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Вернуть стандартный текст") { model.config.prompts[block.id] = nil }.disabled(!custom)
                    }
                }
                .padding(.top, 6).padding(.bottom, 8)
            } label: {
                HStack(spacing: 8) {
                    Text(block.title)
                    Spacer(minLength: 6)
                    if custom { SPill(text: "изменено вами", role: .warn) }
                    else if block.defaultText.isEmpty { SPill(text: "пусто") }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// The cards of the «Инструкции модели» section of the Перевод tab.
struct TranslatePromptCards: View {
    @ObservedObject var model: SettingsModel
    @State private var sample = "Hi! Could you please advise when the payment will be sent? Thanks."
    @State private var sampleTone = Tone.auto

    var body: some View {
        card("Что получает модель перевода", symbol: "text.bubble",
             subtitle: "Запрос собирается из блоков ниже, вашего глоссария и правил профиля (раздел «Глоссарий»), а в конце идёт тон. Написано по-английски: так модель точнее понимает указания. Менять стоит по одному блоку — и смотреть на результат.",
             group: .translate)
        card("Тон", symbol: "theatermasks", subtitle: "Что именно значит каждый из трёх тонов.", group: .tone)
        card("Правка и редактор", symbol: "wand.and.stars", subtitle: "Инструкции для «Причесать» и для «Редактора» — второго взгляда на готовый перевод.", group: .editor)
        card("Правила для отдельных фраз", symbol: "text.magnifyingglass",
             subtitle: "Точечные подсказки модели. Слева шаблон (регулярное выражение), справа после « => » — что ей сказать. Строки без « => » или с неверным шаблоном пропускаются.",
             group: .phrases, minHeight: 160)
        card("Инструменты вокруг перевода", symbol: "wrench.and.screwdriver",
             subtitle: "Сноски, варианты, «Переписать», «Составить» и «Что он имел в виду». В некоторых блоках есть строка с JSON — её менять нельзя: по ней программа разбирает ответ модели.",
             group: .tools, minHeight: 160)
        previewCard
    }

    private func card(_ title: String, symbol: String, subtitle: String, group: PromptBlock.Group, minHeight: CGFloat = 90) -> some View {
        SCard(title, symbol: symbol, subtitle: subtitle) {
            let changed = PromptCatalog.blocks(in: group).filter { model.config.prompts[$0.id] != nil }.count
            if changed > 0 { SPill(text: "изменено: \(changed)", role: .warn) }
        } content: {
            ForEach(PromptCatalog.blocks(in: group)) { PromptEditor(model: model, block: $0, minHeight: minHeight) }
        }
    }

    /// The whole system prompt for a sample text, with the settings as they are now.
    private var previewCard: some View {
        SCard("Проверка: весь запрос целиком", symbol: "eye",
              subtitle: "Впишите текст — ниже появится всё, что модель получит вместе с ним. Так видно, какие блоки и правила для фраз сработали.") {
            TextField("", text: $sample, prompt: Text("Текст для проверки"), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
            HStack {
                Picker("", selection: $sampleTone) {
                    Text("Авто").tag(Tone.auto); Text("Чат").tag(Tone.chat); Text("Письмо").tag(Tone.formal)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                Spacer()
                Text(direction).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            ScrollView {
                Text(preview).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .background(TolkStyle.tile, in: RoundedRectangle(cornerRadius: TolkStyle.controlRadius, style: .continuous))
        }
        .fullSpan()
    }

    private var resolved: ResolvedRequest {
        LanguageDetector.resolve(TranslationRequest(text: sample, tone: sampleTone), config: model.config)
    }
    private var direction: String { "\(UIText.capitalized(resolved.source)) → \(UIText.capitalized(resolved.target))" }

    private var preview: String {
        // The page edits `model.config`; the engine reads `PromptCatalog.overrides` — show what the edits would give.
        let saved = PromptCatalog.overrides
        PromptCatalog.overrides = model.config.prompts
        defer { PromptCatalog.overrides = saved }
        let rules = RulesStore(path: model.config.effectiveRulesPath).promptBlock(for: sample, target: resolved.target)
        return PromptPreview.system(for: resolved, rules: rules)
    }
}
