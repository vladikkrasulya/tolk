import AppKit
import ApplicationServices

/// Asks Accessibility whether the focused UI element of the frontmost app is certainly read-only (static text),
/// so ⌃⌥T / ⌃⌥P do not pretend to "replace" text that cannot be replaced.
/// Deliberately narrow: "is the value / selection settable" is NOT usable — TextEdit's editable text area reports
/// both as not settable (checked live). Unknown / not exposed → `false` (the paste is attempted, as before).
enum FocusProbe {
    static func focusedFieldIsReadOnly() -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(ref as! AXUIElement, kAXRoleAttribute as CFString, &role)
        return (role as? String) == (kAXStaticTextRole as String)
    }
}
