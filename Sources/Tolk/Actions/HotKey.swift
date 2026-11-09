// Owned by the "quick actions" session.
import AppKit
import Carbon.HIToolbox

/// A global shortcut: Carbon virtual key code + Carbon modifier mask (`controlKey | optionKey` …).
struct HotKeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    /// For a shortcut recorder on the settings page: build from a keyDown NSEvent.
    /// Returns nil without ⌃/⌥/⌘ (plain keys and ⇧+key would hijack typing everywhere).
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        guard m & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    /// "⌃⌥T" — macOS order ⌃⌥⇧⌘.
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return letters[Int(code)] ?? "#\(code)"
    }
}

/// Global hotkeys via Carbon `RegisterEventHotKey` (no Accessibility needed, the key is swallowed).
/// Several centers / other code may register Carbon hotkeys in the same process (the screenshot
/// session has ⌥⇧S): ours are told apart by `signature`, foreign ids get `eventNotHandledErr`.
@MainActor
final class HotKeyCenter {
    nonisolated static let signature: OSType = 0x546C_6B51 // 'TlkQ'

    private var handlerRef: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    /// Registers a shortcut; returns a token for `unregister`, or nil if the combo is taken
    /// (by another app or by us) or Carbon refused it.
    func register(_ combo: HotKeyCombo, handler: @escaping () -> Void) -> UInt32? {
        guard installHandlerIfNeeded() else { return nil }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ token: UInt32) {
        if let ref = refs.removeValue(forKey: token) { UnregisterEventHotKey(ref) }
        handlers[token] = nil
    }

    func unregisterAll() { refs.keys.forEach(unregister) }

    fileprivate func fire(_ id: UInt32) -> Bool {
        guard let h = handlers[id] else { return false }
        h()
        return true
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), tolkHotKeyCallback, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        return status == noErr
    }
}

/// Carbon delivers hotkey events on the main thread (application event target).
private func tolkHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard status == noErr, hk.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let handled = MainActor.assumeIsolated { center.fire(hk.id) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}

/// Hotkeys per action in UserDefaults (`tolk.quickActions.hotKeys`, JSON `{id: combo|null}`).
/// Missing id = the action's default; explicit null = disabled by the user.
struct QuickActionHotKeyStore {
    static let key = "tolk.quickActions.hotKeys"
    var defaults: UserDefaults = .standard

    private func load() -> [String: HotKeyCombo?] {
        guard let data = defaults.data(forKey: Self.key),
              let dict = try? JSONDecoder().decode([String: HotKeyCombo?].self, from: data) else { return [:] }
        return dict
    }

    func hotKey(for action: QuickAction) -> HotKeyCombo? {
        let dict = load()
        if let stored = dict[action.id] { return stored } // may be nil = disabled
        return action.defaultHotKey
    }

    func set(_ combo: HotKeyCombo?, for action: QuickAction) {
        var dict = load()
        dict[action.id] = .some(combo)
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: Self.key) }
    }

    func reset() { defaults.removeObject(forKey: Self.key) }
}
