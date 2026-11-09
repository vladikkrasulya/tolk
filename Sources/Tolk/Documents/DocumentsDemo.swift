// Owned by the "documents" helper. Debug-only hooks for the «Документы» page (no AppDelegate wiring needed:
// DocumentsViewController.init calls `runIfRequested` once).
//
//   TOLK_DOCS_EXTRACT=/a.pdf:/b.docx .build/debug/Tolk --background   — print extracted paragraphs and quit
//   TOLK_DOCS_DEMO=empty|/path/doc.docx                                 — open the page in its own window
//   TOLK_DOCS_TRANSLATE=1  TOLK_DOCS_TARGET=en                          — translate after loading
//   TOLK_DOCS_EXPORT=/out.docx  TOLK_DOCS_BILINGUAL=1                   — export when the translation finishes
//   TOLK_DOCS_RENDER=/dir                                               — PNGs (light + dark) of the page, then quit
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum DocumentsDemo {
    private static var started = false
    private static var keepAlive: [AnyObject] = []

    static func runIfRequested(engine: TranslationEngine) {
        guard !started else { return }
        let env = ProcessInfo.processInfo.environment
        if let raw = env["TOLK_DOCS_EXTRACT"], !raw.isEmpty {
            started = true
            Task { @MainActor in
                for path in raw.split(separator: ":").map(String.init) { await printExtraction(path) }
                exit(0)
            }
            return
        }
        guard let raw = env["TOLK_DOCS_DEMO"], !raw.isEmpty else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { run(raw, env: env, engine: engine) }
    }

    private static func printExtraction(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        let t0 = Date()
        do {
            let doc = try await DocumentExtractor.extract(url) { page, total, ocr in
                if ocr { print("  … OCR page \(page)/\(total)") }
            }
            print("=== \(doc.name): kind=\(doc.kind) pages=\(doc.pageCount.map(String.init) ?? "-") ocrPages=\(doc.ocrPages) "
                  + "paragraphs=\(doc.paragraphs.count) chars=\(doc.characterCount) lang=\(doc.dominantLanguage?.rawValue ?? "?") "
                  + "(\(String(format: "%.2f", Date().timeIntervalSince(t0))) s)")
            for (i, p) in doc.paragraphs.prefix(12).enumerated() {
                let s = p.style
                let style = "h\(s.headingLevel)\(s.bold ? " bold" : "")\(s.italic ? " italic" : "")"
                    + (s.fontSize.map { " \(Int($0))pt" } ?? "") + (s.fontFamily.map { " \($0)" } ?? "")
                    + (p.page.map { " p\($0)" } ?? "") + (p.translatable ? "" : " KEEP")
                let text = p.fullText.replacingOccurrences(of: "\n", with: "⏎").prefix(90)
                print("  [\(i)] (\(style)) \(text)")
            }
        } catch {
            print("=== \(url.lastPathComponent): ERROR \(error.localizedDescription)")
        }
    }

    private static func run(_ raw: String, env: [String: String], engine: TranslationEngine) {
        if let t = env["TOLK_DOCS_TARGET"] { UserDefaults.standard.set(t, forKey: "tolk.docs.target") }
        let vc = DocumentsViewController(engine: engine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Документы — демо"
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.orderFrontRegardless()
        keepAlive = [vc, window]

        let renderDir = env["TOLK_DOCS_RENDER"]
        func render(_ name: String) {
            guard let dir = renderDir else { return }
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                vc.renderForReview(to: "\(dir)/docs-\(name)-\(look).png")
            }
            window.appearance = nil
            print("rendered \(name)")
        }

        if raw == "empty" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { render("empty"); if renderDir != nil { exit(0) } }
            return
        }
        vc.open(url: URL(fileURLWithPath: raw))
        let translate = env["TOLK_DOCS_TRANSLATE"] == "1"
        let started = Date()
        var phase = 0 // 0 loading, 1 loaded, 2 translating
        var progressShot = false
        var pauseTested = env["TOLK_DOCS_PAUSE_TEST"] != "1"
        var resumeAt: Date?
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            MainActor.assumeIsolated {
                if Date().timeIntervalSince(started) > 900 { print("timeout"); exit(1) }
                switch phase {
                case 0:
                    guard !vc.isBusy else { return }
                    guard vc.extracted != nil else { print("load failed"); exit(1) }
                    phase = 1
                    render("loaded")
                    if translate { phase = 2; vc.startTranslation() } else { timer.invalidate(); if renderDir != nil { exit(0) } }
                case 2:
                    if let at = resumeAt {
                        guard Date() >= at else { return }
                        resumeAt = nil
                        print("paused: \(vc.debugProgressText); kept \(vc.translationPairs.count) paragraphs -> resume")
                        vc.debugTogglePause()
                        return
                    }
                    if !pauseTested, vc.translationPairs.count >= 3 {
                        pauseTested = true
                        vc.debugTogglePause()
                        resumeAt = Date().addingTimeInterval(2)
                        render("paused")
                        return
                    }
                    if vc.isBusy {
                        if !progressShot, vc.translationPairs.count >= 2 { progressShot = true; render("progress") }
                        return
                    }
                    timer.invalidate()
                    print("=== TRANSLATION (\(Int(Date().timeIntervalSince(started))) s)")
                    for (p, t) in vc.translationPairs { print("  · \(p.fullText.prefix(80))\n    → \(t)") }
                    render("done")
                    if let out = env["TOLK_DOCS_EXPORT"] {
                        let url = URL(fileURLWithPath: out)
                        let format = DocumentExportFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() } ?? .docx
                        vc.export(to: url, format: format, bilingual: env["TOLK_DOCS_BILINGUAL"] == "1") { error in
                            print(error.map { "export failed: \($0)" } ?? "exported \(out)")
                            exit(error == nil ? 0 : 1)
                        }
                    } else if renderDir != nil {
                        exit(0)
                    }
                default: break
                }
            }
        }
    }
}
#endif
