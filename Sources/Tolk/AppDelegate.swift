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
    private var reply: ReplyPanelController!
    private var inputWindow: InputWindowController!
    private var quickActions: QuickActionsController!
    private var screenCapture: ScreenCaptureController!
    private var mainWindow: MainWindowController!
    private var translatePage: TranslatePageViewController!
    private var imagePage: ImageTranslateViewController!
    private var glossaryPage: GlossaryViewController!
    private var documentsPage: DocumentsViewController!
    private var historyPage: HistoryViewController!
    private let history = HistoryStore()

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
        glossaryPage = GlossaryViewController(rulesPath: config.rulesPath)
        documentsPage = DocumentsViewController(engine: engine)
        historyPage = HistoryViewController(store: history)
        mainWindow = MainWindowController(translate: translatePage,
                                          image: imagePage,
                                          documents: documentsPage,
                                          history: historyPage,
                                          glossary: glossaryPage,
                                          settings: SettingsViewController(config: config))

        popup.onExpand = { [weak self] text in
            self?.mainWindow.show(.translate)
            self?.translatePage.load(text: text)
        }
        popup.toneForApp = { [weak self] in self?.config.tone(forApp: $0) ?? .auto }
        reply = ReplyPanelController(engine: engine)
        reply.toneForApp = { [weak self] in self?.config.tone(forApp: $0) ?? .auto }
        popup.onReply = { [weak self] ctx in self?.reply.show(ctx) }

        monitor = DoubleCopyMonitor(interval: config.doubleCopyInterval)
        monitor.onTrigger = { [weak self] text, point in self?.doubleCopy(text, at: point) }

        quickActions = QuickActionsController(engine: engine, config: config)
        quickActions.onWillPerform = { [weak self] in self?.popup.hideNow() }
        if !quickActions.start() { NSLog("Tolk: hotkeys taken: \(quickActions.failedActions.map(\.title))") }

        screenCapture = ScreenCaptureController()
        imagePage.screenCapture = screenCapture // one controller → never two selection overlays
        screenCapture.onText = { [weak self] text, point in self?.popup.show(text: text, at: point) }
        screenCapture.onHotKey = { [weak self] in self?.captureScreen() }
        screenCapture.start()
        imagePage.screenHotKeyDisplay = screenCapture.hotKeyDisplay
        // Closing the main window stops a long document translation (it would hold an Ollama slot).
        mainWindow.onClose = { [weak self] in self?.imagePage.cancelWork(); self?.documentsPage.cancelWork() }

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
        // Dev: TOLK_RENDER_REPLY=dir renders the reply window (light + dark) to PNG and quits.
        if let dir = ProcessInfo.processInfo.environment["TOLK_RENDER_REPLY"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let ctx = ReplyContext(
                    partnerText: "Hey, how are you? At the start of the integration, we delivered a chunk of requests on your end to let your demand show. It's ECPM. Afterward, our system started optimizing and delivering requests to streams with a better CPA. Then we went into the weekend, and we capped things to stay moderated. As it's an owned and operated website, its visitor volume depends on different metrics and different parameters. So I can't predict whether you'll see similar volume on your end this week.",
                    partnerTranslation: "Привет! Как дела? В начале интеграции мы отдали пачку запросов на вашей стороне, чтобы ваш demand показывался. Это было по eCPM. Потом наша система начала оптимизировать и отдавать запросы в потоки с лучшим CPA. Затем начались выходные, и мы поставили капу, чтобы всё было умеренно. Так как это собственный сайт, его объём посетителей зависит от разных метрик и параметров. Поэтому я не могу предсказать, увидите ли вы похожий объём на своей стороне на этой неделе.",
                    partnerLanguage: .english, app: NSWorkspace.shared.frontmostApplication, anchor: NSPoint(x: 400, y: 800))
                for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: look)
                    let r = ReplyPanelController(engine: self.engine)
                    r.renderForReview(ctx, reply: "Да, видим падение конверсии, похоже на плохие сабы — отключим их сегодня и пришлём новый список",
                                      translated: "Yeah, we see the CR drop too — looks like bad subs. We'll disable them today and send over a new list.",
                                      to: "\(dir)/reply-\(name).png")
                    r.close()
                }
                exit(0)
            }
        }
        // Dev: TOLK_RENDER_POPUP=dir shows the popup with a sample, waits for the translation, renders PNG, quits.
        if let dir = ProcessInfo.processInfo.environment["TOLK_RENDER_POPUP"] {
            UserDefaults.standard.set(false, forKey: "tolk.popup.notes")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                popup.show(text: "Hey Vlad, our CR on your push zones dropped to 0.4%. Can you check the sub IDs?", at: NSPoint(x: 500, y: 700))
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [self] in
                    popup.renderForReview(to: "\(dir)/popup.png")
                    UserDefaults.standard.removeObject(forKey: "tolk.popup.notes")
                    exit(0)
                }
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
        reply.replaceEngine(engine)
        translatePage.engine = engine
        imagePage.engine = engine
        documentsPage.engine = engine
        inputWindow.engine = engine
        glossaryPage.switchFile(to: config.rulesPath)
        quickActions.update(engine: engine, config: config)
        monitor.stop()
        monitor = DoubleCopyMonitor(interval: config.doubleCopyInterval)
        monitor.onTrigger = { [weak self] text, point in self?.doubleCopy(text, at: point) }
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
        menu.addItem(item("Как пользоваться", #selector(openHelp)))
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
    @objc private func openHelp() { mainWindow.show(.help) }
    @objc private func reportProblem() { Diagnostics.copyProblemReport() }
    @objc private func openGlossary() { mainWindow.show(.glossary) }
    @objc private func openSettings() { mainWindow.show(.settings) }
    /// Screen area capture (⌥⇧S or menu): main window open → the image page gets the picture
    /// (preview, paragraphs, translation); otherwise → OCR text in the popup.
    @objc private func captureScreen() {
        // Async: let the status menu close first, so it is not in the screenshot.
        DispatchQueue.main.async { [self] in
            if mainWindowOnScreen {
                Diagnostics.log("capture → image page")
                mainWindow.show(.image)
                imagePage.captureArea(nil)
            } else {
                Diagnostics.log("capture → popup")
                screenCapture.captureNow()
            }
        }
    }

    private var mainWindowOnScreen: Bool {
        guard let w = mainWindow.window else { return false }
        // isVisible is also true on another Space — then the capture must not drag the user there.
        return w.isVisible && !w.isMiniaturized && w.isOnActiveSpace
    }

    /// Double Cmd+C anywhere → popup. Inside Tolk's own windows it is just copying (you are already
    /// in the translator), so no popup there.
    private func doubleCopy(_ text: String, at point: NSPoint) {
        // Inside Tolk (main window, or the popup itself — copying its translation twice must not
        // replace it with a translation of the translation) it is just copying.
        if popupWindow?.isKeyWindow == true || reply.window?.isKeyWindow == true || (NSApp.isActive && NSApp.keyWindow != nil) {
            Diagnostics.log("double Cmd+C inside Tolk (\(NSApp.keyWindow?.title ?? "popup")) — ignored")
            return
        }
        Diagnostics.log("double Cmd+C: \(text.count) chars")
        popup.show(text: text, at: point)
    }

    private var popupWindow: NSWindow? { popup.window }
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
