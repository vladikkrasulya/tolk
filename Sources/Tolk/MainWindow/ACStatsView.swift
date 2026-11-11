// Data source of the autocomplete numbers in Настройки → Статистика (see ACStats in TolkCore).
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

