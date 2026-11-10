// Debug-only measurement: how often does the settings page poll while it is NOT on screen?
//   TOLK_IDLE_TICKS=12 .build/debug/Tolk --background      (waits 12 s, prints the number of polls, quits)
// The window is never shown (alpha 0, far off-screen, not ordered in).
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum IdleTicksDemo {
    private static var keepAlive: [AnyObject] = []
    static func run() {
        guard let secs = ProcessInfo.processInfo.environment["TOLK_IDLE_TICKS"].flatMap(Double.init) else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let vc = SettingsViewController(config: TolkConfig.load())
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.contentViewController = vc // loads the view; the window is NOT ordered in
        keepAlive = [vc, win]
        _ = vc.view
        print("[idle] window visible=\(win.isVisible)")
        let start = SettingsModel.debugRefreshCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(secs))
            print("[idle] polls in \(Int(secs)) s while hidden: \(SettingsModel.debugRefreshCount - start)")
            NSApp.terminate(nil)
        }
    }
}
#endif
