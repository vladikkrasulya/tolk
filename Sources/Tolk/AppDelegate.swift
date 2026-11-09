// Wiring — owned by the coordinating session.
import AppKit
import TolkCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var engine: DefaultTranslationEngine!
    private var monitor: DoubleCopyMonitor!          // strong ref: the event tap only holds a weak one
    private var popup: TranslationPopupController!
    private var inputWindow: InputWindowController!
    private var accessibilityTimer: Timer?
    private var accessItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = TolkConfig.load()
        engine = DefaultTranslationEngine(config: config)
        popup = TranslationPopupController(engine: engine)
        inputWindow = InputWindowController(engine: engine)
        popup.onExpand = { [weak self] text in self?.inputWindow.show(text: text) }

        monitor = DoubleCopyMonitor(interval: config.doubleCopyInterval)
        monitor.onTrigger = { [weak self] text, point in self?.popup.show(text: text, at: point) }

        setupMenu()
        startMonitor()

        #if DEBUG
        TolkUIDemo.runIfRequested(popup: popup, inputWindow: inputWindow)
        #endif
    }

    // MARK: - Double Cmd+C

    private func startMonitor() {
        if monitor.start() { accessItem.isHidden = true; return }
        _ = DoubleCopyMonitor.hasAccessibility(prompt: true)
        accessItem.isHidden = false
        // Retry until the user grants Accessibility in System Settings.
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.monitor.start() { t.invalidate(); self.accessItem.isHidden = true }
        }
    }

    // MARK: - Menu bar

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Tolk") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "T"
        }
        let menu = NSMenu()
        accessItem = item("⚠︎ Дай доступ Accessibility для двойного ⌘C", #selector(openAccessibility))
        menu.addItem(accessItem)
        menu.addItem(item("Окно перевода", #selector(openInput)))
        menu.addItem(item("Перевести буфер обмена", #selector(translateClipboard)))
        menu.addItem(.separator())
        menu.addItem(item("Правила и глоссарий…", #selector(openRules)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из Tolk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func openInput() { inputWindow.show() }

    @objc private func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        popup.show(text: text, at: NSEvent.mouseLocation)
    }

    @objc private func openRules() {
        let path = (engine.config.rulesPath as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openAccessibility() {
        _ = DoubleCopyMonitor.hasAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
