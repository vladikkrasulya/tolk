import AppKit

#if DEBUG
let smoke = ProcessInfo.processInfo.environment["TOLK_SMOKE"] != nil // touches nothing of the user's: no log, no marker
#else
let smoke = false
#endif
if !smoke { Diagnostics.install() } // first: log + crash capture for everything that follows

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu-bar first; the main window turns on the Dock icon
    withExtendedLifetime(delegate) { app.run() }
}
