// The whole text of the focused field (not only the part before the caret), its frame, and "select everything".
// Safety checks (password fields, secure input, selected text, not editable) come from `FocusedField`, which this builds on.
import AppKit
import ApplicationServices
import TolkCore

struct TypeTranslateField {
    let pid: pid_t
    let bundleID: String?
    /// Whole text of the field.
    let text: String
    let element: AXUIElement?
    /// Field frame in Cocoa screen coordinates; nil when the app does not report a sensible one.
    let frame: NSRect?
    let caret: NSRect

    var snapshot: TypeTranslate.FieldSnapshot { .init(pid: pid, bundleID: bundleID, text: text) }

    /// Fields longer than this are never read whole.
    static let valueLimit = TypeTranslate.maxTextChars * 2

    private struct Box: @unchecked Sendable { let element: AXUIElement? }

    /// Full read on a background thread (caret, field frame, whole text). nil = nothing editable, a password field,
    /// text selected, the app does not report the caret, or the text is too long to be a chat message.
    static func read() async -> TypeTranslateField? {
        guard let f = await FocusedField.readAsync(seconds: 0.4) else { return nil }
        let box = Box(element: f.element)
        let value: String? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: wholeText(box.element, budget: 0.2)) }
        }
        return make(f, value: value)
    }

    /// Quick synchronous read for the key handler (Tab): whole text and identity, no geometry. Gives up after ~`seconds`.
    static func readQuick(seconds: TimeInterval = 0.04) -> TypeTranslateField? {
        guard let f = FocusedField.readQuick(seconds: seconds) else { return nil }
        return make(f, value: wholeText(f.element, budget: seconds))
    }

    private static func make(_ f: FocusedField, value: String?) -> TypeTranslateField? {
        var text = value
        // Single-line fallback when the app has no AXValue — or reports an empty one while the caret read (by range)
        // sees text before the caret (contradiction: the whole-text read is the one that is wrong).
        let noValue = text == nil || (text?.isEmpty == true && !f.textBefore.isEmpty)
        if noValue, f.textBefore.count < FocusedField.contextLimit, f.restOfLine.count < 200 {
            text = f.textBefore + f.restOfLine
        }
        guard let text, text.count <= valueLimit else { return nil }
        var frame: NSRect?
        if let el = f.element, let r = cocoaFrame(el), r.width > 60, r.height > 10, r.height < 400,
           r.insetBy(dx: -4, dy: -4).contains(NSPoint(x: f.caret.midX, y: f.caret.midY)) {
            frame = r
        }
        return TypeTranslateField(pid: f.pid, bundleID: f.bundleID, text: text, element: f.element, frame: frame, caret: f.caret)
    }

    /// Whole text of the element: AXValue (String or attributed string), then — when the app gives none or an empty
    /// one — the same text through `AXStringForRange(0, AXNumberOfCharacters)` (NSTextView in a scroll view, rich text).
    static func wholeText(_ el: AXUIElement?, budget: TimeInterval) -> String? {
        guard let el else { return nil }
        AXUIElementSetMessagingTimeout(el, Float(max(0.01, min(0.15, budget))))
        var v: CFTypeRef?
        var first: String?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let v {
            if let s = v as? String { first = s } else if let a = v as? NSAttributedString { first = a.string }
        }
        if let first, !first.isEmpty { return first }
        // Empty or missing: ask for the characters directly.
        var n: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &n) == .success,
              let count = (n as? NSNumber)?.intValue, count > 0, count <= valueLimit else { return first }
        var range = CFRange(location: 0, length: count)
        guard let rv = AXValueCreate(.cfRange, &range) else { return first }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let str = out as? String, !str.isEmpty else { return first }
        return str
    }

    /// For the log (no text, only shapes): role, what AXValue returned and how long, number of characters.
    static func diagnose(_ el: AXUIElement?) -> String {
        guard let el else { return "element=nil" }
        AXUIElementSetMessagingTimeout(el, 0.1)
        func str(_ k: String) -> String? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success ? v as? String : nil }
        var v: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
        var value = "err\(r.rawValue)"
        if r == .success, let v {
            if let s = v as? String { value = "string(\(s.count))" } else if let a = v as? NSAttributedString { value = "attributed(\(a.length))" }
            else { value = "other" }
        }
        var n: CFTypeRef?
        let chars = AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &n) == .success ? ((n as? NSNumber)?.intValue ?? -1) : -1
        return "role=\(str(kAXRoleAttribute) ?? "?") sub=\(str(kAXSubroleAttribute) ?? "-") value=\(value) chars=\(chars)"
    }

    private static func cocoaFrame(_ el: AXUIElement) -> NSRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s),
              let mainH = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: p.x, y: mainH - p.y - s.height, width: s.width, height: s.height)
    }

    /// Selects the whole text through `AXSelectedTextRange` and reads the range back. false = the field does not
    /// accept it (or reports something else): the caller must not paste.
    static func selectAll(_ el: AXUIElement, utf16Count: Int) -> Bool {
        AXUIElementSetMessagingTimeout(el, 0.1)
        var range = CFRange(location: 0, length: utf16Count)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        var back: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &back) == .success,
              let back, CFGetTypeID(back) == AXValueGetTypeID() else { return false }
        var got = CFRange()
        guard AXValueGetValue(back as! AXValue, .cfRange, &got) else { return false }
        return TypeTranslate.selectionCoversAll(location: got.location, length: got.length, textUTF16: utf16Count)
    }
}
