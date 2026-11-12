// Thin window around `TranslatePageViewController`.
import AppKit
import TolkCore

/// Window that routes edit shortcuts (an `.accessory` app may have no usable main menu).
final class InputWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        if super.performKeyEquivalent(with: event) { return true }
        return EditShortcuts.handle(event)
    }

    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

/// Standalone translate window (menu bar "Окно перевода"); the same page as in the main window.
@MainActor
final class InputWindowController: NSObject, NSWindowDelegate {
    /// Replaceable (see `TranslatePageViewController.engine`).
    var engine: TranslationEngine { didSet { pageIfLoaded?.engine = engine } }
    private var pageIfLoaded: TranslatePageViewController?
    private(set) lazy var page: TranslatePageViewController = {
        let p = TranslatePageViewController(engine: engine)
        p.topInset = 34 // below the transparent title bar
        p.footerHint = "⌘↩ — скопировать и закрыть   ·   \(EscText.closeHint)"
        p.onCommandReturn = { [weak self] in self?.copyAndClose() }
        p.onEscape = { [weak self] in self?.window?.performClose(nil) }
        pageIfLoaded = p
        return p
    }()
    private var window: InputWindow?

    init(engine: TranslationEngine) {
        self.engine = engine
        super.init()
    }

    /// Callable from nonisolated code (e.g. `@objc` menu actions); must run on the main thread.
    nonisolated func show() {
        MainActor.assumeIsolated { self.present() }
    }

    /// Opens the window with `text` already in the input and translates it.
    nonisolated func show(text: String) {
        MainActor.assumeIsolated {
            self.present()
            self.page.load(text: text)
        }
    }

    private func present() {
        let firstTime = window == nil
        let w = buildIfNeeded()
        if firstTime, !w.setFrameUsingName("TolkInputWindow") { w.center() }
        AppPresence.bringToFront(w)
        page.focusInput()
    }

    private func copyAndClose() {
        guard !page.translation.isEmpty else { NSSound.beep(); return }
        Clipboard.copy(page.translation)
        window?.orderOut(nil)
        page.stop()
        // Return focus to the app the user came from, ready to paste. `NSApp.hide` would also take away every
        // other Tolk window (the big one): only hide the app when this was its last window on screen.
        let othersOpen = NSApp.windows.contains { $0 !== window && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        if !othersOpen { NSApp.hide(nil) }
    }

    func windowWillClose(_ notification: Notification) { page.stop() }

    private func buildIfNeeded() -> InputWindow {
        if let window { return window }
        let w = InputWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 460),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        w.title = "Tolk — перевод"
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 560, height: 300)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        ThemeFillView.underlay(effect, color: Theme.panel)
        let pageView = page.view
        pageView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: effect.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        w.contentView = effect
        w.setContentSize(NSSize(width: 880, height: 460))
        w.setFrameAutosaveName("TolkInputWindow")
        window = w
        return w
    }
}
