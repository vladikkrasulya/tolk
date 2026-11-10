// Conversation context for autocomplete: the last ~700 characters of text that is visible in the window
// the user is typing in, WITHOUT the text of the input field itself. Gathered ahead of time (on the first
// keystroke in a field) so a request never waits for it: `context(waitingUpTo:)` returns what is ready
// within a few ms or nil.
//
// 1. Accessibility: walk the window's tree, collect AXStaticText / AXTextArea values that sit above the field.
// 2. If that gives too little (Electron/Qt/custom-drawn UIs), OCR the area above the field: ScreenCaptureKit
//    snapshot + Vision (`ImageOCR`). Needs the Screen Recording permission; it is never requested from here.
// Nothing is written to disk or to the log (only lengths and milliseconds).
import AppKit
import ApplicationServices
import CoreGraphics
import TolkCore

@MainActor
final class ScreenContext {
    enum Source: String { case ax, ocr, none }

    struct Snapshot {
        let key: String
        let text: String
        let source: Source
        let ms: Int
        let at: Date
        /// 32×32 grayscale signature of the OCR'd region: the next snapshot is compared with it (`FrameChange`).
        var signature: FrameChange.Signature?
    }

    nonisolated static let maxChars = 700
    /// Below this many characters the AX result counts as "empty" and OCR is tried.
    static let minAXChars = 80
    /// How often an Accessibility-sourced context is re-read. OCR contexts follow `ContextRefreshPolicy` instead:
    /// the screen is looked at on events (another window, a sent message, scrolling) or every 15 s, and Vision runs
    /// only when the picture changed (autocomplete-eval, «OCR» round: one cycle = ~0.47 s median, it used to run every 4 s).
    static let refreshInterval: TimeInterval = 4
    /// Master switch for the pixel comparison / event logic; false = the old behaviour (OCR every 4 s).
    static var smartRefresh = true
    private static let probeInterval: TimeInterval = 1

    /// False while the model server is not ready: no point reading the screen for suggestions that cannot be made.
    /// Set by AppDelegate from the server state.
    static var serverReady = false
    /// OCR of a screen snapshot (setting «Контекст со снимка экрана» and the battery profile). AX text is always used.
    static var ocrAllowed = true

    private(set) var snapshot: Snapshot?
    private var inflight: Task<Void, Never>?
    private var lastProbe = Date.distantPast
    private var lastScroll: Date?
    private var lastFieldLength: Int?
    private var scrollMonitor: Any?

    init() {
        // Mouse wheel / trackpad scrolling anywhere: the visible conversation may have moved. (No permission needed.)
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastScroll = Date() }
        }
    }
    /// Last context returned from the request path; kept so that an unchanged screen yields byte-identical
    /// text (stable prompt prefix, llama-server KV cache is reused).
    var onUpdate: ((Source, Int, Int) -> Void)?

    /// Call on every keystroke: cheap, returns at once. Starts a background refresh when the cache is stale.
    func prepare(pid: pid_t) {
        guard Self.serverReady else { return }
        if inflight != nil { return }
        let now = Date()
        guard now.timeIntervalSince(lastProbe) >= Self.probeInterval else { return }
        lastProbe = now
        let cached = snapshot
        inflight = Task { [weak self] in
            let t0 = Date()
            let target = await Task.detached(priority: .utility) { Target.read(pid: pid) }.value
            guard let target else { self?.inflight = nil; return }
            guard let self else { return }
            let same = cached.map { $0.key == target.key } ?? false
            let event = self.event(cached: same ? cached : nil, target: target)
            self.lastFieldLength = target.fieldLength
            if let c = cached, same {
                let due: Bool
                if c.source == .ocr, Self.smartRefresh {
                    due = ContextRefreshPolicy.mayCheck(now: Date(), lastCheck: c.at, event: event)
                } else {
                    due = Date().timeIntervalSince(c.at) >= Self.refreshInterval
                }
                if !due { self.inflight = nil; return }
            }
            let (text, source, signature, unchanged) = await Self.collect(target, previous: same ? cached : nil)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            self.snapshot = Snapshot(key: target.key, text: text, source: source, ms: ms, at: Date(), signature: signature)
            self.inflight = nil
            if unchanged { Diagnostics.log("autocomplete: context screen unchanged, OCR skipped ms=\(ms)") }
            self.onUpdate?(source, text.count, ms)
        }
    }

    /// What happened since the last look at this window: a sent message (the field was emptied) or scrolling.
    private func event(cached: Snapshot?, target: Target) -> ContextRefreshPolicy.Event {
        guard let c = cached else { return .windowChanged }
        if let before = lastFieldLength, let now = target.fieldLength, before >= 4, now <= 2 { return .sent }
        if let s = lastScroll, s > c.at, Date().timeIntervalSince(s) >= 0.6 { return .scrolled }
        return .none
    }

    /// Context for the current field if it is ready (or becomes ready within `limit`); nil otherwise.
    func context(forPID pid: pid_t, waitingUpTo limit: Duration = .milliseconds(50)) async -> String? {
        let deadline = ContinuousClock.now + limit
        while inflight != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let s = snapshot, s.key.hasPrefix("\(pid)|"), !s.text.isEmpty else { return nil }
        return s.text
    }

    func reset() {
        inflight?.cancel()
        inflight = nil
        snapshot = nil
        lastProbe = .distantPast
    }

    // MARK: - Target (focused field + its window), all in AX coordinates (top-left origin)

    struct Target: @unchecked Sendable {
        let key: String
        let window: AXUIElement
        let focused: AXUIElement
        /// Characters in the input field (nil: the app does not expose its value).
        let fieldLength: Int?
        let windowFrame: CGRect
        let fieldFrame: CGRect

        static func read(pid: pid_t) -> Target? {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.15)
            guard let focused: AXUIElement = AX.attr(system, kAXFocusedUIElementAttribute) else { return nil }
            AXUIElementSetMessagingTimeout(focused, 0.15)
            var elPID: pid_t = 0
            AXUIElementGetPid(focused, &elPID)
            guard elPID == pid else { return nil }
            guard let window: AXUIElement = AX.attr(focused, kAXWindowAttribute) else { return nil }
            AXUIElementSetMessagingTimeout(window, 0.15)
            guard let wf = AX.frame(window), let ff = AX.frame(focused), wf.width > 100, wf.height > 100 else { return nil }
            let title: String = AX.attr(window, kAXTitleAttribute) ?? ""
            // Key: window + field identity. The title is hashed (chat switch in Telegram changes it), never stored as text.
            let key = "\(pid)|\(CFHash(window))|\(CFHash(focused))|\(title.hashValue)"
            let value: String? = AX.attr(focused, kAXValueAttribute)
            return Target(key: key, window: window, focused: focused, fieldLength: value?.count, windowFrame: wf, fieldFrame: ff)
        }
    }

    // MARK: - Collecting

    /// `unchanged`: the screen looked the same as at the last OCR, so `previous.text` is returned as it was.
    private static func collect(_ t: Target, previous: Snapshot?) async -> (text: String, source: Source, signature: FrameChange.Signature?, unchanged: Bool) {
        let ax = await Task.detached(priority: .utility) { axText(t) }.value
        if ax.count >= minAXChars { return (ax, .ax, nil, false) }
        guard ocrAllowed, CGPreflightScreenCaptureAccess() else { return (ax, ax.isEmpty ? .none : .ax, nil, false) }
        let prev = (smartRefresh && previous?.source == .ocr) ? previous : nil
        let r = await ocrText(t, previous: prev)
        if r.text.count > ax.count { return (r.text, .ocr, r.signature, r.unchanged) }
        return (ax, ax.isEmpty ? .none : .ax, nil, false)
    }

    // MARK: Accessibility

    nonisolated private static func axText(_ t: Target) -> String {
        struct Item { var y: CGFloat; var x: CGFloat; var text: String }
        var items: [Item] = []
        var visited = 0
        let maxDepth = 14, maxElements = 600
        let deadline = Date().addingTimeInterval(0.3)
        let field = t.fieldFrame
        let focusedHash = CFHash(t.focused)

        func walk(_ el: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visited < maxElements, Date() < deadline else { return }
            visited += 1
            if CFHash(el) == focusedHash { return }
            let role: String = AX.attr(el, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String {
                if let f = AX.frame(el), f.maxY <= field.minY + 4, f.width > 0 {
                    let overlap = min(f.maxX, field.maxX) - max(f.minX, field.minX)
                    // Same column as the input (skips chat lists / sidebars next to the conversation).
                    if overlap > 0.3 * min(f.width, field.width) {
                        let s: String = AX.attr(el, kAXValueAttribute) ?? AX.attr(el, kAXTitleAttribute) ?? ""
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.count >= 2 { items.append(Item(y: f.minY, x: f.minX, text: trimmed)) }
                    }
                }
                if role == kAXStaticTextRole as String { return }
            }
            guard let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) else { return }
            for k in kids {
                if visited >= maxElements || Date() >= deadline { return }
                walk(k, depth: depth + 1)
            }
        }
        walk(t.window, depth: 0)
        items.sort { ($0.y, $0.x) < ($1.y, $1.x) }
        return tail(items.map(\.text))
    }

    // MARK: OCR

    private static func ocrText(_ t: Target, previous: Snapshot?) async -> (text: String, signature: FrameChange.Signature?, unchanged: Bool) {
        let w = t.windowFrame, f = t.fieldFrame
        // The window area above the input field, in the field's column.
        var x0 = max(w.minX, f.minX - 8), x1 = min(w.maxX, f.maxX + 8)
        if x1 - x0 < 250 { x0 = w.minX; x1 = w.maxX }
        let y0 = w.minY, y1 = min(w.maxY, f.minY)
        guard y1 - y0 > 80, x1 - x0 > 120 else { return ("", nil, false) }
        let axRect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        guard let mainH = NSScreen.screens.first?.frame.height else { return ("", nil, false) }
        let cocoa = NSRect(x: axRect.minX, y: mainH - axRect.maxY, width: axRect.width, height: axRect.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoa) }) else { return ("", nil, false) }
        let clipped = cocoa.intersection(screen.frame)
        guard let image = try? await ScreenCaptureController.snapshot(clipped, on: screen) else { return ("", nil, false) }
        // Same picture as at the last OCR (the region excludes the input field, so typing does not change it)?
        let sig = smartRefresh ? await Task.detached(priority: .utility) { ScreenContext.signature(of: image) }.value : nil
        if let sig, let prev = previous, let old = prev.signature, !FrameChange.isChanged(old: old, new: sig) {
            return (prev.text, sig, true)
        }
        guard let result = try? await ImageOCR.recognize(image) else { return ("", nil, false) }
        // Paragraphs come in reading order, top to bottom; the newest messages are at the bottom.
        let lines = result.paragraphs.map(\.text)
        return (tail(lines), sig, false)
    }

    /// 128×128 grayscale redraw of the snapshot → 32×32 signature (`FrameChange`). ~0.1 ms.
    nonisolated private static func signature(of image: CGImage) -> FrameChange.Signature? {
        let side = 128
        var px = [UInt8](repeating: 0, count: side * side)
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            c.interpolationQuality = .high
            c.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok, let sig = FrameChange.signature(luma: px, width: side, height: side) else { return nil }
        // Keep the region's real size in the signature: another size (the field grew) counts as a change.
        return FrameChange.Signature(cells: sig.cells, width: image.width, height: image.height)
    }

    // MARK: Text cleanup

    /// Last `maxChars` characters, cut on a line boundary, consecutive duplicates removed.
    nonisolated static func tail(_ pieces: [String]) -> String {
        var lines: [String] = []
        for p in pieces {
            for l in p.split(whereSeparator: \.isNewline) {
                let s = l.trimmingCharacters(in: .whitespaces)
                if s.count >= 2, s != lines.last { lines.append(s) }
            }
        }
        var out: [String] = []
        var total = 0
        for l in lines.reversed() {
            if total + l.count + 1 > maxChars {
                if out.isEmpty { out.append(String(l.suffix(maxChars))) }
                break
            }
            out.append(l)
            total += l.count + 1
        }
        return out.reversed().joined(separator: "\n")
    }
}

private enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        if let v: AXValue = attr(el, "AXFrame") {
            var r = CGRect.zero
            if AXValueGetValue(v, .cgRect, &r) { return r }
        }
        guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
