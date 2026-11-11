// Debug-only invisible render of the «Автодополнение» settings tab with demo statistics.
//
//   TOLK_AC_STATS_SHOT=/some/dir .build/debug/Tolk --background
//
// Writes ac-stats-{light,dark}.png and quits. The window is never shown (no orderFront/makeKey): it only
// exists so that AppKit lays the views out and cacheDisplay can draw them. Fake data, the user's settings and
// statistics are not touched (the config is a default one, the statistics provider is replaced).
#if DEBUG
import AppKit
import TolkCore

@MainActor
enum ACStatsDemo {
    private static var keepAlive: [AnyObject] = []

    static func run() {
        guard let dir = ProcessInfo.processInfo.environment["TOLK_AC_STATS_SHOT"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let demo = ACStatsSource.demo()
        ACStatsSource.provider = { demo }
        let height = Double(ProcessInfo.processInfo.environment["TOLK_AC_STATS_HEIGHT"] ?? "") ?? 1700
        var shots: [(String, NSWindow, SettingsViewController)] = []
        for (name, ap) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            let vc = SettingsViewController(config: TolkConfig())
            let size = NSSize(width: 860, height: height)
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.alphaValue = 0
            win.appearance = ap
            win.contentViewController = vc
            win.setContentSize(size)
            vc.model.tab = .stats
            vc.model.refreshStats()
            shots.append((name, win, vc))
        }
        keepAlive = shots.map { $0.1 } + shots.map { $0.2 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            for (name, win, _) in shots {
                guard let v = win.contentView else { continue }
                v.layoutSubtreeIfNeeded(); v.displayIfNeeded()
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(dir)/ac-stats-\(name).png"))
                    print("[ac-stats-demo] wrote \(dir)/ac-stats-\(name).png")
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
