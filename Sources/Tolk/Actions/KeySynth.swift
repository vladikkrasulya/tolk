import AppKit
import Carbon.HIToolbox

/// Synthetic ⌘C / ⌘V for the frontmost app. Posting needs Accessibility permission.
/// Every event carries `eventSourceUserData = KeySynth.marker`, so our own taps
/// (DoubleCopyMonitor) can ignore them.
enum KeySynth {
    static let marker = DoubleCopyMonitor.syntheticMarker

    /// Presses and releases ⌘+key (key = Carbon/virtual key code, layout-independent).
    static func pressCommand(_ keyCode: Int) {
        // Private state: the event does not inherit modifiers the user still holds physically.
        let src = CGEventSource(stateID: .privateState)
        src?.userData = marker
        for keyDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else { continue }
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    static func copy() { pressCommand(kVK_ANSI_C) }
    static func paste() { pressCommand(kVK_ANSI_V) }

    /// The hotkey fires while the user still holds ⌃⌥; some apps read the live modifier state,
    /// so wait (≤ timeout) until ⌃⌥⇧⌘ are released before sending ⌘C.
    @MainActor
    static func waitForModifiersReleased(timeout: TimeInterval = 1.0) async {
        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty { return }
            await sleepIgnoringCancel(0.02)
        }
    }
}

/// Sleep that finishes even when the task is cancelled (clipboard bookkeeping must complete).
@MainActor
func sleepIgnoringCancel(_ seconds: TimeInterval) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { c.resume() }
    }
}
