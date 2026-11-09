// The text field the user is typing in, read through the Accessibility API:
// text before the caret, what follows on the same line, and where the caret is on screen.
import AppKit
import ApplicationServices

struct FocusedField {
    let pid: pid_t
    let bundleID: String?
    /// Up to `contextLimit` characters before the caret.
    let textBefore: String
    /// Rest of the caret's line (suggestions are shown only at the end of a line).
    let restOfLine: String
    /// Caret rectangle in Cocoa screen coordinates (origin bottom-left of the main screen).
    let caret: NSRect
    /// Which AX query produced the caret and the raw rectangle (AX coordinates), for diagnostics only.
    let caretInfo: String
    /// Real font size (points) of the character before the caret, when the app reports it.
    var fontSize: CGFloat? = nil
    /// Right edge (Cocoa x) the ghost text must not cross: the field's, else the window's.
    var rightLimit: CGFloat? = nil

    static let contextLimit = 1500

    /// nil when nothing editable is focused, it is a password field, text is selected,
    /// or the app does not report the caret position. Every refusal is logged (rate-limited, no user text).
    static func read() -> FocusedField? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        switch readFocused(app) {
        case .success(let f): return f
        case .failure(let why):
            logFailure(app.bundleIdentifier ?? "pid\(app.processIdentifier)", why.reason)
            return nil
        }
    }

    private struct Refusal: Error { let reason: String }

    private static var lastFailureLog: [String: TimeInterval] = [:]
    private static func logFailure(_ app: String, _ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastFailureLog[app], now - last < 2 { return }
        lastFailureLog[app] = now
        Diagnostics.log("autocomplete: read refused app=\(app) \(reason)")
    }

    private static let editableMarkers = ["AXEditable", "AXEditableAncestor", "AXHighestEditableAncestor"]

    private static func readFocused(_ app: NSRunningApplication) -> Result<FocusedField, Refusal> {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        // Electron/Chromium often fail the system-wide query but answer on the app element.
        var el: AXUIElement? = attr(system, kAXFocusedUIElementAttribute)
        var via = "system"
        if el == nil {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.15)
            el = attr(appEl, kAXFocusedUIElementAttribute)
            via = "app"
        }
        guard let el else { return .failure(Refusal(reason: "step=no-focused-element")) }
        AXUIElementSetMessagingTimeout(el, 0.15)

        let role: String = attr(el, kAXRoleAttribute) ?? ""
        let sub: String = attr(el, kAXSubroleAttribute) ?? ""
        if sub == kAXSecureTextFieldSubrole as String { return .failure(Refusal(reason: "step=secure-field")) }

        var names: CFArray?
        AXUIElementCopyAttributeNames(el, &names)
        let attrNames = (names as? [String]) ?? []
        let hasRange = attrNames.contains(kAXSelectedTextRangeAttribute as String)
        let hasMarkers = attrNames.contains("AXSelectedTextMarkerRange")
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]
        var editable = settable.boolValue || textRoles.contains(role)
        if !editable {
            for k in editableMarkers where attrNames.contains(k) {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success, let v {
                    if let b = v as? Bool { editable = editable || b } else { editable = true }
                }
            }
        }
        let info = "role=\(role) sub=\(sub) via=\(via) settable=\(settable.boolValue) range=\(hasRange) markers=\(hasMarkers) editable=\(editable)"
        guard editable else { return .failure(Refusal(reason: "step=not-editable \(info)")) }

        // 1) Classic CFRange attributes.
        if hasRange {
            switch readByRange(el) {
            case .success(let r): return .success(make(app, r, el))
            case .failure(let why):
                if !hasMarkers { return .failure(Refusal(reason: "step=\(why.reason) \(info)")) }
            }
        }
        // 2) Text markers (Chromium/WebKit when CFRange is not supported).
        if hasMarkers {
            switch readByMarkers(el) {
            case .success(let r): return .success(make(app, r, el))
            case .failure(let why): return .failure(Refusal(reason: "step=markers:\(why.reason) \(info)"))
            }
        }
        return .failure(Refusal(reason: "step=no-selection-attrs \(info)"))
    }

    private struct Raw { let before: String; let after: String; let caret: NSRect; let caretInfo: String; var fontSize: CGFloat? = nil }

    /// AX frame (origin top-left of the main screen) → Cocoa frame.
    private static func axFrame(_ el: AXUIElement) -> NSRect? {
        guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute),
              let mainH = NSScreen.screens.first?.frame.height else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &sz), sz.width > 0, sz.height > 0 else { return nil }
        return NSRect(x: p.x, y: mainH - p.y - sz.height, width: sz.width, height: sz.height)
    }

    /// Right edge of the field if it reports a sensible size around the caret, else of its window.
    private static func rightLimit(_ el: AXUIElement, caret: NSRect) -> CGFloat? {
        if let f = axFrame(el), f.width > 40, f.minX - 2 <= caret.minX, f.maxX > caret.minX { return f.maxX }
        if let w: AXUIElement = attr(el, kAXWindowAttribute), let f = axFrame(w), f.maxX > caret.minX { return f.maxX }
        return nil
    }

    private static func make(_ app: NSRunningApplication, _ r: Raw, _ el: AXUIElement) -> FocusedField {
        let rest = String(r.after.prefix { $0 != "\n" && $0 != "\r" })
        return FocusedField(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                            textBefore: r.before, restOfLine: rest, caret: r.caret, caretInfo: r.caretInfo, fontSize: r.fontSize,
                            rightLimit: rightLimit(el, caret: r.caret))
    }

    private static func readByRange(_ el: AXUIElement) -> Result<Raw, Refusal> {
        guard let rangeValue: AXValue = attr(el, kAXSelectedTextRangeAttribute) else { return .failure(Refusal(reason: "no-selected-range")) }
        var sel = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &sel), sel.location >= 0 else { return .failure(Refusal(reason: "bad-range")) }
        guard sel.length == 0 else { return .failure(Refusal(reason: "text-selected")) }
        let caretIndex = sel.location

        // Only the tail before the caret and a little after it — documents can be huge.
        let start = max(0, caretIndex - contextLimit)
        guard let before = string(el, CFRange(location: start, length: caretIndex - start)) else { return .failure(Refusal(reason: "no-text")) }
        let after = string(el, CFRange(location: caretIndex, length: 200), clamp: true) ?? ""

        let afterNewline = before.last?.isNewline ?? false
        guard let (rect, info) = caretRect(
            prev: caretIndex > 0 && !afterNewline ? bounds(el, CFRange(location: caretIndex - 1, length: 1)) : nil,
            zero: bounds(el, CFRange(location: caretIndex, length: 0))
        ) else { return .failure(Refusal(reason: "no-rect")) }
        var fs: CGFloat?
        if caretIndex > 0, !afterNewline,
           let a: NSAttributedString = param(el, "AXAttributedStringForRange", axRange(CFRange(location: caretIndex - 1, length: 1))) {
            fs = fontSize(a)
        }
        return .success(Raw(before: before, after: after, caret: rect, caretInfo: info, fontSize: fs))
    }

    // MARK: - Text markers

    private typealias CopyMarkerFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private static let copyStart: CopyMarkerFn? = symbol("AXTextMarkerRangeCopyStartMarker")
    private static let copyEnd: CopyMarkerFn? = symbol("AXTextMarkerRangeCopyEndMarker")
    private static func symbol(_ name: String) -> CopyMarkerFn? {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(p, to: CopyMarkerFn.self)
    }

    private static func readByMarkers(_ el: AXUIElement) -> Result<Raw, Refusal> {
        guard let copyStart, let copyEnd else { return .failure(Refusal(reason: "no-marker-symbols")) }
        guard let sel: CFTypeRef = attr(el, "AXSelectedTextMarkerRange") else { return .failure(Refusal(reason: "no-selected-markers")) }
        guard let caretM = copyEnd(sel)?.takeRetainedValue(), let selStart = copyStart(sel)?.takeRetainedValue() else {
            return .failure(Refusal(reason: "no-caret-marker"))
        }
        if let len: Int = param(el, "AXLengthForTextMarkerRange", sel), len != 0 { return .failure(Refusal(reason: "text-selected")) }
        _ = selStart

        // Bounds of this element's own text.
        var startM: CFTypeRef?
        var endM: CFTypeRef?
        if let all: CFTypeRef = param(el, "AXTextMarkerRangeForUIElement", el) {
            startM = copyStart(all)?.takeRetainedValue()
            endM = copyEnd(all)?.takeRetainedValue()
        }
        if startM == nil { startM = attr(el, "AXStartTextMarker") }
        if endM == nil { endM = attr(el, "AXEndTextMarker") }
        guard let startM else { return .failure(Refusal(reason: "no-start-marker")) }

        func range(_ a: CFTypeRef, _ b: CFTypeRef) -> CFTypeRef? {
            param(el, "AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray)
        }
        func text(_ r: CFTypeRef?) -> String? { r.flatMap { param(el, "AXStringForTextMarkerRange", $0) } }
        func bounds(_ r: CFTypeRef?) -> CGRect? {
            guard let r, let v: AXValue = param(el, "AXBoundsForTextMarkerRange", r) else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(v, .cgRect, &rect), rect.height > 2 else { return nil }
            return rect
        }

        guard let whole = text(range(startM, caretM)) else { return .failure(Refusal(reason: "no-text")) }
        let before = String(whole.suffix(contextLimit))
        var after = ""
        if let endM, let t = text(range(caretM, endM)) { after = String(t.prefix(200)) }

        let afterNewline = before.last?.isNewline ?? false
        var prevRect: CGRect?
        var fs: CGFloat?
        if !afterNewline, before.isEmpty == false, let prevM: CFTypeRef = param(el, "AXPreviousTextMarkerForTextMarker", caretM) {
            let pr = range(prevM, caretM)
            prevRect = bounds(pr)
            if let pr, let a: NSAttributedString = param(el, "AXAttributedStringForTextMarkerRange", pr) { fs = fontSize(a) }
        }
        var zeroRect: CGRect?
        if let nextM: CFTypeRef = param(el, "AXNextTextMarkerForTextMarker", caretM) { zeroRect = bounds(range(caretM, nextM)) }
        guard let (rect, info) = caretRect(prev: prevRect, zero: zeroRect) else { return .failure(Refusal(reason: "no-rect")) }
        return .success(Raw(before: before, after: after, caret: rect, caretInfo: "markers " + info, fontSize: fs))
    }

    // MARK: - AX helpers

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    private static func param<T>(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &v) == .success, let v else { return nil }
        return v as? T
    }

    private static func axRange(_ r: CFRange) -> AXValue {
        var r = r
        return AXValueCreate(.cfRange, &r)!
    }

    /// Text for a range; falls back to slicing the whole value for apps without StringForRange.
    private static func string(_ el: AXUIElement, _ r: CFRange, clamp: Bool = false) -> String? {
        if r.length == 0 { return "" }
        var range = r
        if clamp, let count: Int = attr(el, kAXNumberOfCharactersAttribute) {
            range.length = max(0, min(r.length, count - r.location))
            if range.length == 0 { return "" }
        }
        if let s: String = param(el, kAXStringForRangeParameterizedAttribute, axRange(range)) { return s }
        guard let all: String = attr(el, kAXValueAttribute) else { return nil }
        let ns = all as NSString
        let loc = min(range.location, ns.length)
        return ns.substring(with: NSRange(location: loc, length: min(range.length, ns.length - loc)))
    }

    /// Font size from the "AXFont" attribute (a dictionary with "AXFontSize") of the first character.
    private static func fontSize(_ a: NSAttributedString) -> CGFloat? {
        guard a.length > 0, let font = a.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
              let n = font["AXFontSize"] as? NSNumber else { return nil }
        let v = CGFloat(truncating: n)
        return v >= 8 && v <= 48 ? v : nil
    }

    private static func bounds(_ el: AXUIElement, _ r: CFRange) -> CGRect? {
        guard let v: AXValue = param(el, kAXBoundsForRangeParameterizedAttribute, axRange(r)) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v, .cgRect, &rect), rect.height > 2 else { return nil }
        return rect
    }

    /// Screen rect of the caret. Prefers the character before the caret (`prev`, its right edge): some apps
    /// return the whole block/paragraph for a zero-length range (`zero`, the fallback, its left edge).
    /// The result is at most `maxLineHeight` tall; for taller rects the bottom line is used.
    private static func caretRect(prev: CGRect?, zero: CGRect?) -> (NSRect, String)? {
        let maxLineHeight: CGFloat = 48
        let fallbackLineHeight: CGFloat = 20
        func line(_ r: CGRect, x: CGFloat) -> CGRect {
            if r.height <= maxLineHeight { return CGRect(x: x, y: r.minY, width: 1, height: r.height) }
            let h = fallbackLineHeight
            return CGRect(x: x, y: r.maxY - h, width: 1, height: h)
        }
        func fmt(_ r: CGRect) -> String {
            "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
        }

        var rect: CGRect
        var info: String
        if let r = prev {
            rect = line(r, x: r.maxX)
            info = "prevChar raw=\(fmt(r))"
        } else if let r = zero {
            rect = line(r, x: r.minX)
            info = "zeroLen raw=\(fmt(r))"
        } else {
            return nil
        }
        // AX: origin top-left of the main screen, y down. Cocoa: bottom-left, y up.
        guard let mainH = NSScreen.screens.first?.frame.height else { return nil }
        rect.origin.y = mainH - rect.maxY
        return (rect, info)
    }

    private static let enhancedUIApps: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams"]

    /// Chromium/Electron apps build their accessibility tree only when asked.
    static func enableAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Slack / Teams (Chromium) sometimes need the older switch too.
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, enhancedUIApps.contains(id) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}
