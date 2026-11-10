// Debug-only fake engine and sample text for previews (see MainWindowDemo).
#if DEBUG
import AppKit
import TolkCore

/// Fake engine that streams word by word, like Qwen does.
final class DemoTranslationEngine: TranslationEngine, @unchecked Sendable {
    enum Mode: String { case normal = "1", fallback, error }
    let mode: Mode
    init(mode: Mode) { self.mode = mode }

    static let longRussian = """
    Привет! Мы посмотрели статистику по кампании за прошлую неделю: CTR вырос на 12 %, но eCPM \
    в тирах 2–3 просел, и fill rate на SSP упал примерно до 64 %. Похоже, проблема в floor price, \
    который мы подняли в пятницу. Предлагаю откатить флор до прежнего значения на сегменте мобильного \
    веба и параллельно запустить A/B-тест с динамическими флорами на десктопе.

    Ещё вопрос: можете прислать свежий ads.txt и подтвердить, что новые seller ID уже добавлены? \
    Без этого часть DSP режет трафик как unauthorized. Если всё ок, к среде сможем раскатить \
    изменения на 100 % трафика и вернуть объём.

    Спасибо, ждём обратной связи!
    """

    /// What the back-translation of `longRussian` looks like (a bit off on purpose: shows the highlighting).
    static let backEnglish = """
    Hi! We reviewed the campaign statistics for last week: CTR grew by 12%, but eCPM \
    in tiers 2–3 sank, and the SSP fill rate fell to roughly 64%. It seems the problem is the floor price \
    we raised on Friday. I suggest rolling the floor back to its previous value on the mobile \
    web segment and at the same time launching an A/B test with dynamic floors on desktop.

    One more question: could you send a fresh ads.txt and confirm that the new seller IDs have been added? \
    Without it, some DSPs cut the traffic as unauthorized. If everything is fine, by Wednesday we can roll out \
    the changes to 100% of traffic and bring back the volume.

    Thanks, waiting for your feedback!
    """

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        let mode = self.mode
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    let src = request.source ?? .english
                    let dst = request.target ?? .russian
                    if mode == .error {
                        try await Task.sleep(for: .milliseconds(600))
                        throw URLError(.cannotConnectToHost)
                    }
                    if mode == .fallback {
                        c.yield(.started(provider: "qwen", source: src, target: dst))
                        try await Task.sleep(for: .milliseconds(400))
                        c.yield(.delta("Прив"))
                        try await Task.sleep(for: .milliseconds(500))
                        c.yield(.fellBack(from: "qwen", reason: "vkbox: connection refused"))
                        c.yield(.started(provider: "google", source: src, target: dst))
                    } else {
                        c.yield(.started(provider: "qwen", source: src, target: dst))
                    }
                    let text = request.target == .english && request.source == .russian ? Self.backEnglish
                        : request.text.count > 80 ? Self.longRussian
                        : "[\(request.tone.rawValue)] " + Self.longRussian.prefix(140) + "…"
                    var chunk = ""
                    for ch in text {
                        chunk.append(ch)
                        if ch == " " || ch == "\n" {
                            c.yield(.delta(chunk)); chunk = ""
                            try await Task.sleep(for: .milliseconds(25))
                        }
                    }
                    if !chunk.isEmpty { c.yield(.delta(chunk)) }
                    var stats = TranslationStats(provider: "gemma-translate", route: .home, firstChunk: 1.7, total: 6.8,
                                                 outputTokens: 110, tokensExact: true, fallbackReason: nil)
                    stats.warnings = ["в переводе нет времени 15:30", "потеряна ссылка example.com/ads.txt"]
                    c.yield(.stats(stats))
                    c.yield(.finished)
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    func addGlossaryTerm(source: String, translation: String) throws {
        print("[demo] glossary: \(source) -> \(translation)")
    }

    func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote] {
        try? await Task.sleep(for: .milliseconds(500))
        return [
            TranslationNote(term: "floor price", used: "floor price", suggestion: "минимальная цена",
                            note: "В RTB/AdTech «floor» — минимальная ставка аукциона; в русской практике чаще «флор» или «минимальная цена»."),
            TranslationNote(term: "fill rate", used: "fill rate", suggestion: nil,
                            note: "Доля запросов, на которые пришла хотя бы одна ставка. Обычно не переводят."),
        ]
    }

    func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String] {
        try? await Task.sleep(for: .milliseconds(300))
        return ["минимальная цена", "порог цены", "флор", "нижняя граница ставки"]
    }

    func refine(source: String, translation: String, from: Language, to: Language, tone: Tone) -> AsyncThrowingStream<String, Error> {
        let edited = translation
            .replacingOccurrences(of: "Мы посмотрели статистику", with: "Мы просмотрели статистику")
            .replacingOccurrences(of: "Предлагаю откатить", with: "Предлагаю вернуть")
            .replacingOccurrences(of: "раскатить изменения", with: "выкатить изменения")
        return AsyncThrowingStream { c in c.yield(edited); c.finish() }
    }
}

@MainActor
enum TolkUIDemo {
    static let sampleEnglish = """
    Hi team! We looked at last week's campaign stats: CTR is up 12%, but eCPM in tiers 2–3 dropped \
    and SSP fill rate fell to about 64%. It looks like the floor price we raised on Friday is the \
    culprit. I suggest rolling the floor back on mobile web and running an A/B test with dynamic \
    floors on desktop in parallel. Also, could you send the latest ads.txt and confirm the new \
    seller IDs are in? Thanks!
    """
}
#endif
