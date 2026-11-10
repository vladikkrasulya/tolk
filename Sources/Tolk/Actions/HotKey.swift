import AppKit
import Carbon.HIToolbox

/// A global shortcut: Carbon virtual key code + Carbon modifier mask (`controlKey | optionKey` …).
struct HotKeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
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
    let defaults = UserDefaults.standard

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
}
