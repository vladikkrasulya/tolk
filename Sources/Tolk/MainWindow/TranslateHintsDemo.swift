// Debug-only invisible render of the «Перевод» page with the hints panel (demo engine, no network).
//
//   TOLK_HINTS_SHOT=/some/dir .build/debug/Tolk --background
//
// Writes translate-hints-{wide,narrow}-{light,dark}.png and quits. The windows used here are never shown:
// no show/orderFront/makeKey — they only exist so that AppKit lays the views out and cacheDisplay can draw them.
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum TranslateHintsDemo {
    private struct Shot {
        let name: String
        let size: NSSize
        let appearance: NSAppearance?
        let window: NSWindow
        let page: TranslatePageViewController
    }
    private static var keepAlive: [AnyObject] = []

    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["TOLK_HINTS_SHOT"], !dir.isEmpty else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The demo texts, switches and collapsed cards must not depend on (or touch) the user's settings.
        UserDefaults.standard.set(true, forKey: "tolk.popup.notes")
        UserDefaults.standard.set(true, forKey: "tolk.popup.back")

        var shots: [Shot] = []
        for (wname, size) in [("wide", NSSize(width: 1180, height: 700)), ("narrow", NSSize(width: 820, height: 760))] {
            for (aname, ap) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
                let page = TranslatePageViewController(engine: DemoTranslationEngine(mode: .normal))
                let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                win.alphaValue = 0
                win.appearance = ap
                win.contentViewController = page   // loads the view; the window is NOT ordered in
                win.setContentSize(size)
                shots.append(Shot(name: "translate-\(wname)-\(aname)", size: size, appearance: ap, window: win, page: page))
            }
        }
        keepAlive = shots.map { $0.window } + shots.map { $0.page }
        for s in shots { s.page.load(text: TolkUIDemo.sampleEnglish) }

        Task { @MainActor in
            @MainActor func settle(_ seconds: Double = 0.6) async {
                try? await Task.sleep(for: .seconds(seconds))
                for _ in 0..<60 where !shots.allSatisfy({ $0.page.debugIdle }) { try? await Task.sleep(for: .milliseconds(300)) }
            }
            @MainActor func shot(_ name: String) { print("[hints-demo] step \(name)"); for s in shots { render(s, to: "\(dir)/\(s.name)-\(name).png") } }
            print("[hints-demo] started")
            // translation (~6 s) + 1.5 s pause + back-translation + notes
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(500))
                if shots.allSatisfy({ $0.page.debugHintsReady }) { break }
            }
            print("[hints-demo] ready: \(shots.map { $0.page.debugHintsReady })")
            await settle(2.5)
            // 1. normal translation with hints (glossary underline, ⚠ badge, back-translation diff)
            shot("1-hints")
            // 2. hover on a pair
            for s in shots { s.page.debugHover("floor price we raised on Friday") }
            try? await Task.sleep(for: .milliseconds(300))
            shot("2-pair-hover")
            for s in shots { s.page.debugHover("zzz") }
            // 3. variants of a sentence
            for s in shots { s.page.debugClickSentence("floor price, который") }
            await settle(0.5)
            shot("3-variants")
            // 4. rewrite: shorter (diff card), then a rejected one
            for s in shots { s.page.debugRewrite(.shorter) }
            await settle(1.0)
            try? await Task.sleep(for: .seconds(0.4))
            shot("4-rewrite")
            for s in shots { s.page.debugRewrite(.firmer) }
            await settle(1.0)
            print("[hints-demo] notice \(shots[0].page.debugNotice)")
            shot("4b-rewrite-rejected")
            // 5. reply mode
            for s in shots { s.page.debugReply(message: DemoTranslationEngine.partnerMessage, answer: DemoTranslationEngine.myReply) }
            await settle(1.0)
            for _ in 0..<40 {
                if shots.allSatisfy({ $0.page.debugHintsReady }) { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            await settle(2.5)
            shot("5-reply")
            // 6. «что он имел в виду»
            for s in shots { s.page.debugExplain() }
            await settle(0.5)
            shot("6-explain")
            await renderLongStatus(to: dir)
            renderRecents(to: dir)
            print("[hints-demo] shots in \(dir)")
            NSApp.terminate(nil)
        }
    }

    /// No warnings, long status line («Gemma дома · первое слово … · ток/с»): both buttons of the bottom line must fit whole.
    private static func renderLongStatus(to dir: String) async {
        DemoTranslationEngine.noWarnings = true
        var list: [Shot] = []
        for (w, h, dark) in [(1000, 700, false), (1180, 700, false), (1500, 700, false), (700, 760, false), (1000, 700, true), (700, 760, true)] {
            let size = NSSize(width: w, height: h)
            let page = TranslatePageViewController(engine: DemoTranslationEngine(mode: .normal))
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.alphaValue = 0
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            win.contentViewController = page
            win.setContentSize(size)
            keepAlive += [win, page]
            list.append(Shot(name: "translate-w\(w)-\(dark ? "dark" : "light")", size: size, appearance: win.appearance, window: win, page: page))
        }
        for s in list { s.page.load(text: TolkUIDemo.sampleEnglish) }
        for _ in 0..<60 where !list.allSatisfy({ $0.page.debugHintsReady }) { try? await Task.sleep(for: .milliseconds(400)) }
        try? await Task.sleep(for: .seconds(1))
        for s in list { render(s, to: "\(dir)/\(s.name)-7-no-warnings-long-status.png") }
        for s in list { s.page.debugScrollOutputToEnd() }
        try? await Task.sleep(for: .milliseconds(300))
        for s in list { render(s, to: "\(dir)/\(s.name)-8-scrolled-down.png") }
        DemoTranslationEngine.noWarnings = false
    }

    /// The «Последние переводы» popover content, rendered on its own (the popover itself is never shown).
    private static func renderRecents(to dir: String) {
        let tmp = NSTemporaryDirectory() + "tolk-recents-demo-\(ProcessInfo.processInfo.processIdentifier).jsonl"
        let store = HistoryStore(path: tmp, defaults: UserDefaults(suiteName: "tolk.recents.demo") ?? .standard)
        store.add(HistoryEntry(date: Date().addingTimeInterval(-300), origin: "page", app: nil, source: "Привет! Мы посмотрели статистику по кампании за прошлую неделю.",
                               translation: "Hi! We looked at last week's campaign stats.", sourceLanguage: .russian, targetLanguage: .english, provider: "gemma-translate", mode: .translate))
        store.add(HistoryEntry(date: Date().addingTimeInterval(-4000), origin: "popup", app: "Slack", source: "Can you send the latest ads.txt?",
                               translation: "Можете прислать свежий ads.txt?", sourceLanguage: .english, targetLanguage: .russian, provider: "gemma-translate", mode: .translate))
        store.add(HistoryEntry(date: Date().addingTimeInterval(-90000), origin: "popup", app: "Telegram", source: "Коли ти будеш вдома? Я вже чекаю на тебе.",
                               translation: "Когда ты будешь дома? Я уже жду тебя.", sourceLanguage: .ukrainian, targetLanguage: .russian, provider: "gemma-translate", mode: .translate))
        for (aname, ap) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            let vc = RecentTranslationsViewController(store: store)
            let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 420, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.alphaValue = 0
            win.appearance = ap
            win.contentViewController = vc
            win.setContentSize(NSSize(width: 420, height: 400))
            keepAlive += [win, vc]
            let shot = Shot(name: "recent-\(aname)", size: NSSize(width: 420, height: 400), appearance: ap, window: win, page: TranslatePageViewController(engine: DemoTranslationEngine(mode: .normal)))
            render(shot, to: "\(dir)/recent-\(aname).png")
        }
        try? FileManager.default.removeItem(atPath: tmp)
    }

    private static func render(_ s: Shot, to path: String) {
        guard let view = s.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        print("[hints-demo] \(s.name): window=\(s.window.frame.size) view=\(view.frame) fitting=\(view.fittingSize)")
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Paint the window background under it (a borderless window draws none into cacheDisplay).
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = view.bounds.size   // before the context: 1 unit = 1 point, not 1 pixel
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        rep.draw(in: view.bounds)
        // Window background behind whatever the view left transparent.
        let dark = (s.appearance ?? view.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ctx.cgContext.setBlendMode(.destinationOver)
        ctx.cgContext.setFillColor(dark ? CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
                                        : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        ctx.cgContext.fill(CGRect(origin: .zero, size: view.bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("[hints-demo] wrote \(path)")
    }
}
#endif
