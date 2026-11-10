// Where a screen-area capture shows its result and who gets the keyboard focus afterwards.
// Pure rules (no AppKit), so the self-test can check every exit path.
import Foundation

public enum CaptureRoute: Equatable, Sendable {
    /// Result goes to the «Фото и скриншоты» page of the big window; Tolk stays the active app.
    case mainWindow
    /// Result goes to the popup next to the area; focus returns to the app the user was in.
    case popup
}

/// How the area selection ended.
public enum CaptureEnd: Equatable, Sendable {
    case selected
    /// Esc, right click, an area that is too small.
    case cancelled
    /// The user switched to another app (⌘Tab, click on a Dock icon) — the overlay closed itself.
    case appSwitched
}

public enum CaptureFocusTarget: Equatable, Sendable {
    case tolk
    case previousApp
    /// Do not touch the focus: the user already chose where to go.
    case none
}

public enum CaptureFocus {
    /// Rule: the big window is used only when the user was working in Tolk when they pressed the hotkey
    /// (Tolk was the frontmost app). A visible window behind another app does not count.
    public static func route(tolkWasFrontmost: Bool, mainWindowUsable: Bool) -> CaptureRoute {
        tolkWasFrontmost && mainWindowUsable ? .mainWindow : .popup
    }

    /// Who gets the focus once the overlay is gone.
    public static func target(route: CaptureRoute, end: CaptureEnd) -> CaptureFocusTarget {
        if end == .appSwitched { return .none }
        return route == .mainWindow ? .tolk : .previousApp
    }
}
