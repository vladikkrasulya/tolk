// Owned by the "input" session.
import AppKit
import ApplicationServices

/// Watches the keyboard globally; when Cmd+C is pressed twice within `interval`,
/// waits for the pasteboard to update and calls `onTrigger` with the copied text
/// and the mouse location (screen coordinates) for placing the popup.
///
/// Uses a listen-only CGEvent tap (needs Accessibility permission), so a single Cmd+C
/// keeps working as a normal copy in every app. The tap is attached to the main run loop,
/// so all state lives on the main thread and `onTrigger` is called there.
final class DoubleCopyMonitor {
    /// `eventSourceUserData` value on key events Tolk posts itself (quick actions, popup "Insert").
    static let syntheticMarker: Int64 = 0x544F4C4B
    var onTrigger: ((_ text: String, _ mouseLocation: NSPoint) -> Void)?
    let interval: TimeInterval

    /// How long to wait for the frontmost app to put the copied text on the pasteboard.
    private let pasteboardTimeout: TimeInterval = 0.3
    private let pasteboardPollStep: TimeInterval = 0.02

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastCopyTime: TimeInterval?
    /// Increments on every trigger so a stale pasteboard poll can tell it was superseded.
    private var triggerGeneration = 0

    private static let keyCodeC: Int64 = 8 // kVK_ANSI_C (physical key, works with any layout)
    private static let relevantModifiers: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
    ]

    init(interval: TimeInterval) { self.interval = interval }

    deinit { stop() }

    /// Returns false if Accessibility permission is missing or the tap could not be created.
    @discardableResult func start() -> Bool {
        if tap != nil { return true }
        guard Self.hasAccessibility(prompt: false) else { return false }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: doubleCopyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        lastCopyTime = nil
    }

    /// Checks Accessibility trust; with `prompt` shows the system dialog.
    static func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - Event handling (main thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        case .keyDown:
            break
        default:
            return
        }

        // Synthetic Cmd+C/Cmd+V from Tolk's own quick actions are marked 'TOLK' — never count them.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return }

        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.keyCodeC else {
            lastCopyTime = nil // any other key breaks the sequence
            return
        }
        // Key repeat while holding Cmd+C is not a second press.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        // Exactly Cmd — Cmd+Shift+C, Cmd+Opt+C etc. don't count and reset the sequence.
        guard event.flags.intersection(Self.relevantModifiers) == .maskCommand else {
            lastCopyTime = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastCopyTime, now - last <= interval {
            lastCopyTime = nil // third press starts a new pair
            fire()
        } else {
            lastCopyTime = now
        }
    }

    private func fire() {
        triggerGeneration += 1
        let generation = triggerGeneration
        let pasteboard = NSPasteboard.general
        let initialCount = pasteboard.changeCount
        let deadline = ProcessInfo.processInfo.systemUptime + pasteboardTimeout

        // The tap sees the key before the target app handles it, so poll until the
        // pasteboard changes. On timeout use what is there: the first Cmd+C of the pair
        // has already copied the selection in practically every app.
        func poll() {
            guard generation == triggerGeneration else { return }
            let changed = pasteboard.changeCount != initialCount
            if changed || ProcessInfo.processInfo.systemUptime >= deadline {
                deliver(pasteboard.string(forType: .string))
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardPollStep, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardPollStep, execute: poll)
    }

    private func deliver(_ text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onTrigger?(text, NSEvent.mouseLocation)
    }
}

/// C callback for the event tap. Runs on the main run loop (the tap source is added there).
private func doubleCopyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<DoubleCopyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
