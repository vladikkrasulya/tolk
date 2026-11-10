// Debug-only INVISIBLE render of the «Ответить» window (demo engine, no network, no clicks, no focus).
//
//   TOLK_RENDER_REPLY=/some/dir .build/debug/Tolk --background
//
// Writes reply-chips-{light,dark}.png (empty field, ready answers), reply-chips-filled-*.png (a ready answer in the
// field) and reply-*.png (the usual window). The panel is never ordered in or made key; the run aborts if it ever
// reports `isVisible`. Like PopupDemo it runs before anything else of the app starts.
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum ReplyDemo {
    private static var keepAlive: [AnyObject] = []

    static func run() {
        guard let dir = ProcessInfo.processInfo.environment["TOLK_RENDER_REPLY"], !dir.isEmpty else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let partner = "Hey, how are you? At the start of the integration, we delivered a chunk of requests on your end to let your demand show. It's ECPM. Afterward, our system started optimizing and delivering requests to streams with a better CPA. So I can't predict whether you'll see similar volume on your end this week."
        let ctx = ReplyContext(
            partnerText: partner,
            partnerTranslation: "Привет! Как дела? В начале интеграции мы отдали пачку запросов на вашей стороне, чтобы ваш demand показывался. Это было по eCPM. Затем наша система начала оптимизировать и отдавать запросы в потоки с лучшим CPA. Поэтому я не могу предсказать, увидите ли вы похожий объём на своей стороне на этой неделе.",
            partnerLanguage: .english, app: nil, anchor: NSPoint(x: 400, y: 800))
        for (name, dark) in [("light", false), ("dark", true)] {
            let shots: [(String, String, String, Bool)] = [
                ("reply-chips", "", "", false),
                ("reply-chips-filled", "Спасибо, что объяснили. Мы посмотрим и вернёмся с ответом.",
                 "Thanks for explaining. We'll take a look and get back to you.", true),
                ("reply", "Да, видим падение конверсии, похоже на плохие сабы — отключим их сегодня и пришлём новый список",
                 "Yeah, we see the CR drop too — looks like bad subs. We'll disable them today and send over a new list.", false),
            ]
            for (file, reply, translated, chip) in shots {
                let r = ReplyPanelController(engine: DemoTranslationEngine(mode: .normal))
                keepAlive.append(r)
                r.renderForReview(ctx, dark: dark, reply: reply, translated: translated, fromChip: chip, to: "\(dir)/\(file)-\(name).png")
                guard !(r.window?.isVisible ?? false) else { print("[reply-demo] ABORT: the panel became visible"); NSApp.terminate(nil); return }
                print("[reply-demo] wrote \(file)-\(name).png (visible=\(r.window?.isVisible ?? false))")
            }
        }
        NSApp.terminate(nil)
    }
}
#endif
