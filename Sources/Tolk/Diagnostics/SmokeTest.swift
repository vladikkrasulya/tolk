// Debug-only smoke run: TOLK_SMOKE=1 .build/debug/Tolk --background
// Builds every window controller WITHOUT showing anything, pokes the public API in "awkward" orders
// (setters / callbacks before the view is loaded, twice in a row, after stop) and exits 0 if nothing trapped.
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum SmokeTest {
    static var requested: Bool { ProcessInfo.processInfo.environment["TOLK_SMOKE"] != nil }

    private static func step(_ name: String, _ body: () -> Void) {
        body()
        print("smoke ok: \(name)")
        fflush(stdout)
    }

    private static func engines() -> [TranslationEngine] {
        [DemoTranslationEngine(mode: .normal), DemoTranslationEngine(mode: .error), DemoTranslationEngine(mode: .fallback)]
    }

    /// Fresh controllers (never loaded) — every setter / entry point in a bad order.
    static func run() {
        let e = engines()
        let tmp = NSTemporaryDirectory() + "tolk-smoke-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = HistoryStore(path: tmp + "/history.jsonl", defaults: UserDefaults(suiteName: "tolk-smoke") ?? .standard)

        step("translate page: setters before load") {
            let p = TranslatePageViewController(engine: e[0])
            p.engine = e[1]; p.engine = e[2]
            p.footerHint = "x"; p.topInset = 10; p.history = store; p.onOpenDocument = { _ in }
            p.onOpenDocument = nil; p.history = nil
            p.stop()
            p.engine = e[0]
            _ = p.view
            p.engine = e[1]
            p.stop(); p.stop()
            p.load(text: "Hello world. Second sentence here.")
            p.engine = e[2]; p.engine = e[0]
            p.stop()
            p.setMode(.reply); p.setMode(.compose); p.setMode(.translate)
            p.engine = e[1]
        }
        step("translate page: load(text:) first") {
            let p = TranslatePageViewController(engine: e[0])
            p.load(text: "")
            p.load(text: String(repeating: "Привет, мир. ", count: 50))
            p.focusInput()
        }
        step("translate page: handoff first") {
            let p = TranslatePageViewController(engine: e[0])
            p.load(PopupHandoff(text: "Hi", source: nil, target: nil, requestTone: .auto, displayTone: .auto, threadContext: nil), suggestVariants: true)
            p.stop()
        }
        step("input window: engine before page exists") {
            let w = InputWindowController(engine: e[0])
            w.engine = e[1]
            _ = w.page
            w.engine = e[2]
        }
        step("image page") {
            let p = ImageTranslateViewController(engine: e[0])
            p.engine = e[1]; p.screenHotKeyDisplay = "⌥S"; p.cancelWork()
            p.engine = e[2]
            _ = p.view
            p.engine = e[0]; p.screenHotKeyDisplay = "⌥⇧S"; p.cancelWork()
            p.load(pages: [])
        }
        step("documents page") {
            let p = DocumentsViewController(engine: e[0])
            p.engine = e[1]; p.cancelWork()
            _ = p.isBusy; _ = p.translationPairs
            p.engine = e[2]
            _ = p.view
            p.engine = e[0]; p.cancelWork()
            p.cancelWork()
        }
        step("history page") {
            let p = HistoryViewController(store: store)
            p.onOpen = { _ in }
            store.record(HistoryEntry(origin: "page", app: nil, source: "a", translation: "b", sourceLanguage: .english, targetLanguage: .russian, provider: "t", mode: .translate))
            _ = p.view
            p.reload(); p.onOpen = nil
            p.reload()
        }
        step("glossary page") {
            let path = tmp + "/rules.md"
            let g = GlossaryViewController(rulesPath: path)
            g.switchFile(to: tmp + "/rules2.md")
            g.flush()
            _ = g.view
            g.switchFile(to: tmp + "/rules3.md")
            g.flush()
            g.switchFile(to: "/nonexistent-dir/rules.md") // unwritable: must not trap
            g.flush()
        }
        step("popup") {
            let p = TranslationPopupController(engine: e[0])
            p.replaceEngine(e[1]); p.hideNow(); p.hide(); p.replaceEngine(e[2])
            _ = p.isVisible
        }
        step("reply panel") {
            let r = ReplyPanelController(engine: e[0])
            r.replaceEngine(e[1]); r.close(); r.replaceEngine(e[2])
        }
        step("quick actions") {
            let q = QuickActionsController(engine: e[0], config: TolkConfig())
            q.update(engine: e[1], config: TolkConfig()); q.cancel(); q.update(engine: e[2], config: TolkConfig())
        }
        print("smoke: all steps passed"); fflush(stdout)
    }
}
#endif
