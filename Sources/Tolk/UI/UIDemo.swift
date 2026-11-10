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
                    let text = request.text.count > 80 ? Self.longRussian
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
