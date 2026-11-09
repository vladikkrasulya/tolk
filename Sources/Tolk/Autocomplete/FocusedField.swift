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

    static let contextLimit = 1500

    /// nil when nothing editable is focused, it is a password field, text is selected,
    /// or the app does not report the caret position.
    static func read() -> FocusedField? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        guard let el: AXUIElement = attr(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.15)

        if let sub: String = attr(el, kAXSubroleAttribute), sub == kAXSecureTextFieldSubrole as String { return nil }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]
        guard settable.boolValue || textRoles.contains(role) else { return nil }

        guard let rangeValue: AXValue = attr(el, kAXSelectedTextRangeAttribute) else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &sel), sel.length == 0, sel.location >= 0 else { return nil }
        let caretIndex = sel.location

        // Only the tail before the caret and a little after it — documents can be huge.
        let start = max(0, caretIndex - contextLimit)
        guard let before = string(el, CFRange(location: start, length: caretIndex - start)) else { return nil }
        let after = string(el, CFRange(location: caretIndex, length: 200), clamp: true) ?? ""
        let restOfLine = String(after.prefix { $0 != "\n" && $0 != "\r" })

        guard let (rect, info) = caretRect(el, caretIndex, afterNewline: before.last?.isNewline ?? false) else { return nil }
        return FocusedField(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                            textBefore: before, restOfLine: restOfLine, caret: rect, caretInfo: info)
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

    /// Screen rect of the caret. Prefers the character before the caret (its right edge): some apps
    /// return the whole block/paragraph for a zero-length range. Zero length is the fallback.
    /// The result is at most `maxLineHeight` tall; for taller rects the bottom line is used.
    private static func caretRect(_ el: AXUIElement, _ index: Int, afterNewline: Bool) -> (NSRect, String)? {
        func bounds(_ r: CFRange) -> CGRect? {
            guard let v: AXValue = param(el, kAXBoundsForRangeParameterizedAttribute, axRange(r)) else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(v, .cgRect, &rect), rect.height > 2 else { return nil }
            return rect
        }
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
        if index > 0, !afterNewline, let r = bounds(CFRange(location: index - 1, length: 1)) {
            rect = line(r, x: r.maxX)
            info = "prevChar raw=\(fmt(r))"
        } else if let r = bounds(CFRange(location: index, length: 0)) {
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

    /// Chromium/Electron apps build their accessibility tree only when asked.
    static func enableAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
