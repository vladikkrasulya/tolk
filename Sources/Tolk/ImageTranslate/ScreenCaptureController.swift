// Global hotkey -> area selection overlay -> ScreenCaptureKit snapshot -> OCR.
import AppKit
import Carbon.HIToolbox
import ImageIO
import ScreenCaptureKit
import TolkCore

/// Global hotkey (default ⌥⇧S) -> the user selects a screen area -> OCR -> `onText(text, point)`.
/// `point` is the bottom-left corner of the selection in global screen coordinates — the popup opens under it.
@MainActor
final class ScreenCaptureController {
    var onText: ((_ text: String, _ point: NSPoint) -> Void)?
    /// When set, the hotkey calls this instead of `captureNow()` — lets the app route the capture
    /// (main window open → image page, otherwise → popup).
    var onHotKey: (() -> Void)?

    /// Carbon virtual key code and modifiers (`optionKey | shiftKey` …).
    private let keyCode = UInt32(kVK_ANSI_S)
    private let modifiers = UInt32(optionKey | shiftKey)
    private var hotKey: GlobalHotKey?
    private var overlay: SelectionOverlay?

    nonisolated init() {}

    /// Registers the global hotkey; returns false if registration failed (e.g. taken by another app).
    @discardableResult func start() -> Bool {
        ImageOCR.warmUp()
        // An unbundled dev build (`swift run`, .build/debug/Tolk) next to the installed app would register the
        // same ⌥⇧S: both processes show a selection overlay, steal activation from each other, and both
        // overlays cancel themselves ("app-resigned-active") — the capture silently does nothing.
        if Bundle.main.bundleIdentifier == nil, ProcessInfo.processInfo.environment["TOLK_DEV_HOTKEY"] == nil {
            Diagnostics.log("capture: dev build — global hotkey not registered (set TOLK_DEV_HOTKEY=1 to force)")
            return false
        }
        hotKey = GlobalHotKey(keyCode: keyCode, modifiers: modifiers) { [weak self] in self?.hotKeyPressed() }
        Diagnostics.log("capture: hotkey \(hotKeyDisplay) registered=\(hotKey != nil)")
        return hotKey != nil
    }

    private func hotKeyPressed() {
        Diagnostics.log("capture: hotkey pressed")
        if let onHotKey { onHotKey() } else { captureNow() }
    }

    /// "⌥⇧S" — for menus and hints.
    var hotKeyDisplay: String { GlobalHotKey.display(keyCode: keyCode, modifiers: modifiers) }

    /// Starts an area selection immediately (menu item / hotkey): OCR result goes to `onText`.
    func captureNow() {
        selectImage(route: .popup) { [weak self] image, rect, _ in
            guard let self, let image else { return }
            let point = NSPoint(x: rect.minX + 24, y: rect.minY)
            Task { @MainActor in
                let text = await Self.recognizeLogged(image)
                if text.isEmpty {
                    Diagnostics.log("capture: no text found")
                    Toast.show("Текст не найден", near: NSPoint(x: rect.midX, y: rect.midY))
                } else {
                    Diagnostics.log("capture: popup shown")
                    self.onText?(text, point)
                }
            }
        }
    }

    /// OCR with a log line (length and time only — never the text itself).
    static func recognizeLogged(_ image: CGImage) async -> String {
        let t0 = Date()
        var result = OCRResult.empty
        do { result = try await ImageOCR.recognize(image) }
        catch { Diagnostics.log("capture: ocr FAILED \(error) px=\(image.width)x\(image.height)") }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Diagnostics.log("capture: ocr chars=\(text.count) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        return text
    }

    /// Debug: `TOLK_TEST_CAPTURE=x,y,w,h` (global coords, bottom-left origin) runs snapshot → OCR → popup without the overlay.
    func runTestCapture(_ spec: String) {
        let n = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4 else { Diagnostics.log("test-capture: bad spec"); return }
        let rect = NSRect(x: n[0], y: n[1], width: n[2], height: n[3])
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else {
            Diagnostics.log("test-capture: no screen for rect=\(rect)"); return
        }
        Diagnostics.log("test-capture: start rect=\(rect) screen=\(screen.frame)")
        Task { @MainActor in
            do {
                let image = try await Self.snapshot(rect, on: screen)
                Diagnostics.log("test-capture: snapshot px=\(image.width)x\(image.height)")
                if let dir = ProcessInfo.processInfo.environment["TOLK_TEST_CAPTURE_DUMP"],
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
                }
                let text = await Self.recognizeLogged(image)
                if text.isEmpty { Diagnostics.log("capture: no text found") }
                else { Diagnostics.log("capture: popup shown"); self.onText?(text, NSPoint(x: rect.minX + 24, y: rect.minY)) }
            } catch {
                Diagnostics.log("capture: snapshot failed \(error)")
            }
        }
    }

    /// Lets the user select an area and returns its picture (nil = cancelled / no permission / failed).
    /// `rect` is the selection in global screen coordinates (bottom-left origin).
    /// `route` decides who gets the focus when the overlay closes (see `CaptureFocus`); `end` tells how it ended.
    func selectImage(route: CaptureRoute, _ completion: @escaping (_ image: CGImage?, _ rect: NSRect, _ end: CaptureEnd) -> Void) {
        guard overlay == nil else { return }
        guard Self.ensurePermission() else { completion(nil, .zero, .cancelled); return }
        let overlay = SelectionOverlay()
        self.overlay = overlay
        overlay.run(route: route) { [weak self] screen, rect, reason, end in
            self?.overlay = nil
            guard let screen, rect.width >= 6, rect.height >= 6 else {
                Diagnostics.log("capture: selection cancelled reason=\(reason)")
                completion(nil, .zero, end == .selected ? .cancelled : end); return
            }
            Diagnostics.log("capture: selection screen=\(Int(screen.frame.minX)),\(Int(screen.frame.minY)) rect=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))")
            Task { @MainActor in
                do {
                    let img = try await Self.snapshot(rect, on: screen)
                    Diagnostics.log("capture: snapshot ok px=\(img.width)x\(img.height)")
                    completion(img, rect, .selected)
                } catch {
                    Diagnostics.log("capture: snapshot failed \(error)")
                    Toast.show("Не удалось снять экран", near: NSPoint(x: rect.midX, y: rect.midY))
                    NSLog("Tolk: screen capture failed: \(error)")
                    completion(nil, rect, .cancelled)
                }
            }
        }
    }

    // MARK: - Permission

    /// Returns true if Screen Recording is allowed. Otherwise asks the system once and explains in Russian.
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // First call shows the system dialog and adds Tolk to the list in System Settings.
        if CGRequestScreenCaptureAccess() { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Нужно разрешение «Запись экрана»"
        alert.informativeText = """
        Чтобы распознать текст в выделенной области, Tolk должен видеть содержимое экрана. \
        Снимок обрабатывается только на этом Mac и никуда не отправляется.

        Откройте «Системные настройки → Конфиденциальность и безопасность → Запись экрана», \
        включите Tolk и перезапустите приложение.
        """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
        return false
    }

    static func openSettings() {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    // MARK: - Snapshot

    /// Captures `rect` (global coords) of `screen` with ScreenCaptureKit, without Tolk's own windows.
    static func snapshot(_ rect: NSRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw NSError(domain: "Tolk", code: 1, userInfo: [NSLocalizedDescriptionKey: "Нет экрана для снимка"])
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        // Display-local points, top-left origin.
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        config.sourceRect = local
        // At least 2x: small UI text on non-Retina screens recognizes much better upscaled.
        let scale = max(screen.backingScaleFactor, 2)
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        config.showsCursor = false
        config.scalesToFit = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

// MARK: - Global hotkey (Carbon; needs no Accessibility permission)

@MainActor
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?
    nonisolated static let signature = OSType(0x544F_4C4B) // 'TOLK'

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        let id = self.id
        MainActor.assumeIsolated { _ = Self.handlers.removeValue(forKey: id) }
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            // Other hotkeys of this app (quick actions, 'TlkQ') are not ours — let their handler run.
            guard hk.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    nonisolated static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
        ]
        return s + (letters[Int(keyCode)] ?? "#\(keyCode)")
    }
}

// MARK: - Selection overlay

/// Dimmed full-screen windows on every display; drag selects a rectangle, Esc / right click cancels.
@MainActor
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var completion: ((NSScreen?, NSRect, String, CaptureEnd) -> Void)?
    private var route: CaptureRoute = .popup
    private var keyMonitor: Any?
    private var resignObserver: Any?
    private var previousApp: NSRunningApplication?
    private var shownAt = Date()

    func run(route: CaptureRoute, _ completion: @escaping (NSScreen?, NSRect, String, CaptureEnd) -> Void) {
        self.completion = completion
        self.route = route
        previousApp = NSWorkspace.shared.frontmostApplication
        shownAt = Date()
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.showsHint = screen == (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)
            view.onFinish = { [weak self, weak w] local in
                guard let self, let w else { return }
                let global = local.map { $0.offsetBy(dx: w.frame.minX, dy: w.frame.minY) }
                self.finish(screen: global == nil ? nil : screen, rect: global ?? .zero, reason: global == nil ? "view-cancel(esc/right-click/too-small)" : "selected",
                            end: global == nil ? .cancelled : .selected)
            }
            w.contentView = view
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        let mouseWindow = windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first
        mouseWindow?.makeKey()
        NSCursor.crosshair.push()
        Diagnostics.log("capture: overlay shown screens=\(windows.count) active=\(NSApp.isActive) key=\(mouseWindow?.isKeyWindow ?? false)")

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == UInt16(kVK_Escape) { self?.finish(screen: nil, rect: .zero, reason: "esc", end: .cancelled); return nil }
            return e
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(screen: nil, rect: .zero, reason: "app-resigned-active front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") dt=\(Int(Date().timeIntervalSince(self?.shownAt ?? Date()) * 1000))ms", end: .appSwitched) }
        }
    }

    private func finish(screen: NSScreen?, rect: NSRect, reason: String, end: CaptureEnd) {
        guard let completion else { return }
        self.completion = nil
        NSCursor.pop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil; resignObserver = nil
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        // Focus: popup → back to the app the user was reading; big window → stays with Tolk (the caller
        // brings the window back); the user switched apps themselves → leave them where they went.
        if CaptureFocus.target(route: route, end: end) == .previousApp,
           let prev = previousApp, prev != NSRunningApplication.current {
            prev.activate()
        }
        completion(screen, rect, reason, end)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    var showsHint = false
    private var start: NSPoint?
    private var current: NSPoint?

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y)).integral
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        Diagnostics.log("capture: overlay mouseDown at=\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) global=\(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y)) activeApp=\(NSApp.isActive)")
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    private var dragCount = 0
    override func mouseDragged(with event: NSEvent) {
        dragCount += 1
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let sel = selection
        Diagnostics.log("capture: overlay mouseUp at=\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) global=\(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y))")
        Diagnostics.log("capture: overlay mouseUp drags=\(dragCount) sel=\(sel.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil") window=\(window.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY))" } ?? "-")")
        dragCount = 0
        start = nil; current = nil
        onFinish?(sel.flatMap { $0.width >= 6 && $0.height >= 6 ? $0 : nil })
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        if let sel = selection {
            NSColor.clear.setFill()
            sel.fill(using: .copy)
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let path = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1
            path.stroke()
            let size = "\(Int(sel.width)) × \(Int(sel.height))"
            drawPill(size, at: NSPoint(x: sel.maxX, y: sel.minY - 8), alignRight: true, small: true)
        } else if showsHint {
            drawPill("Выделите область с текстом  ·  \(EscText.cancelHint)",
                     at: NSPoint(x: bounds.midX, y: bounds.maxY - 90), alignRight: false, small: false)
        }
    }

    private func drawPill(_ text: String, at p: NSPoint, alignRight: Bool, small: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: small ? 11 : 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let ts = s.size()
        let pad: CGFloat = small ? 6 : 14
        let w = ts.width + pad * 2, h = ts.height + (small ? 6 : 14)
        var x = alignRight ? p.x - w : p.x - w / 2
        var y = p.y - h
        x = min(max(x, 4), bounds.maxX - w - 4)
        if y < 4 { y = p.y + 16 }
        let r = NSRect(x: x, y: y, width: w, height: h)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        s.draw(at: NSPoint(x: r.minX + pad, y: r.minY + (h - ts.height) / 2))
    }
}

// MARK: - Toast

/// Short HUD message that fades out by itself ("Текст не найден").
@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, near point: NSPoint, duration: TimeInterval = 1.6) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        let size = label.fittingSize
        let frame = NSRect(x: point.x - size.width / 2 - 16, y: point.y - size.height / 2 - 9,
                           width: size.width + 32, height: size.height + 18)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = frame.height / 2
        fx.layer?.masksToBounds = true
        label.frame = NSRect(x: 16, y: 9, width: size.width, height: size.height)
        fx.addSubview(label)
        p.contentView = fx
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    p.orderOut(nil)
                    if panel === p { panel = nil }
                }
            }
        }
    }
}
