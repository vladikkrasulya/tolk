// Rules for user-chosen global hotkeys (pure logic; Carbon modifier masks written out so the core stays AppKit-free).
import Foundation

public struct HotKeyBinding: Equatable, Sendable {
    public var id: String
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(id: String, keyCode: UInt32, modifiers: UInt32) { self.id = id; self.keyCode = keyCode; self.modifiers = modifiers }
}

public enum HotKeyRules {
    public static let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096

    public enum Problem: Equatable, Sendable {
        case needsControlOrOption
        case taken(by: String)
        case reserved
    }

    /// Key codes that must never be taken even with ⌃/⌥ (Esc, Return, Tab, Space, Delete, F-keys, arrows would break typing/navigation).
    private static let blockedKeys: Set<UInt32> = [53, 36, 48, 49, 51, 117, 76, 123, 124, 125, 126]

    /// Why `combo` cannot be used for `id`, or nil if it is fine. `others` = bindings of the other features (the
    /// screenshot hotkey included), `id` itself is ignored there.
    public static func validate(keyCode: UInt32, modifiers: UInt32, for id: String, others: [HotKeyBinding]) -> Problem? {
        let mods = modifiers & (cmd | shift | option | control)
        if mods & (control | option) == 0 { return .needsControlOrOption }
        if blockedKeys.contains(keyCode) { return .reserved }
        if let clash = others.first(where: { $0.id != id && $0.keyCode == keyCode && ($0.modifiers & (cmd | shift | option | control)) == mods }) {
            return .taken(by: clash.id)
        }
        return nil
    }

    /// Carbon mask from the pressed modifier keys (device-independent flags given as booleans).
    public static func mask(control c: Bool, option o: Bool, shift s: Bool, command m: Bool) -> UInt32 {
        (c ? control : 0) | (o ? option : 0) | (s ? shift : 0) | (m ? cmd : 0)
    }

    /// "⌃⌥T"-style label; `keyName` = the key's letter/digit.
    public static func label(modifiers: UInt32, key: String) -> String {
        var s = ""
        if modifiers & control != 0 { s += "⌃" }
        if modifiers & option != 0 { s += "⌥" }
        if modifiers & shift != 0 { s += "⇧" }
        if modifiers & cmd != 0 { s += "⌘" }
        return s + key
    }
}
