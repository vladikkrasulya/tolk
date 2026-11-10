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
                shots.append(Shot(name: "translate-hints-\(wname)-\(aname)", size: size, appearance: ap, window: win, page: page))
            }
        }
        keepAlive = shots.map { $0.window } + shots.map { $0.page }
        for s in shots { s.page.load(text: TolkUIDemo.sampleEnglish) }

        Task { @MainActor in
            // translation (~6 s) + 1.5 s pause + back-translation + notes
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(500))
                if shots.allSatisfy({ $0.page.debugHintsReady }) { break }
            }
            try? await Task.sleep(for: .seconds(9))
            for s in shots { render(s, to: "\(dir)/\(s.name)-1-hints.png") }
            for s in shots { s.page.debugRefine() }
            try? await Task.sleep(for: .seconds(9))   // pause + back-translation + notes again for the edited text
            for s in shots { s.page.debugSelectOutput("floor price") }
            try? await Task.sleep(for: .seconds(1.5))
            for s in shots { render(s, to: "\(dir)/\(s.name)-2-word-editor.png") }
            print("[hints-demo] shots in \(dir)")
            NSApp.terminate(nil)
        }
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
