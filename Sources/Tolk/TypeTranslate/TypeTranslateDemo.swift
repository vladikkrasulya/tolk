// Debug-only offline render of the «Перевод при наборе» line (no window is ever shown, no screen, no keys):
//
//   TOLK_TYPE_TRANSLATE_SHOT=/some/dir .build/debug/Tolk --background
//
// Writes type-translate-{short,long,error,atcaret}-{light,dark}.png and quits. The geometry is the real one
// (`TypeTranslatePanel.frame`) with a fake screen and a fake chat field.
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum TypeTranslateDemo {
    static func run() {
        guard let dir = ProcessInfo.processInfo.environment["TOLK_TYPE_TRANSLATE_SHOT"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let typed = "Хорошо, отправлю обновлённый счёт сегодня вечером и дам знать"
        let cases: [(name: String, content: TypeTranslateContent, withFrame: Bool)] = [
            ("short", .translation(text: "Okay, I'll send the updated invoice tonight and let you know.", label: TypeTranslate.label(for: .english)), true),
            ("long", .translation(text: "Okay, I will send you the updated invoice this evening, together with the revised delivery schedule, the signed copy of the contract and the list of open questions we discussed on the call yesterday, and I will let you know as soon as everything has been uploaded to the shared folder so that your team can start the review before Friday.",
                                   label: TypeTranslate.label(for: .english)), true),
            ("error", .error(TypeTranslate.selectFailed), true),
            ("atcaret", .translation(text: "Gut, ich schicke die Rechnung heute Abend.", label: TypeTranslate.label(for: .german)), false),
        ]
        for (aname, ap, bg, fg, fieldBG) in [
            ("light", NSAppearance(named: .aqua), NSColor.white, NSColor.black, NSColor(white: 0.93, alpha: 1)),
            ("dark", NSAppearance(named: .darkAqua), NSColor(white: 0.12, alpha: 1), NSColor.white, NSColor(white: 0.2, alpha: 1)),
        ] {
            for c in cases {
                let canvas = NSSize(width: 700, height: 200)
                let screen = NSRect(origin: .zero, size: canvas)
                let field = NSRect(x: 30, y: 110, width: 640, height: 44)
                let caretX = field.minX + 12 + NSAttributedString(string: typed, attributes: [.font: NSFont.systemFont(ofSize: 15)]).size().width
                let caret = NSRect(x: caretX, y: field.minY + 12, width: 1.5, height: 20)
                let frame = TypeTranslatePanel.frame(for: c.content, fieldFrame: c.withFrame ? field : nil, anchor: c.withFrame ? field : caret, screen: screen)
                guard let card = TypeTranslatePanel.image(for: c.content, width: frame.width, appearance: ap) else { continue }
                let img = NSImage(size: canvas)
                img.lockFocus()
                bg.setFill(); NSRect(origin: .zero, size: canvas).fill()
                fieldBG.setFill()
                NSBezierPath(roundedRect: field, xRadius: 8, yRadius: 8).fill()
                NSAttributedString(string: typed, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: fg])
                    .draw(at: NSPoint(x: field.minX + 12, y: field.minY + 12))
                card.draw(in: frame)
                img.unlockFocus()
                if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("type-translate-\(c.name)-\(aname).png")
                    try? png.write(to: url)
                    print("wrote \(url.path) card=\(Int(frame.width))x\(Int(frame.height))")
                }
            }
        }
        NSApp.terminate(nil)
    }
}
#endif
