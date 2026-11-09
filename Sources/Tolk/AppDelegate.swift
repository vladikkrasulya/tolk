// Wiring — owned by the coordinating session. Each feature lives in its own folder and is plugged in here:
//   Input/ (double Cmd+C) · UI/ (popup) · Actions/ (hotkeys, replace in place) · ImageTranslate/ (OCR)
//   MainWindow/ (window, Dock, settings) · Glossary/ (rules editor) · TolkCore/ (engine, contracts)
import AppKit
import TolkCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = TolkConfig.load()
    private var engine: DefaultTranslationEngine!

    // Features
    private var monitor: DoubleCopyMonitor!          // strong ref: the event tap only holds a weak one
    private var popup: TranslationPopupController!
    private var inputWindow: InputWindowController!
    private var quickActions: QuickActionsController!
    private var screenCapture: ScreenCaptureController!
    private var mainWindow: MainWindowController!
    private var translatePage: TranslatePageViewController!
    private var imagePage: ImageTranslateViewController!

    // Menu bar
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var accessItem: NSMenuItem!
    private var accessibilityTimer: Timer?
    private var healthTimer: Timer?
    private var lastHealth: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = DefaultTranslationEngine(config: config)

        popup = TranslationPopupController(engine: engine)
        inputWindow = InputWindowController(engine: engine)
        translatePage = TranslatePageViewController(engine: engine)
        imagePage = ImageTranslateViewController(engine: engine)
        mainWindow = MainWindowController(translate: translatePage,
                                          image: imagePage,
                                          glossary: GlossaryViewController(rulesPath: config.rulesPath),
                                          settings: SettingsViewController(config: config))

        popup.onExpand = { [weak self] text in
            self?.mainWindow.show(.translate)
            self?.translatePage.load(text: text)
        }
        popup.toneForApp = { [weak self] in self?.config.tone(forApp: $0) ?? .auto }

        monitor = DoubleCopyMonitor(interval: config.doubleCopyInterval)
        monitor.onTrigger = { [weak self] text, point in
            Diagnostics.log("double Cmd+C: \(text.count) chars")
            self?.popup.show(text: text, at: point)
        }

        quickActions = QuickActionsController(engine: engine, config: config)
        if !quickActions.start() { NSLog("Tolk: hotkeys taken: \(quickActions.failedActions.map(\.title))") }

        screenCapture = ScreenCaptureController()
        screenCapture.onText = { [weak self] text, point in self?.popup.show(text: text, at: point) }
        screenCapture.start()
        imagePage.screenHotKeyDisplay = screenCapture.hotKeyDisplay

        setupMenu()
        startMonitor()
        startHealthChecks()

        NotificationCenter.default.addObserver(self, selector: #selector(configChanged),
                                               name: TolkConfig.didChange, object: nil)

        // Launched by hand (Dock, Launchpad, Finder) -> show the window. At login (LaunchAgent passes
        // --background) stay quietly in the menu bar.
        if !CommandLine.arguments.contains("--background") { mainWindow.show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Diagnostics.offerReportIfCrashed() }

        #if DEBUG
        // Dev: TOLK_TEST_CRASH=1 crashes on purpose (checks the crash report path).
        if ProcessInfo.processInfo.environment["TOLK_TEST_CRASH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let missing: String? = nil
                Diagnostics.log("test crash")
                _ = missing!.count
            }
        }
        // Dev: TOLK_TEST_POPUP="text" opens the popup on launch (reproduce popup issues without clicking).
        if let text = ProcessInfo.processInfo.environment["TOLK_TEST_POPUP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.popup.show(text: text, at: NSPoint(x: 600, y: 600))
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) { Diagnostics.markCleanExit() }

    /// Click on the Dock / Launchpad icon while Tolk is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show() }
        return true
    }

    // MARK: - Settings changed -> rebuild the engine everywhere

    @objc private func configChanged() {
        config = TolkConfig.load()
        Diagnostics.log("settings changed: model=\(config.model) server=\(config.ollamaURL)")
        engine = DefaultTranslationEngine(config: config)
        popup.replaceEngine(engine)
        translatePage.engine = engine
        imagePage.engine = engine
        inputWindow.engine = engine
        quickActions.update(engine: engine, config: config)
        monitor.stop()
        monitor = DoubleCopyMonitor(interval: config.doubleCopyInterval)
        monitor.onTrigger = { [weak self] text, point in self?.popup.show(text: text, at: point) }
        startMonitor()
        checkHealth()
    }

    // MARK: - Double Cmd+C

    private func startMonitor() {
        if monitor.start() { accessItem.isHidden = true; return }
        _ = DoubleCopyMonitor.hasAccessibility(prompt: true)
        accessItem.isHidden = false
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.monitor.start() { t.invalidate(); self.accessItem.isHidden = true }
        }
    }

    // MARK: - Status: who translates right now

    private func startHealthChecks() {
        checkHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkHealth() }
    }

    private func checkHealth() {
        let primary = engine.primary
        Task { @MainActor [weak self] in
            let ok = await primary.isAvailable()
            if self?.lastHealth != ok { Diagnostics.log("vkbox \(primary.name): \(ok ? "available" : "unavailable")") }
            self?.lastHealth = ok
            self?.showHealth(ok)
        }
    }

    private func showHealth(_ qwenOK: Bool) {
        let symbol = qwenOK ? "character.bubble" : "exclamationmark.bubble"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tolk") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
        statusLine.title = qwenOK
            ? "● Переводит \(engine.primary.name) (vkbox)"
            : (config.useGoogleFallback ? "○ vkbox недоступен — переводит Google" : "○ vkbox недоступен")
        statusItem.button?.toolTip = statusLine.title
    }

    // MARK: - Menu bar

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Проверяю vkbox…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        accessItem = item("⚠︎ Дай доступ Accessibility для двойного ⌘C", #selector(openAccessibility))
        menu.addItem(accessItem)
        menu.addItem(.separator())
        menu.addItem(item("Открыть Tolk", #selector(openMain)))
        menu.addItem(item("Перевести буфер обмена", #selector(translateClipboard)))
        menu.addItem(item("Перевести область экрана  ⌥⇧S", #selector(captureScreen)))
        menu.addItem(.separator())
        menu.addItem(item("Перевести и заменить выделенное  ⌃⌥T", #selector(quickTranslate)))
        menu.addItem(item("Причесать выделенное  ⌃⌥P", #selector(quickPolish)))
        menu.addItem(.separator())
        menu.addItem(item("Глоссарий", #selector(openGlossary)))
        menu.addItem(item("Настройки…", #selector(openSettings)))
        menu.addItem(item("Сообщить о проблеме…", #selector(reportProblem)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из Tolk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        showHealth(true)
        statusLine.title = "Проверяю vkbox…"
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func openMain() { mainWindow.show() }
    @objc private func reportProblem() { Diagnostics.copyProblemReport() }
    @objc private func openGlossary() { mainWindow.show(.glossary) }
    @objc private func openSettings() { mainWindow.show(.settings) }
    // Async: let the status menu close first, so it is not in the screenshot.
    @objc private func captureScreen() { DispatchQueue.main.async { self.screenCapture.captureNow() } }
    @objc private func quickTranslate() { quickActions.perform(.translateReplace) }
    @objc private func quickPolish() { quickActions.perform(.polishReplace) }

    @objc private func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Diagnostics.log("translate clipboard: \(text.count) chars")
        popup.show(text: text, at: NSEvent.mouseLocation)
    }

    @objc private func openAccessibility() {
        _ = DoubleCopyMonitor.hasAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
