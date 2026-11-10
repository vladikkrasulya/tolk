// Self-test of the UX rules (capture focus). No windows, no focus changes.
import Foundation

extension SelfTest {
    static func uxRules(_ check: Check) {
        check(CaptureFocus.route(tolkWasFrontmost: true, mainWindowUsable: true) == .mainWindow, "capture: Tolk in front + window → big window")
        check(CaptureFocus.route(tolkWasFrontmost: false, mainWindowUsable: true) == .popup, "capture: window visible but another app in front → popup")
        check(CaptureFocus.route(tolkWasFrontmost: true, mainWindowUsable: false) == .popup, "capture: Tolk in front but no window (popup only) → popup")
        check(CaptureFocus.route(tolkWasFrontmost: false, mainWindowUsable: false) == .popup, "capture: nothing of Tolk open → popup")
        for end in [CaptureEnd.selected, .cancelled] {
            check(CaptureFocus.target(route: .mainWindow, end: end) == .tolk, "capture focus: big window, \(end) → stays in Tolk")
            check(CaptureFocus.target(route: .popup, end: end) == .previousApp, "capture focus: popup, \(end) → back to the previous app")
        }
        check(CaptureFocus.target(route: .mainWindow, end: .appSwitched) == .none, "capture focus: big window, app switched → do not pull back")
        check(CaptureFocus.target(route: .popup, end: .appSwitched) == .none, "capture focus: popup, app switched → do not pull back")
    }
}
