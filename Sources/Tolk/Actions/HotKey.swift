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
    /// Shared by every center: all of them use the same signature, so ids must be unique app-wide
    /// (two centers both starting at 1 made ⌃⌥R arrive at the quick actions' handler for id 1).
    private static var nextID: UInt32 = 1

    /// Registers a shortcut; returns a token for `unregister`, or nil if the combo is taken
    /// (by another app or by us) or Carbon refused it.
    func register(_ combo: HotKeyCombo, handler: @escaping () -> Void) -> UInt32? {
        guard installHandlerIfNeeded() else { return nil }
        let id = Self.nextID
        Self.nextID += 1
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

/// Hotkeys per feature in UserDefaults (`tolk.quickActions.hotKeys`, JSON `{id: combo|null}`).
/// Missing id = the feature's default; explicit null = disabled by the user. Ids: quick-action ids and "typeTranslate".
struct QuickActionHotKeyStore {
    static let key = "tolk.quickActions.hotKeys"
    /// Posted after `set` — controllers re-register their hotkeys, the menu rewrites its labels.
    static let didChange = Notification.Name("tolk.hotKeysChanged")
    static let typeTranslateID = "typeTranslate"
    /// Ids whose last registration failed (taken by another app) — the settings page shows a warning.
    @MainActor static var failedIDs: Set<String> = []
    let defaults = UserDefaults.standard

    private func load() -> [String: HotKeyCombo?] {
        guard let data = defaults.data(forKey: Self.key),
              let dict = try? JSONDecoder().decode([String: HotKeyCombo?].self, from: data) else { return [:] }
        return dict
    }

    func hotKey(for action: QuickAction) -> HotKeyCombo? { hotKey(id: action.id, default: action.defaultHotKey) }

    func hotKey(id: String, default def: HotKeyCombo?) -> HotKeyCombo? {
        if let stored = load()[id] { return stored } // may be nil = disabled
        return def
    }

    /// nil = disabled. Writing the default again just stores it explicitly (harmless).
    func set(_ combo: HotKeyCombo?, id: String) {
        var dict = load()
        dict[id] = .some(combo)
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func reset(id: String) {
        var dict = load()
        dict[id] = nil
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

extension HotKeyCombo {
    var display: String { GlobalHotKey.display(keyCode: keyCode, modifiers: modifiers) }
}
