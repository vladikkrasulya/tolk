// Owned by the "glossary" session. Debug-only preview of the glossary page.
//
//   TOLK_GLOSSARY_DEMO=1 swift run Tolk                    — the page in its own window, over a temp COPY of rules.md
//   TOLK_GLOSSARY_DEMO_SHOTS=/some/dir swift run Tolk      — render PNGs (both tabs, search, dark,
//                                                            external "В глоссарий" change) and quit
//   TOLK_GLOSSARY_DEMO_RULES=/path/rules.md                — source to copy (default ~/Translate/rules.md)
//
// Wiring (coordinator, AppDelegate.applicationDidFinishLaunching):
//   #if DEBUG
//   GlossaryDemo.runIfRequested()
//   #endif
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum GlossaryDemo {
    private static var keepAlive: [AnyObject] = []

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        let shots = env["TOLK_GLOSSARY_DEMO_SHOTS"]
        guard shots != nil || (env["TOLK_GLOSSARY_DEMO"].map { !$0.isEmpty && $0 != "0" } ?? false) else { return }
        let source = (env["TOLK_GLOSSARY_DEMO_RULES"] ?? "~/Translate/rules.md") as NSString
        let path = makeTempCopy(of: source.expandingTildeInPath)
        print("[glossary demo] editing a copy: \(path)")
        let (window, vc) = makeWindow(rulesPath: path)
        keepAlive = [window, vc]
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let dir = shots { Task { await renderShots(window: window, vc: vc, rulesPath: path, to: dir); exit(0) } }
    }

    static func makeTempCopy(of src: String) -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("tolk-glossary-demo")
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dst = (dir as NSString).appendingPathComponent("rules.md")
        if (try? FileManager.default.copyItem(atPath: src, toPath: dst)) == nil {
            try? "## Стиль\n- Пиши коротко.\n\n## Глоссарий\n- bid → ставка\n".write(toFile: dst, atomically: true, encoding: .utf8)
        }
        return dst
    }

    static func makeWindow(rulesPath: String) -> (NSWindow, GlossaryViewController) {
        let vc = GlossaryViewController(rulesPath: rulesPath)
        // Same content size the main window gives a page (900x620 minus sidebar and toolbar).
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 570),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Глоссарий — демо"
        w.contentViewController = vc
        w.setContentSize(NSSize(width: 690, height: 570))
        w.isReleasedWhenClosed = false
        w.center()
        return (w, vc)
    }

    static func renderShots(window: NSWindow, vc: GlossaryViewController, rulesPath: String, to dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(350))
            render(window, to: (dir as NSString).appendingPathComponent(name + ".png"))
        }
        func search(_ q: String) {
            guard let f = find(NSSearchField.self, in: window.contentView) else { return }
            f.stringValue = q
            _ = f.target?.perform(f.action, with: f)
        }
        window.appearance = NSAppearance(named: .aqua)
        vc.showTerms()
        await shot("glossary-terms-light")
        search("traf")
        await shot("glossary-search-light")
        search("")
        // Simulate the popup's "В глоссарий" button writing behind our back.
        try? RulesStore(path: rulesPath).addTerm(source: "fill rate", translation: "филрейт")
        try? await Task.sleep(for: .milliseconds(900))
        if let t = find(NSTableView.self, in: window.contentView) {
            t.scrollRowToVisible(t.numberOfRows - 1)
            t.selectRowIndexes([t.numberOfRows - 1], byExtendingSelection: false)
        }
        await shot("glossary-external-change-light")
        vc.addTerm()
        window.fieldEditor(false, for: nil)?.insertText("seller ID")
        await shot("glossary-adding-light")
        window.makeFirstResponder(nil)
        vc.showStyle()
        await shot("glossary-style-light")
        window.appearance = NSAppearance(named: .darkAqua)
        await shot("glossary-style-dark")
        vc.showTerms()
        await shot("glossary-terms-dark")
        vc.flush()
        print("[glossary demo] shots in \(dir); edited copy: \(rulesPath)")
    }

    static func render(_ window: NSWindow, to path: String) {
        guard let v = window.contentView else { return }
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        // cacheDisplay skips the window background: paint it first so dark mode looks like the real window.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func find<T: NSView>(_ type: T.Type, in v: NSView?) -> T? {
        guard let v else { return nil }
        if let t = v as? T { return t }
        for s in v.subviews { if let t = find(type, in: s) { return t } }
        return nil
    }
}
#endif
