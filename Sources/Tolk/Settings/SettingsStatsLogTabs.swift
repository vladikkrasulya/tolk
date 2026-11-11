// Настройки → Статистика and Журнал.
import SwiftUI
import AppKit
import TolkCore

// MARK: - Статистика

struct StatsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmReset = false

    private var period: Int? { model.statsPeriod }
    private var usage: UsageDay { model.usage.total(last: period) }
    private var ac: ACBucket { model.acStats.summary(last: period).total }

    var body: some View {
        periodCard.fullSpan()
        SSections(tab: .stats) { section in
            switch section {
            case 0:
                translateCard
                translateChartCard
                originsCard
            case 1:
                suggestCard
                suggestChartCard
                missesCard
                placesCard
                suggestTablesCard
            default:
                privacyCard
            }
        }
    }

    private func pct(_ part: Int, _ whole: Int) -> String { whole > 0 ? "\(Int((Double(part) / Double(whole) * 100).rounded())) %" : "—" }

    private var periodCard: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.statsPeriod) {
                Text("Сегодня").tag(Int?.some(1))
                Text("7 дней").tag(Int?.some(7))
                Text("30 дней").tag(Int?.some(30))
                Text("Всё время").tag(Int?.none)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Text(headline).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
        }
    }

    /// One sentence that says the main thing about the period.
    private var headline: String {
        let u = usage, a = ac
        if u.translations == 0, a.shown + a.instantShown == 0 { return "За этот период Tolk не использовался." }
        var parts: [String] = []
        if u.translations > 0 { parts.append("переведено \(UsageText.count(u.translations)) раз") }
        if a.acceptedEvents > 0 {
            let seconds = Double(a.savedKeystrokes) / 4.5
            parts.append("подсказки сберегли \(UsageText.count(a.savedKeystrokes)) нажатий" + (seconds >= 60 ? " (около \(Int((seconds / 60).rounded())) мин набора)" : ""))
        }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
    }

    // MARK: Translation

    private var translateCard: some View {
        let u = usage
        return SCard("Перевод", symbol: "character.bubble") {
            if u.translations == 0, u.failed == 0 {
                SHint("Переводов за этот период нет.")
            } else {
                STileGrid {
                    STile(caption: "Переводов", value: UsageText.count(u.translations), note: "\(UsageText.count(u.chars)) знаков исходного текста")
                    STile(caption: "Обычное время", value: UsageText.ms(u.medianLatency), note: u.medianFirstChunk.map { "первые слова через \(UsageText.ms($0))" } ?? "от запроса до готового перевода")
                    STile(caption: "Из кэша", value: pct(u.cached, u.translations), note: "повторный текст отдаётся мгновенно")
                    STile(caption: "Запасной перевод", value: pct(u.fallback, u.translations), note: u.fallback == 0 ? "сервер отвечал всегда" : "\(u.fallback) раз сервер был недоступен")
                    STile(caption: "Ошибок", value: "\(u.failed)", note: u.failed == 0 ? "все переводы дошли" : "подробности во вкладке «Журнал»")
                }
                if u.medianLatency == nil {
                    SHint("Время перевода считается с версии 0.8: более ранние переводы взяты из истории без замеров.").padding(.top, 6)
                }
            }
        }
    }

    private var translateChartCard: some View {
        let series = model.usage.series(days: 30)
        return SCard("Переводы по дням", symbol: "calendar", subtitle: "Последние 30 дней.") {
            SDayChart(bars: series.map { .init(id: $0.day, back: $0.value, front: $0.value) })
        }
    }

    private var originsCard: some View {
        let u = usage
        return SCard("Откуда и что переводится", symbol: "arrow.triangle.branch") {
            if u.translations == 0 {
                SHint("Нет данных за этот период.")
            } else {
                shareBlock("Способ", u.byOrigin.map { (UsageText.origin($0.key), $0.value) }, total: u.translations)
                shareBlock("Направление", u.byPair.map { ($0.key.uppercased(), $0.value) }, total: u.translations)
                if !u.byApp.isEmpty { shareBlock("Программа", u.byApp.map { ($0.key, $0.value) }, total: u.translations) }
                if u.byProvider.count > 1 { shareBlock("Кто переводил", u.byProvider.map { ($0.key, $0.value) }, total: u.translations) }
            }
        }
    }

    private func shareBlock(_ title: String, _ rows: [(String, Int)], total: Int, limit: Int = 5) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(Array(rows.sorted { ($0.1, $1.0) > ($1.1, $0.0) }.prefix(limit).enumerated()), id: \.offset) { _, r in
                SShareRow(label: r.0, value: r.1, total: total)
            }
        }
    }

    // MARK: Suggestions

    private var suggestCard: some View {
        let a = ac
        let shown = a.shown + a.instantShown
        return SCard("Подсказки", symbol: "text.cursor") {
            if shown == 0 {
                SHint("Подсказок за этот период не было.")
            } else {
                STileGrid {
                    STile(caption: "Показано", value: UsageText.count(shown), note: a.instantShown > 0 ? "из них \(a.instantShown) — опечатки и эмодзи" : nil)
                    STile(caption: "Принято", value: pct(a.acceptedEvents, shown), note: "\(a.acceptedEvents) раз: Tab \(a.tabEvents + a.instantAccepted), → \(a.allEvents)")
                    STile(caption: "Слов принято", value: UsageText.count(a.acceptedWords), note: nil)
                    STile(caption: "Сбережено нажатий", value: UsageText.count(a.savedKeystrokes), note: "знаки, которые не пришлось печатать")
                    STile(caption: "Обычная задержка", value: a.medianLatency.map { "\($0) мс" } ?? "—", note: "от паузы до подсказки")
                    STile(caption: "Не подошло", value: pct(a.typedOn + a.esc, shown), note: "печатали дальше \(a.typedOn), Esc \(a.esc)")
                }
                SHint(verdict(a, shown: shown)).padding(.top, 8)
            }
        }
    }

    /// What the numbers mean and what to change.
    private func verdict(_ a: ACBucket, shown: Int) -> String {
        let rate = a.acceptRate
        if shown < 30 { return "Данных пока мало — выводы делать рано." }
        if rate >= 0.25 { return "Принимается каждая четвёртая подсказка или больше — хороший результат. Можно попробовать «Чаще», если хочется больше подсказок." }
        if rate >= 0.12 { return "Принимается примерно каждая \(Int((1 / max(rate, 0.01)).rounded()))-я подсказка — обычный уровень для режима «Чаще». Хотите меньше лишнего — поставьте «Обычно»." }
        return "Подсказки принимаются редко. Попробуйте «Реже» (только уверенные) и включите «Учиться на моих сообщениях», чтобы модель писала вашими словами."
    }

    private var suggestChartCard: some View {
        let cal = Calendar.current
        let rows = model.acStats.dayRows(last: nil)
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
        let changes = model.acStats.modelChanges(rows)
        let bars: [SDayChart.Bar] = (0..<30).map { i in
            let day = ACStats.dayKey(cal.date(byAdding: .day, value: i - 29, to: Date()) ?? Date(), calendar: cal)
            let b = by[day]?.bucket
            return .init(id: day, back: (b?.shown ?? 0) + (b?.instantShown ?? 0), front: b?.acceptedEvents ?? 0, mark: changes[day] != nil)
        }
        return SCard("Подсказки по дням", symbol: "calendar") {
            HStack(spacing: 10) {
                SLegend(color: Color.primary.opacity(0.2), text: "показано")
                SLegend(color: .accentColor, text: "принято")
                SLegend(color: .orange, text: "смена модели")
            }
        } content: {
            SDayChart(bars: bars)
            ForEach(bars.filter(\.mark)) { b in
                Text("\(SDayChart.short(b.id)): модель \(ACStats.shortModel(changes[b.id] ?? ""))").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var missesCard: some View {
        let misses = usage.acMisses
        let total = misses.values.reduce(0, +)
        return SCard("Почему подсказки не было", symbol: "questionmark.bubble",
                     subtitle: "Случаи, когда вы остановились, а у курсора осталось пусто.") {
            if total == 0 {
                SHint("Пока нет данных — причины начали считаться с версии 0.8.")
            } else {
                ForEach(misses.sorted { ($0.value, $1.key) > ($1.value, $0.key) }, id: \.key) { key, n in
                    SShareRow(label: UsageText.miss(key), value: n, total: total, note: UsageText.missAdvice(key))
                }
            }
        }
    }

    /// How suggestions behave in every app and site the user types in.
    private var placesCard: some View {
        let reports = PlaceReport.reports(usage)
        return SCard("Где подсказки работают", symbol: "mappin.and.ellipse",
                     subtitle: "По каждой программе, а в браузере — по каждому сайту: как Tolk находит курсор и проходит ли вставка. Места с проблемами видно сразу.") {
            if reports.isEmpty {
                SHint("Пока нет данных — учёт по местам начался с версии 0.9.7.")
            }
            ForEach(Array(reports.prefix(12).enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 3) {
                    Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 4)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(placeName(r)).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        placePill(r.verdict)
                    }
                    Text(r.verdictText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("показано \(r.shown): у курсора \(r.exact), по снимку \(r.ocr), под полем \(r.under) · принято \(r.accepted)" + (r.notInserted > 0 ? " · не вставилось \(r.notInserted)" : ""))
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func placeName(_ r: PlaceReport) -> String {
        let app = r.bundleID == "?" ? "не определена" : SettingsModel.appName(r.bundleID)
        return r.host.map { app + " — " + $0 } ?? app
    }

    private func placePill(_ v: PlaceReport.Verdict) -> some View {
        switch v {
        case .good: SPill(text: "хорошо", symbol: "checkmark", role: .ok)
        case .snapshot: SPill(text: "по снимку", symbol: "camera.viewfinder", role: .accent)
        case .under: SPill(text: "под полем", symbol: "arrow.down.to.line", role: .warn)
        case .insertTrouble: SPill(text: "сбои вставки", symbol: "exclamationmark.triangle", role: .bad)
        case .fewData: SPill(text: "мало данных")
        }
    }

    private var suggestTablesCard: some View {
        SCard("По моделям и программам", symbol: "tablecells") {
            table("Модель", model.acStats.byModel(last: period).map { (ACStats.shortModel($0.name), $0.bucket) })
            table("Программа", model.acStats.byApp(last: period).prefix(6).map { ($0.name == ACStats.unknownApp ? "не определена" : SettingsModel.appName($0.name), $0.bucket) })
                .padding(.top, 10)
            if model.acStats.days.values.contains(where: { $0.values.contains { $0.values.contains { $0.approx } } }) {
                SHint("Часть старых дней восстановлена из журнала приблизительно.").padding(.top, 6)
            }
        }
    }

    private func table(_ title: String, _ rows: [(String, ACBucket)]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text(title).gridColumnAlignment(.leading)
                Text("Показано"); Text("Принято"); Text("%")
            }
            .font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                GridRow { Text("нет данных").foregroundStyle(.secondary).gridColumnAlignment(.leading); Text(""); Text(""); Text("") }.font(.callout)
            }
            ForEach(0..<rows.count, id: \.self) { i in
                let b = rows[i].1
                GridRow {
                    Text(rows[i].0).lineLimit(1).truncationMode(.middle).gridColumnAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(b.shown + b.instantShown)"); Text("\(b.acceptedEvents)")
                    Text(pct(b.acceptedEvents, b.shown + b.instantShown))
                }
                .font(.callout.monospacedDigit())
            }
        }
    }

    private var privacyCard: some View {
        SCard("Что хранится", symbol: "lock") {
            SHint("Только числа, названия программ и моделей — без единого слова текста. Срок хранения — год, всё лежит на этом Mac.")
            Button("Сбросить статистику…", role: .destructive) { confirmReset = true }
                .padding(.top, 8)
                .confirmationDialog("Сбросить всю статистику?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Сбросить", role: .destructive) { model.resetStats() }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text("Счётчики перевода и подсказок обнулятся. Это нельзя отменить.")
                }
        }
    }
}

// MARK: - Журнал

struct LogTab: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmClear = false

    var body: some View {
        SSections(tab: .log) { section in
            switch section {
            case 0:
                viewerCard.fullSpan()
            case 1:
                summaryCard
                settingsCard
            default:
                guideCard.fullSpan()
            }
        }
    }

    private var viewerCard: some View {
        let lines = model.shownLogLines
        return SCard("Журнал событий", symbol: "list.bullet.rectangle",
                     subtitle: "Нажмите на строку — под списком появится объяснение по-человечески. Красные строки — проблемы, оранжевые — «к сведению».") {
            Text("\(lines.count) строк").font(.callout).foregroundStyle(.secondary).monospacedDigit()
        } content: {
            HStack(spacing: 8) {
                Picker("", selection: $model.logFilter) {
                    ForEach(LogFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("", text: $model.logSearch, prompt: Text("Найти в журнале")).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Button { model.refreshLog(force: true) } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                .help("Скопировать показанные строки")
            }
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            LogLine(line: line, selected: model.logSelected == line)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { model.logSelected = model.logSelected == line ? nil : line }
                        }
                        if lines.isEmpty {
                            Text(model.logLines.isEmpty ? "Журнал пуст." : "По этому фильтру ничего нет.").font(.callout).foregroundStyle(.secondary).padding(8)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 240, idealHeight: 340, maxHeight: 420)
                .background(TolkStyle.tile, in: RoundedRectangle(cornerRadius: TolkStyle.controlRadius, style: .continuous))
                .onAppear { model.refreshLog(force: true); proxy.scrollTo(max(0, lines.count - 1), anchor: .bottom) }
                .onChange(of: lines.count) { _, n in proxy.scrollTo(max(0, n - 1), anchor: .bottom) }
            }
            explanation.padding(.top, 8)
        }
    }

    /// What the clicked line means.
    @ViewBuilder private var explanation: some View {
        if let line = model.logSelected {
            if let e = LogGuide.explain(line) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(e.title).fontWeight(.medium)
                        kindPill(e.kind)
                        SPill(text: e.group.title)
                    }
                    Text(e.meaning).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let a = e.action {
                        (Text("Что делать: ").fontWeight(.medium) + Text(a)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(TolkStyle.tile, in: RoundedRectangle(cornerRadius: TolkStyle.controlRadius, style: .continuous))
            } else {
                SHint("Для этой строки объяснения в справочнике нет — это редкое техническое событие.")
            }
        } else {
            SHint("Нажмите на любую строку, чтобы увидеть, что она значит.")
        }
    }

    private func kindPill(_ k: LogGuide.Kind) -> some View {
        switch k {
        case .problem: SPill(text: "проблема", symbol: "exclamationmark.triangle", role: .bad)
        case .note: SPill(text: "к сведению", symbol: "info.circle", role: .warn)
        case .normal: SPill(text: "обычное", symbol: "checkmark", role: .ok)
        }
    }

    /// Problems and notes found in the loaded lines, by kind of event.
    private var summaryCard: some View {
        let items = LogGuide.summary(model.logLines)
        return SCard("Что происходило", symbol: "exclamationmark.bubble",
                     subtitle: "Проблемы и события «к сведению» в последних \(model.logLines.count) строках журнала, от частых к редким.") {
            if items.isEmpty {
                SHint("Ничего примечательного: только обычная работа.")
            }
            ForEach(Array(items.prefix(12).enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 3) {
                    Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 4)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(it.entry.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Text("\(it.count)×").monospacedDigit().foregroundStyle(.secondary)
                        kindPill(it.entry.kind)
                    }
                    Text(it.entry.meaning).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let a = it.entry.action {
                        (Text("Что делать: ").fontWeight(.medium) + Text(a)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear { model.refreshLog(force: true) }
    }

    /// The whole guide, by group.
    private var guideCard: some View {
        SCard("Справочник по строкам журнала", symbol: "text.book.closed",
              subtitle: "Все виды событий по группам. Тот же текст лежит файлом рядом с журналом — его можно открыть и читать отдельно.") {
            Button("Открыть файлом") { Diagnostics.writeGuide(); NSWorkspace.shared.open(Diagnostics.guideURL) }
        } content: {
            ForEach(LogGuide.Group.allCases, id: \.rawValue) { g in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(g.about).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(LogGuide.entries.filter { $0.group == g }.enumerated()), id: \.offset) { _, e in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) { Text(e.title).fontWeight(.medium); kindPill(e.kind) }
                                Text(e.sample).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                Text(e.meaning).font(.callout).fixedSize(horizontal: false, vertical: true)
                                if let a = e.action {
                                    (Text("Что делать: ").fontWeight(.medium) + Text(a)).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(.top, 6).padding(.bottom, 8)
                } label: {
                    HStack(spacing: 8) {
                        Text(g.title).fontWeight(.medium)
                        let n = LogGuide.entries.filter { $0.group == g && $0.kind == .problem }.count
                        Text("\(LogGuide.entries.filter { $0.group == g }.count) событий" + (n > 0 ? ", из них проблем \(n)" : "")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var settingsCard: some View {
        SCard("Запись и файлы", symbol: "doc.text.magnifyingglass") {
            SToggle("Подробный журнал", isOn: $model.config.verboseLog,
                    hint: "Пишется каждое решение подсказок и каждый запрос к модели: журнал растёт на мегабайты в час. Включайте, когда ловите проблему, потом выключайте.",
                    offHint: "Пишутся только события, по которым можно понять, что произошло: переводы, показанные и принятые подсказки, ошибки. Хватает на недели.",
                    divider: false)
            SRow("Отчёт о проблеме", hint: "Версия, последние 60 событий и текст ошибки — готовый текст, чтобы отправить разработчику.") {
                Button("Скопировать отчёт") { Diagnostics.copyProblemReport() }
            }
            SRow("Файлы журнала", hint: "Папка ~/Library/Logs/Tolk, сейчас \(UsageText.bytes(Diagnostics.logFolderSize())). Основной файл сам обновляется после 1 МБ, прошлый хранится рядом.") {
                HStack {
                    Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL]) }
                    Button("Очистить…", role: .destructive) { confirmClear = true }
                }
            }
            .confirmationDialog("Очистить журнал?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Очистить", role: .destructive) { model.clearLog() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("События будут стёрты. Записи о сбоях программы останутся.")
            }
        }
    }
}

private struct LogLine: View {
    let line: String
    var selected = false

    var body: some View {
        // "2026-11-11 12:14:01 message" or the old "2026-11-11T11:14:01Z message".
        let cut = line.firstIndex(of: " ").flatMap { i -> String.Index? in
            let rest = line[line.index(after: i)...]
            if line[..<i].contains("T") { return line.index(after: i) }
            return rest.firstIndex(of: " ").map { line.index(after: $0) }
        }
        let stamp = cut.map { String(line[..<$0]) } ?? ""
        let message = cut.map { String(line[$0...]) } ?? line
        let entry = LogGuide.explain(message)
        let problem = entry.map { $0.kind == .problem } ?? LogGuide.isProblem(message)
        let color: AnyShapeStyle = problem ? AnyShapeStyle(Color.red) : (entry?.kind == .note ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(shortStamp(stamp)).foregroundStyle(.tertiary)
            Text(message).foregroundStyle(color)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .help(entry.map { $0.title + " — " + $0.meaning } ?? "")
    }

    /// "11-11 12:14:01"
    private func shortStamp(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        return t.count >= 19 ? String(t.dropFirst(5).prefix(14)) : t
    }
}
