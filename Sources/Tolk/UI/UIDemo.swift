// Owned by the "UI" session. Debug-only preview of the UI without double Cmd+C or a real engine.
//
//   TOLK_UI_DEMO=1 swift run Tolk            — popup with a long streaming text + input window
//   TOLK_UI_DEMO=fallback swift run Tolk     — popup that falls back from Qwen to Google
//   TOLK_UI_DEMO=error swift run Tolk        — popup that fails with a network error
//   TOLK_UI_APPEARANCE=dark|light            — force the appearance
//
// Wiring (coordinator, AppDelegate.applicationDidFinishLaunching, after creating popup/inputWindow):
//   #if DEBUG
//   TolkUIDemo.runIfRequested(popup: popup, inputWindow: inputWindow)
//   #endif
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

    private static var keepAlive: [AnyObject] = []

    /// Uses its own demo engine unless `engine` is given (pass the real one to try it live).
    static func runIfRequested(popup: TranslationPopupController? = nil,
                               inputWindow: InputWindowController? = nil,
                               engine: TranslationEngine? = nil) {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TOLK_UI_DEMO"], !raw.isEmpty, raw != "0" else { return }
        switch env["TOLK_UI_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let mode = DemoTranslationEngine.Mode(rawValue: raw) ?? .normal
        let demoEngine = engine ?? DemoTranslationEngine(mode: mode)
        let popup = engine == nil ? TranslationPopupController(engine: demoEngine) : (popup ?? TranslationPopupController(engine: demoEngine))
        let input = engine == nil ? InputWindowController(engine: demoEngine) : (inputWindow ?? InputWindowController(engine: demoEngine))
        keepAlive = [popup, input]

        if env["TOLK_UI_DEMO_INPUT"] != "0" {
            input.show(text: "Can you send the latest ads.txt and confirm the new seller IDs?")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let p = env["TOLK_UI_DEMO_POINT"].flatMap { s -> NSPoint? in
                let parts = s.split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
            } ?? NSEvent.mouseLocation
            popup.show(text: sampleEnglish, at: p)
        }
    }
}
#endif
