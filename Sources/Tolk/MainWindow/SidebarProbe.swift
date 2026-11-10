// Debug-only: a single click on each sidebar row (real NSEvents, offscreen inactive window) must switch the page.
//   TOLK_SIDEBAR_PROBE=1 .build/debug/Tolk --background
#if DEBUG
import AppKit

@MainActor
enum SidebarProbe {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let sections = MainWindowController.Section.allCases
        let vc = SidebarViewController(sections: sections)
        let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 220, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.contentViewController = vc
        win.setContentSize(NSSize(width: 220, height: 400))
        vc.select(.translate)
        var failures = 0
        // Click every row in an odd order, then the same row twice, then the already selected one.
        for row in [2, 5, 0, 6, 3, 3, 1] {
            let seen = vc.debugClick(row: row, in: win)
            let ok = vc.debugSelectedRow == row && (seen == [sections[row]] || (seen.isEmpty && row == 3))
            print("[sidebar-probe] click row \(row): selected=\(vc.debugSelectedRow) onSelect=\(seen.map(\.rawValue)) \(ok ? "ok" : "FAIL")")
            if !ok { failures += 1 }
        }
        print("[sidebar-probe] failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
