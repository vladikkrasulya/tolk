// Owned by the "image" session. Debug-only preview of the "Фото и скриншоты" page.
//
//   TOLK_IMAGE_DEMO=empty swift run Tolk                    — the empty page (drop zone)
//   TOLK_IMAGE_DEMO=/path/a.heic:/path/b.pdf swift run Tolk — opens the files, OCR + translation
//   TOLK_IMAGE_DEMO_OUT=/tmp/page.png                       — when idle, render the window to PNG
//   TOLK_IMAGE_DEMO_QUIT=1                                  — quit after rendering (prints OCR + translation)
//   TOLK_IMAGE_DEMO_TARGET=en                               — translation language for the demo
//   TOLK_OCR=/path/img.png swift run Tolk                   — print the OCR text of a file and quit
//   TOLK_UI_APPEARANCE=dark|light                           — force the appearance
//
// Wiring (coordinator, AppDelegate.applicationDidFinishLaunching):
//   #if DEBUG
//   TolkImageDemo.runIfRequested(engine: engine)
//   #endif
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum TolkImageDemo {
    private static var keepAlive: [AnyObject] = []

    static func runIfRequested(engine: TranslationEngine) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["TOLK_OCR"], !path.isEmpty { runOCR(path); return }
        guard let raw = env["TOLK_IMAGE_DEMO"], !raw.isEmpty, raw != "0" else { return }
        switch env["TOLK_UI_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let t = env["TOLK_IMAGE_DEMO_TARGET"] { UserDefaults.standard.set(t, forKey: "tolk.image.target") }

        let vc = ImageTranslateViewController(engine: engine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Фото и скриншоты — демо"
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        keepAlive = [vc, window]

        if raw != "empty" {
            let urls = raw.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            vc.open(urls: urls)
        }
        guard let out = env["TOLK_IMAGE_DEMO_OUT"] else { return }
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
            MainActor.assumeIsolated {
                guard !vc.isBusy || Date().timeIntervalSince(started) > 240 else { return }
                t.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    render(window, to: out)
                    print("=== OCR ===\n\(vc.recognizedText)\n=== TRANSLATION ===\n\(vc.translatedText)\n=== END (\(Int(Date().timeIntervalSince(started)))s)")
                    if env["TOLK_IMAGE_DEMO_QUIT"] == "1" { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// Draws the window's content from inside the process (no Screen Recording permission needed).
    static func render(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("[image demo] rendered \(path)")
        } catch { print("[image demo] render failed: \(error)") }
    }

    private static func runOCR(_ path: String) {
        Task { @MainActor in
            do {
                for page in try ImageLoader.pages(from: URL(fileURLWithPath: path)) {
                    let t0 = Date()
                    let r = try await ImageOCR.recognize(page.image)
                    print("=== \(page.name) \(page.image.width)×\(page.image.height), \(r.paragraphs.count) paragraphs, \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
                    print(r.text)
                }
            } catch { print("OCR error: \(error.localizedDescription)") }
            NSApp.terminate(nil)
        }
    }
}
#endif
