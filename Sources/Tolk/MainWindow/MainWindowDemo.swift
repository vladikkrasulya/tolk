// Debug-only preview of the main window with a fake engine.
//
//   TOLK_MAIN_DEMO=translate|image|glossary|settings swift run Tolk   — opens the main window on that section
//   TOLK_UI_APPEARANCE=dark|light                                     — force the appearance
//   TOLK_MAIN_SHOT=/some/dir                                          — render every section (+ the input window)
//                                                                       to PNGs via cacheDisplay, then quit
//
// Wiring (coordinator, AppDelegate.applicationDidFinishLaunching):
//   #if DEBUG
//   MainWindowDemo.runIfRequested()
//   #endif
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum MainWindowDemo {
    private static var keepAlive: [AnyObject] = []
    private static var forced: NSAppearance?

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TOLK_MAIN_DEMO"], !raw.isEmpty, raw != "0" else { return }
        // Forced look is set per window (never on NSApp), so nothing leaks into the app's own theme.
        switch env["TOLK_UI_APPEARANCE"] {
        case "dark": forced = NSAppearance(named: .darkAqua)
        case "light": forced = NSAppearance(named: .aqua)
        default: forced = nil
        }
        let engine = DemoTranslationEngine(mode: .normal)
        let config = TolkConfig.load()
        let translate = TranslatePageViewController(engine: engine)
        let main = MainWindowController(translate: translate,
                                        image: ImageTranslateViewController(engine: engine),
                                        documents: DocumentsViewController(engine: engine),
                                        history: HistoryViewController(store: HistoryStore()),
                                        glossary: GlossaryViewController(rulesPath: config.rulesPath),
                                        settings: SettingsViewController(config: config))
        keepAlive = [main, translate]
        main.window?.appearance = forced
        let section = MainWindowController.Section(rawValue: raw) ?? .translate
        main.show(section)
        if section == .translate { translate.load(text: TolkUIDemo.sampleEnglish) }

        if let dir = env["TOLK_MAIN_SHOT"], !dir.isEmpty {
            Task { @MainActor in await shootAll(main: main, translate: translate, engine: engine, dir: dir) }
        }
    }

    private static func shootAll(main: MainWindowController, translate: TranslatePageViewController,
                                 engine: TranslationEngine, dir: String) async {
        let suffix = ProcessInfo.processInfo.environment["TOLK_UI_APPEARANCE"] ?? "auto"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        main.window?.setFrame(NSRect(x: 80, y: 80, width: 900, height: 620), display: true)

        main.show(.translate)
        translate.load(text: TolkUIDemo.sampleEnglish)
        try? await Task.sleep(for: .seconds(4))
        render(main.window, to: "\(dir)/main-translate-\(suffix).png")
        for section in [MainWindowController.Section.settings, .glossary, .image, .help] {
            main.show(section)
            try? await Task.sleep(for: .seconds(1))
            render(main.window, to: "\(dir)/main-\(section.rawValue)-\(suffix).png")
        }

        // Every settings tab, full height, in an off-screen borderless window (the main window is clamped to the screen).
        do {
            let vc = SettingsViewController(config: TolkConfig.load())
            let env = ProcessInfo.processInfo.environment
            let w = Double(env["TOLK_SHOT_WIDTH"] ?? "") ?? 860, h = Double(env["TOLK_SHOT_HEIGHT"] ?? "") ?? 2300
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless],
                               backing: .buffered, defer: false)
            win.contentViewController = vc
            win.setContentSize(NSSize(width: w, height: h))
            win.appearance = forced
            for tab in SettingsTab.allCases { for sec in 0..<1 {
                vc.model.open(tab, section: sec)
                try? await Task.sleep(for: .milliseconds(1200))
                let v = vc.view
                v.layoutSubtreeIfNeeded(); v.displayIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "\(dir)/settings-\(tab.rawValue)\(sec)-\(Int(w))-\(suffix).png"))
                        print("[main-demo] wrote \(dir)/settings-\(tab.rawValue)-\(suffix).png")
                    }
                }
            } }
            win.orderOut(nil)
        }

        // Settings scrolled to the bottom part.
        main.show(.settings)
        try? await Task.sleep(for: .milliseconds(500))
        if let scroll = findScrollView(in: main.pages[.settings]?.view) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .milliseconds(400))
            render(main.window, to: "\(dir)/main-settings-bottom-\(suffix).png")
        }

        let input = InputWindowController(engine: engine)
        keepAlive.append(input)
        input.show(text: "Can you send the latest ads.txt and confirm the new seller IDs?")
        try? await Task.sleep(for: .seconds(2.5))
        let inputWindow = NSApp.windows.first { $0 is InputWindow }
        inputWindow?.appearance = forced
        render(inputWindow, to: "\(dir)/input-window-\(suffix).png")

        print("[main-demo] shots in \(dir)")
        NSApp.terminate(nil)
    }

    private static func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        // The settings form is the biggest scroll view on screen.
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.frame.height > (best?.frame.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    /// Renders the whole window frame (title bar, toolbar, sidebar) into a PNG.
    static func render(_ window: NSWindow?, to path: String) {
        guard let window, let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        // Redraw into a standard RGBA bitmap so we can paint over it.
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = frameView.bounds.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        rep.draw(in: frameView.bounds)
        NSGraphicsContext.restoreGraphicsState()
        compositeGlass(in: frameView, onto: out)
        if let data = out.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("[main-demo] wrote \(path)")
        }
    }

    /// cacheDisplay can't draw Liquid Glass (NSGlassEffectView comes out blank), so the sidebar
    /// content is drawn again on an opaque approximation of the glass, below the title bar.
    private static func compositeGlass(in frameView: NSView, onto rep: NSBitmapImageRep) {
        var glasses: [NSView] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)) == "NSGlassEffectView", v.frame.height > 100 { glasses.append(v); return }
            v.subviews.forEach(walk)
        }
        walk(frameView)
        let titlebar = frameView.subviews.first { String(describing: type(of: $0)) == "NSTitlebarContainerView" }
        let topLimit = titlebar?.frame.minY ?? frameView.bounds.maxY
        guard !glasses.isEmpty, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
            for glass in glasses {
                var r = glass.convert(glass.bounds, to: frameView)
                r.size.height = min(r.maxY, topLimit) - r.minY
                let isDark = frameView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                (isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                r.fill()
                var tables: [NSView] = []
                func findTables(_ v: NSView) { if v is NSTableView { tables.append(v) } else { v.subviews.forEach(findTables) } }
                findTables(glass)
                for sub in tables {
                    let sr = sub.convert(sub.bounds, to: frameView).intersection(r)
                    guard sr.width > 0, sr.height > 0,
                          let srep = sub.bitmapImageRepForCachingDisplay(in: sub.bounds) else { continue }
                    sub.cacheDisplay(in: sub.bounds, to: srep)
                    let img = NSImage(size: sub.bounds.size)
                    img.addRepresentation(srep)
                    let full = sub.convert(sub.bounds, to: frameView)
                    NSGraphicsContext.current?.saveGraphicsState()
                    NSBezierPath(rect: r).addClip()
                    img.draw(in: full)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
