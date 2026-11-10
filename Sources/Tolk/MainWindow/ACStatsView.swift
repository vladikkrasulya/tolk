// «Статистика» block of the Автодополнение settings tab. Numbers only (see ACStats in TolkCore).
import SwiftUI
import TolkCore

/// Where the settings page gets its numbers. DEBUG demo can replace it (TOLK_AC_STATS_DEMO).
enum ACStatsSource {
    @MainActor static var provider: () -> ACStatsData = { ACStatsStore.shared.data }
    @MainActor static func reset() { ACStatsStore.shared.reset() }

    /// Fake data for the off-line render: 40 days, the model changes on day -9.
    static func demo(now: Date = Date()) -> ACStatsData {
        var d = ACStatsData()
        let cal = Calendar.current
        var seed: UInt64 = 7
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(max(1, n))) }
        for off in stride(from: -40, through: 0, by: 1) where rnd(10) > 0 {
            let day = ACStats.dayKey(cal.date(byAdding: .day, value: off, to: now)!, calendar: cal)
            let model = off < -9 ? "gemma-4-E4B-it-q4_0.gguf" : "gemma-4-E2B-abl-Q4_K.gguf"
            for (app, share) in [("com.anthropic.claudefordesktop", 5), ("ru.keepcoder.Telegram", 3), ("com.tinyspeck.slackmacgap", 2), ("com.apple.TextEdit", 1), ("com.apple.mail", 1)] {
                let shown = rnd(share * 12 + 1)
                guard shown > 0 else { continue }
                let acc = shown * (20 + rnd(15)) / 100
                d.update(day: day, model: model, app: app) { b in
                    b.shown = shown; b.shownWords = shown * 3
                    b.tabEvents = acc; b.tabWords = acc; b.tabChars = acc * 6
                    b.allEvents = acc / 8; b.allWords = acc / 8 * 4; b.allChars = acc / 8 * 24
                    b.instantShown = rnd(4); b.instantAccepted = rnd(2); b.instantChars = b.instantAccepted
                    b.typedOn = shown / 2; b.esc = rnd(3)
                    for _ in 0..<min(shown, 8) { b.addLatency(150 + rnd(250)) }
                    if off < -33 { b.approx = true }
                }
            }
        }
        return d
    }
}

struct ACStatsSection: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmReset = false

    private var data: ACStatsData { model.acStats }
    private let periods: [(String, Int?)] = [("Сегодня", 1), ("7 дней", 7), ("30 дней", 30), ("Всё время", nil)]

    private func pct(_ x: Double, has: Bool = true) -> String { has ? "\(Int((x * 100).rounded())) %" : "—" }

    var body: some View {
        Section {
            if data.isEmpty {
                Text("Пока пусто: статистика появится, когда подсказки начнут показываться.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                summaryGrid
                chart
                modelsTable
                appsTable
                if data.days.values.contains(where: { $0.values.contains { $0.values.contains { $0.approx } } }) {
                    Text("Дни «из лога» посчитаны приблизительно: слова оценены по символам, приложение — по последней показанной подсказке.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text("Хранятся только числа, названия программ и модели — без текста. Срок — год.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Сбросить статистику", role: .destructive) { confirmReset = true }
                    .disabled(data.isEmpty)
            }
        } header: {
            Text("Статистика")
        }
        .confirmationDialog("Сбросить всю статистику автодополнения?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) { model.resetStats() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это нельзя отменить.")
        }
    }

    // MARK: Summary

    private var summaryGrid: some View {
        let sums = periods.map { data.summary(last: $0.1).total }
        return Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                Text("")
                ForEach(0..<periods.count, id: \.self) { Text(periods[$0].0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing) }
            }
            row("Принято слов", sums.map { "\($0.acceptedWords)" })
            row("Принято подсказок", sums.map { "\($0.acceptedEvents) из \($0.shown + $0.instantShown)" })
            row("Процент принятых", sums.map { pct($0.acceptRate, has: $0.shown + $0.instantShown > 0) })
            row("Сэкономлено нажатий", sums.map { "\($0.savedKeystrokes)" })
            row("Медианная задержка", sums.map { $0.medianLatency.map { "\($0) мс" } ?? "—" })
        }
        .font(.callout.monospacedDigit())
    }

    private func row(_ title: String, _ values: [String]) -> some View {
        GridRow {
            Text(title).font(.callout).gridColumnAlignment(.leading).frame(width: 170, alignment: .leading)
            ForEach(0..<values.count, id: \.self) { Text(values[$0]).frame(maxWidth: .infinity, alignment: .trailing) }
        }
    }

    // MARK: Chart

    private struct Bar: Identifiable { var id: String; var shown: Int; var accepted: Int; var change: String? }

    private var bars: [Bar] {
        let cal = Calendar.current
        let rows = data.dayRows(last: nil)
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
        let changes = data.modelChanges(rows)
        return (0..<30).map { i in
            let day = ACStats.dayKey(cal.date(byAdding: .day, value: i - 29, to: Date())!, calendar: cal)
            let b = by[day]?.bucket
            return Bar(id: day, shown: (b?.shown ?? 0) + (b?.instantShown ?? 0), accepted: b?.acceptedEvents ?? 0, change: changes[day])
        }
    }

    private func short(_ day: String) -> String { String(day.suffix(5)).split(separator: "-").reversed().joined(separator: ".") }

    private var chart: some View {
        let bars = self.bars
        let maxV = max(1, bars.map(\.shown).max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Последние 30 дней").font(.callout)
                Spacer()
                legend(Color.secondary.opacity(0.35), "показано")
                legend(Color.accentColor, "принято")
                legend(Color.orange, "смена модели")
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bars) { b in
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: max(b.shown > 0 ? 2 : 0, 80 * CGFloat(b.shown) / CGFloat(maxV)))
                        Rectangle().fill(Color.accentColor).frame(height: 80 * CGFloat(min(b.accepted, b.shown)) / CGFloat(maxV))
                    }
                    .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80, alignment: .bottom)
                    .overlay(alignment: .leading) {
                        if b.change != nil { Rectangle().fill(Color.orange).frame(width: 2) }
                    }
                }
            }
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1) }
            HStack {
                Text(short(bars.first!.id)); Spacer(); Text(short(bars[14].id)); Spacer(); Text(short(bars.last!.id))
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(bars.filter { $0.change != nil }) { b in
                Text("\(short(b.id)): модель \(ACStats.shortModel(b.change!))").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9); Text(t).font(.caption).foregroundStyle(.secondary) }
    }

    // MARK: Tables

    private func table(_ title: String, _ rows: [(String, ACBucket)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text(title).gridColumnAlignment(.leading)
                    Text("Показано"); Text("Принято"); Text("%")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(0..<rows.count, id: \.self) { i in
                    let b = rows[i].1
                    GridRow {
                        Text(rows[i].0).lineLimit(1).truncationMode(.middle).gridColumnAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(b.shown + b.instantShown)"); Text("\(b.acceptedEvents)")
                        Text(pct(b.acceptRate, has: b.shown + b.instantShown > 0))
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }

    private var modelsTable: some View {
        table("По моделям", data.byModel().map { (ACStats.shortModel($0.name), $0.bucket) })
    }

    private var appsTable: some View {
        table("Топ-5 программ", data.byApp().prefix(5).map { ($0.name == ACStats.unknownApp ? "не определена" : SettingsModel.appName($0.name), $0.bucket) })
    }
}
