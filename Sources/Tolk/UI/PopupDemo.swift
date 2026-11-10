// Debug-only INVISIBLE render of the translation popup (demo engine, no network, no clicks, no focus).
//
//   TOLK_RENDER_POPUP=/some/dir .build/debug/Tolk --background
//
// Writes popup-{tz,cached}-{light,dark}.png and quits. Like TranslateHintsDemo the panel is never shown: it is built,
// moved far off every screen, kept at alpha 0 and never ordered in or made key (`presentInvisibly`); the run aborts
// if the panel ever reports `isVisible`.
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum PopupDemo {
    private static var keepAlive: [AnyObject] = []

    static func run() {
        guard let dir = ProcessInfo.processInfo.environment["TOLK_RENDER_POPUP"], !dir.isEmpty else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The popup reads these switches from the user's defaults: remember and restore them.
        let defaults = UserDefaults.standard
        let keys = ["tolk.popup.notes", "tolk.popup.back"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.set(false, forKey: $0) }

        Task { @MainActor in
            defer {
                for (k, v) in zip(keys, saved) { if let v { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) } }
                DemoTranslationEngine.fixedTranslation = nil
                DemoTranslationEngine.fromCache = false
            }
            let source = "Hey Vlad, let's sync at 10:00 EST tomorrow. Can you check the sub IDs before the call?"
            DemoTranslationEngine.fixedTranslation = "Привет, Влад, давай созвонимся завтра в 10:00 EST. Можешь проверить sub ID до звонка?"
            for (name, cached) in [("tz", false), ("cached", true)] {
                DemoTranslationEngine.fromCache = cached
                for (aname, ap) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
                    let popup = TranslationPopupController(engine: DemoTranslationEngine(mode: .normal))
                    keepAlive.append(popup)
                    guard popup.presentInvisibly(text: source, appearance: ap) else {
                        print("[popup-demo] ABORT: the panel became visible"); NSApp.terminate(nil); return
                    }
                    for _ in 0..<60 where !popup.debugFinished { try? await Task.sleep(for: .milliseconds(200)) }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !popup.debugPanelVisible else { print("[popup-demo] ABORT: the panel became visible"); NSApp.terminate(nil); return }
                    popup.renderInvisible(to: "\(dir)/popup-\(name)-\(aname).png", dark: aname == "dark")
                    print("[popup-demo] wrote popup-\(name)-\(aname).png (visible=\(popup.debugPanelVisible))")
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
