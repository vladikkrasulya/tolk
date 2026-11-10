// Debug-only check that the whole-text read works on a TextEdit-like field: NSTextView inside NSScrollView.
// AX does not describe a process to itself, so two runs of this binary talk to each other:
//
//   TOLK_AX_PROBE=host .build/debug/Tolk --background          prints its pid; shows (invisibly) four text views, waits 20 s
//   TOLK_AX_PROBE=read:<pid> .build/debug/Tolk --background    reads them with TypeTranslateField.wholeText; exit 0 = all match
//
// The host window is a non-activating panel, alpha 0, 30000 pt off screen: nothing appears and no focus moves.
#if DEBUG
import AppKit
import ApplicationServices

@MainActor
enum AXReadProbe {
    private static var keepAlive: [AnyObject] = []

    static let samples: [(String, String)] = [
        ("plain", "Привет, как дела? Это проверка поля."),
        ("multiline", "Первая строка.\nВторая строка.\n\nТретий абзац с текстом."),
        ("rich", "Жирный и обычный текст"),
        ("empty", ""),
    ]

    static func run(_ mode: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        if mode == "host" { host() } else if mode.hasPrefix("read:"), let pid = pid_t(mode.dropFirst(5)) { Task { @MainActor in read(pid) } }
        else { print("[ax-probe] usage: TOLK_AX_PROBE=host | read:<pid>"); exit(2) }
    }

    private static func host() {
        var views: [NSView] = []
        for (i, (_, text)) in samples.enumerated() {
            let scroll = NSTextView.scrollableTextView()
            let tv = scroll.documentView as! NSTextView
            tv.isRichText = true
            if i == 2 {
                let a = NSMutableAttributedString(string: "Жирный ", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
                a.append(NSAttributedString(string: "и обычный текст", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                tv.textStorage?.setAttributedString(a)
            } else { tv.string = text }
            scroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
            views.append(scroll)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        let win = NSPanel(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.contentView = stack
        win.orderFrontRegardless()
        keepAlive = [win, stack]
        print("[ax-probe] host pid=\(getpid())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
    }

    private static func read(_ pid: pid_t) {
        print("[ax-probe] trusted=\(AXIsProcessTrusted())")
        var areas: [AXUIElement] = []
        collect(AXUIElementCreateApplication(pid), 0, &areas)
        print("[ax-probe] text areas found: \(areas.count)")
        var failures = areas.count == samples.count ? 0 : 1
        // The stack lists them top to bottom; AX order is the same.
        for (el, (name, want)) in zip(areas, samples) {
            let got = TypeTranslateField.wholeText(el, budget: 0.2)
            let ok = got == want
            print("[ax-probe] \(name): \(ok ? "ok" : "FAIL") len=\(got?.count ?? -1)/\(want.count) \(TypeTranslateField.diagnose(el))")
            if !ok { failures += 1 }
        }
        print("[ax-probe] failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func collect(_ el: AXUIElement, _ depth: Int, _ out: inout [AXUIElement]) {
        if depth > 10 { return }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXTextAreaRole as String { out.append(el); return }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] else { return }
        for k in arr { collect(k, depth + 1, &out) }
    }
}
#endif
