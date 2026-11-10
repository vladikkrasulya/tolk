// Wiring — owned by the coordinating session. Each feature lives in its own folder and is plugged in here:
//   Input/ (double Cmd+C) · UI/ (popup) · Actions/ (hotkeys, replace in place) · ImageTranslate/ (OCR)
//   MainWindow/ (window, Dock, settings) · Glossary/ (rules editor) · TolkCore/ (engine, contracts)
import AppKit
import TolkCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = TolkConfig.load()
    private let isFirstRun = FirstRunView.isNeeded // no tolk.json yet: evaluated before anything can save it
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
    private var profileItem: NSMenuItem!

    // Autocomplete
    private var acServer: LocalModelServer!
    private var acController: AutocompleteController!
    private var ttController: TypeTranslateController!
    private var ttItem: NSMenuItem!
    private var quickMenuItems: [(QuickAction, NSMenuItem)] = []
    private var settingsVC: SettingsViewController!
    private var termSources: [DispatchSourceSignal] = []
    private var acItem: NSMenuItem!
    private var acStatusItem: NSMenuItem!
    private var acStatsItem: NSMenuItem!
    private var acRetryItem: NSMenuItem!
    private var acAppItem: NSMenuItem!
    private var acFlagItems: [(item: NSMenuItem, keyPath: WritableKeyPath<TolkConfig, Bool>)] = []
    private var acLengthItems: [NSMenuItem] = []
    private var acFreqItems: [NSMenuItem] = []
    private var acTimer: Timer?
    private var lastExternalApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOLK_AC_STATS_SHOT"] != nil { ACStatsDemo.run(); return }
        if ProcessInfo.processInfo.environment["TOLK_HINTS_SHOT"] != nil { TranslateHintsDemo.run(); return }
        // Invisible popup render (never shown): TOLK_RENDER_POPUP=dir
        if ProcessInfo.processInfo.environment["TOLK_RENDER_POPUP"] != nil { PopupDemo.run(); return }
        if ProcessInfo.processInfo.environment["TOLK_IDLE_TICKS"] != nil { IdleTicksDemo.run(); return }
        if ProcessInfo.processInfo.environment["TOLK_TYPE_TRANSLATE_SHOT"] != nil { TypeTranslateDemo.run(); return }
        if ProcessInfo.processInfo.environment["TOLK_MAIN_DEMO"] != nil { MainWindowDemo.runIfRequested(); return }
        // Dev: TOLK_TEST_OLLAMA=http://127.0.0.1:11999 points this run at a fake server (cold-model / down tests); not saved.
        if let url = ProcessInfo.processInfo.environment["TOLK_TEST_OLLAMA"] { config.ollamaURL = url; config.autocomplete = false }
        #endif
        engine = DefaultTranslationEngine(config: config)

        popup = TranslationPopupController(engine: withHistory("popup"))
        inputWindow = InputWindowController(engine: withHistory("page"))
        translatePage = TranslatePageViewController(engine: withHistory("page"))
        imagePage = ImageTranslateViewController(engine: withHistory("image"))
        Self.ensureProfileFile(config.activeProfile)
        glossaryPage = GlossaryViewController(rulesPath: config.effectiveRulesPath)
        documentsPage = DocumentsViewController(engine: engine)
        historyPage = HistoryViewController(store: history)
        historyPage.onOpen = { [weak self] e in
            self?.mainWindow.show(.translate)
            self?.translatePage.load(text: e.source)
        }
        settingsVC = SettingsViewController(config: config)
        mainWindow = MainWindowController(translate: translatePage,
                                          image: imagePage,
                                          documents: documentsPage,
                                          history: historyPage,
                                          glossary: glossaryPage,
                                          settings: settingsVC)

        let openDocument: (URL) -> Void = { [weak self] url in
            self?.mainWindow.show(.documents)
            self?.documentsPage.open(url: url)
        }
        translatePage.history = history
        translatePage.onOpenDocument = openDocument
        inputWindow.page.history = history
        inputWindow.page.onOpenDocument = openDocument

        popup.onExpand = { [weak self] text in
            self?.mainWindow.show(.translate)
            self?.translatePage.load(text: text)
        }
        popup.onVariants = { [weak self] text, tone, thread in
            self?.mainWindow.show(.translate)
            self?.translatePage.load(text: text, tone: tone, threadContext: thread, suggestVariants: true)
        }
        popup.toneForApp = { [weak self] in self?.config.tone(forApp: $0) ?? .auto }
        reply = ReplyPanelController(engine: withHistory("reply"))
        reply.toneForApp = { [weak self] in self?.config.tone(forApp: $0) ?? .auto }
        popup.onReply = { [weak self] ctx in self?.reply.show(ctx) }

        monitor = DoubleCopyMonitor(interval: config.doubleCopyInterval)
        monitor.onTrigger = { [weak self] text, point in self?.doubleCopy(text, at: point) }

        quickActions = QuickActionsController(engine: withHistory("quick"), config: config)
        quickActions.onWillPerform = { [weak self] in self?.popup.hideNow() }
        NotificationCenter.default.addObserver(self, selector: #selector(hotKeysChanged),
                                               name: QuickActionHotKeyStore.didChange, object: nil)
        if !quickActions.start() { NSLog("Tolk: hotkeys taken: \(quickActions.failedActions.map(\.title))") }

        screenCapture = ScreenCaptureController()
        imagePage.screenCapture = screenCapture // one controller → never two selection overlays
        screenCapture.onText = { [weak self] text, point in self?.popup.show(text: text, at: point) }
        screenCapture.onHotKey = { [weak self] in self?.captureScreen() }
        screenCapture.start()
        if ProcessInfo.processInfo.environment["TOLK_TEST_OVERLAY"] != nil {
            if ProcessInfo.processInfo.environment["TOLK_TEST_OVERLAY"] == "image" { mainWindow.show(.image) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.captureScreen() }
        }
        if let spec = ProcessInfo.processInfo.environment["TOLK_TEST_CAPTURE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.screenCapture.runTestCapture(spec) }
        }
        imagePage.screenHotKeyDisplay = screenCapture.hotKeyDisplay
        // Closing the main window stops a long document translation (it would hold an Ollama slot).
        mainWindow.onClose = { [weak self] in self?.imagePage.cancelWork(); self?.documentsPage.cancelWork() }

        setupAutocomplete()
        setupMenu()
        startMonitor()
        applyAutocomplete()
        startHealthChecks()

        NotificationCenter.default.addObserver(self, selector: #selector(configChanged),
                                               name: TolkConfig.didChange, object: nil)

        // Launched by hand (Dock, Launchpad, Finder) -> show the window. At login (LaunchAgent passes
        // --background) stay quietly in the menu bar.
        if !CommandLine.arguments.contains("--background") {
            mainWindow.show()
            if isFirstRun { FirstRunView.present(in: mainWindow.window) }
        }
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
        // Dev: TOLK_MENU_PROBE=file appends the status item position and every menu opening to `file`
        // (lets a script click the real status item and check that a plain left click opens the menu).
        if let probe = ProcessInfo.processInfo.environment["TOLK_MENU_PROBE"] {
            func note(_ s: String) {
                guard let h = FileHandle(forWritingAtPath: probe) ?? { FileManager.default.createFile(atPath: probe, contents: nil); return FileHandle(forWritingAtPath: probe) }() else { return }
                h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close()
            }
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                note("OPEN")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.statusItem.menu?.cancelTracking() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let f = self?.statusItem.button?.window?.frame else { return }
                note("POS \(f.midX) \((NSScreen.screens.first?.frame.height ?? 0) - f.midY)")
            }
        }
        // Dev: TOLK_RENDER_MENUICON=file.png renders the menu bar icon preview and quits.
        if let path = ProcessInfo.processInfo.environment["TOLK_RENDER_MENUICON"] {
            MenuBarIcon.renderPreview(to: path); exit(0)
        }
        // Dev: TOLK_STRESS_POPUP=N opens/closes the popup N times at random intervals (races, leaks), then logs
        // memory + open file/thread counts to stderr.log and quits.
        if let n = ProcessInfo.processInfo.environment["TOLK_STRESS_POPUP"].flatMap(Int.init) {
            func rss() -> Int { var info = mach_task_basic_info(); var c = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
                _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &c) } }
                return Int(info.resident_size) / 1_048_576 }
            let r0 = rss()
            var i = 0
            func step() {
                i += 1
                if i > n {
                    popup.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let line = "stress: \(n) shows, rss \(r0) -> \(rss()) MB, windows \(NSApp.windows.count), visible \(NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) }) popupVisible \(self.popup.isVisible)\n"
                        FileHandle.standardError.write(Data(line.utf8)); try? line.write(toFile: "/tmp/claude-501/stress.txt", atomically: true, encoding: .utf8); exit(0)
                    }
                    return
                }
                popup.show(text: "Stress \(i): the quick brown fox jumps over the lazy dog \(i % 7)", at: NSPoint(x: 300 + (i % 5) * 40, y: 600))
                if i % 3 == 0 { popup.hide() }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 5...250))) { step() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { step() }
        }
        // Dev: TOLK_TEST_QUICK=translateReplace|polishReplace runs that quick action after 8 s on whatever is selected
        // in the frontmost app (needs Accessibility for this binary).
        if let id = ProcessInfo.processInfo.environment["TOLK_TEST_QUICK"], let action = QuickAction.with(id: id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                Diagnostics.log("test quick action \(id), trusted=\(AXIsProcessTrusted())")
                self?.quickActions.perform(action)
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

    func applicationWillTerminate(_ notification: Notification) {
        acController?.stop()
        ACStatsStore.shared.flush()
        acServer?.stop() // the llama-server child must not outlive Tolk
        Diagnostics.markCleanExit()
    }

    /// Every feature gets the engine through a history recorder with its own origin
    /// (documents are not recorded paragraph by paragraph).
    private func withHistory(_ origin: String) -> TranslationEngine {
        HistoryRecordingEngine(engine, origin: origin, store: history)
    }

    /// Click on the Dock / Launchpad icon while Tolk is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show() }
        return true
    }

    // MARK: - Settings changed -> rebuild the engine everywhere

    @objc private func configChanged() {
        config = TolkConfig.load()
        Diagnostics.log("settings changed: profile=\(config.activeProfileID) model=\(config.effectiveModel) fallback=\(config.fallback.rawValue)")
        engine = DefaultTranslationEngine(config: config)
        popup.replaceEngine(withHistory("popup"))
        reply.replaceEngine(withHistory("reply"))
        translatePage.engine = withHistory("page")
        imagePage.engine = withHistory("image")
        documentsPage.engine = engine
        inputWindow.engine = withHistory("page")
        Self.ensureProfileFile(config.activeProfile)
        glossaryPage.switchFile(to: config.effectiveRulesPath)
        rebuildProfileMenu()
        quickActions.update(engine: withHistory("quick"), config: config)
        monitor.stop()
        monitor = DoubleCopyMonitor(interval: config.doubleCopyInterval)
        monitor.onTrigger = { [weak self] text, point in self?.doubleCopy(text, at: point) }
        startMonitor()
        applyAutocomplete()
        checkHealth()
    }

    // MARK: - Autocomplete

    private func setupAutocomplete() {
        acServer = LocalModelServer(modelPath: config.autocompleteModel)
        acController = AutocompleteController(server: acServer)
        acController?.onStatsChanged = { [weak self] in self?.refreshStatsMenuLine() }
        // «Перевод при наборе»: its own engine without the Google fallback (the conversation never leaves for the internet).
        ttController = TypeTranslateController(engine: typeTranslateEngine(), config: config)
        ttController.onToggle = { [weak self] apps in
            guard let self else { return }
            var c = self.config
            c.typeTranslateApps = apps
            try? c.save()
        }
        if !ttController.start() { Diagnostics.log("type-translate: hotkey taken") }
        acController.typeTranslate = ttController
        acServer.onStateChange = { [weak self] _ in self?.serverStateChanged() }
        settingsVC.model.onRetryAutocomplete = { [weak self] in self?.acServer.retry() }
        // SIGTERM/SIGINT/SIGHUP end Tolk normally (applicationWillTerminate stops the server). After kill -9 the
        // llama-server wrapper notices the missing parent within ~2 s (LocalModelServer).
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            termSources.append(src)
        }
        PowerMonitor.shared.onChange = { [weak self] in
            guard let self, self.config.autocompleteBatteryRare || self.config.autocompleteBatteryNoScreen || self.config.autocompleteBatteryShort else { return }
            self.applyAutocomplete()
        }
        PowerMonitor.shared.start()
        let me = Bundle.main.bundleIdentifier
        lastExternalApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == me ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular else { return }
        lastExternalApp = app
        refreshAutocompleteMenu()
    }

    /// Server state → menu, settings tab, and the gate for screen reading (no snapshots while the model is not ready).
    private func serverStateChanged() {
        ScreenContext.serverReady = acServer.state == .ready
        if case .failed(let e) = acServer.state {
            var text = e
            if let at = acServer.nextRetryAt { text += " — повтор через \(max(1, Int(at.timeIntervalSinceNow.rounded()))) с" }
            settingsVC.model.acError = text
        } else {
            settingsVC.model.acError = nil
        }
        refreshAutocompleteMenu()
    }

    @objc private func retryAutocompleteServer() { acServer.retry() }

    private var wantsTypingTap: Bool {
        config.autocomplete || config.autocorrect || config.autocompleteEmoji
            || TypeTranslate.anyEnabled(config.typeTranslateApps) || config.typeTranslateAuto
    }

    private func typeTranslateEngine() -> TranslationEngine {
        var c = config
        c.fallback = .none
        return DefaultTranslationEngine(config: c)
    }

    /// Brings server + controller in line with the config (on launch and on every settings change).
    private func applyAutocomplete() {
        ttController?.update(engine: typeTranslateEngine(), config: config)
        acController.disabledApps = Set(config.autocompleteOffApps)
        AutocompleteFeatures.configure(acController, config: config)
        acServer.setModel(config.autocompleteModel)
        acTimer?.invalidate(); acTimer = nil
        // The model server belongs to autocomplete; the key tap also serves typo fixes and emoji on their own.
        if config.autocomplete {
            if acServer.state == .stopped { acServer.start() }
        } else {
            acServer.stop()
        }
        if wantsTypingTap {
            if !acController.isRunning && !acController.start() {
                Diagnostics.log("autocomplete: event tap not created (Accessibility/Input Monitoring missing?) trusted=\(AXIsProcessTrusted())")
                _ = DoubleCopyMonitor.hasAccessibility(prompt: true) // same flow as double Cmd+C
                acTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                    guard let self else { t.invalidate(); return }
                    if !self.wantsTypingTap || self.acController.start() { t.invalidate(); self.acTimer = nil }
                }
            }
        } else {
            acController.stop()
        }
        refreshAutocompleteMenu()
    }

    private func refreshStatsMenuLine() {
        guard acStatsItem != nil else { return }
        let line = ACStats.menuLine(ACStatsStore.shared.data)
        acStatsItem.title = line ?? ""
        acStatsItem.isHidden = line == nil || !config.autocomplete
    }

    private func refreshAutocompleteMenu() {
        guard acItem != nil else { return }
        refreshStatsMenuLine()
        acItem.state = config.autocomplete ? .on : .off
        acStatusItem.isHidden = !config.autocomplete
        for f in acFlagItems { f.item.state = config[keyPath: f.keyPath] ? .on : .off }
        for it in acFreqItems { it.state = (it.representedObject as? String) == config.autocompleteFrequency ? .on : .off }
        for it in acLengthItems { it.state = (it.representedObject as? String) == config.autocompleteLength ? .on : .off }
        switch acServer.state {
        case .stopped: acStatusItem.title = "\(acServer.modelName): остановлена"
        case .starting: acStatusItem.title = "\(acServer.modelName) загружается…"
        case .ready: acStatusItem.title = "\(acServer.modelName): готово"
        case .failed(let e): acStatusItem.title = "\(acServer.modelName): не запустилась"; acStatusItem.toolTip = e
        }
        if let retry = acRetryItem { retry.isHidden = !acServer.isFailedState }
        if let app = lastExternalApp, let id = app.bundleIdentifier {
            let ttOn = config.typeTranslateApps[id] == true
            ttItem.title = "Перевод при наборе в \(app.localizedName ?? id): \(ttOn ? "выключить" : "включить")" + Self.hotKeySuffix(typeTranslateHotKey)
            ttItem.state = ttOn ? .on : .off
            let off = config.autocompleteOffApps.contains(id)
            acAppItem.title = "\(off ? "Включить" : "Выключить") в \(app.localizedName ?? id)"
            acAppItem.isHidden = false
        } else {
            acAppItem.isHidden = true
        }
    }

    @objc private func toggleTypeTranslate() { ttController.toggleForFrontApp() }

    @objc private func toggleAutocomplete() {
        var c = config
        c.autocomplete.toggle()
        try? c.save()
    }

    @objc private func toggleAutocompleteFlag(_ sender: NSMenuItem) {
        guard acFlagItems.indices.contains(sender.tag) else { return }
        var c = config
        c[keyPath: acFlagItems[sender.tag].keyPath].toggle()
        try? c.save()
    }

    @objc private func setAutocompleteLength(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var c = config
        c.autocompleteLength = key
        try? c.save()
    }

    @objc private func setAutocompleteFrequency(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var c = config
        c.autocompleteFrequency = key
        try? c.save()
    }

    @objc private func toggleAutocompleteForApp() {
        guard let id = lastExternalApp?.bundleIdentifier else { return }
        var c = config
        if let i = c.autocompleteOffApps.firstIndex(of: id) { c.autocompleteOffApps.remove(at: i) }
        else { c.autocompleteOffApps.append(id) }
        try? c.save()
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
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkHealth()
            self?.monitor?.ensureAlive()
        }
    }

    private func checkHealth() {
        let primary = engine.primary
        Task { @MainActor [weak self] in
            let ok = await primary.isAvailable()
            if self?.lastHealth != ok { Diagnostics.log("vkbox \(primary.name): \(ok ? "available" : "unavailable")") }
            self?.lastHealth = ok
            self?.showHealth(ok)
            // Model fell out of memory (idle > keep_alive, Ollama restart): load it in the background now,
            // so the next translation is not a 35+ s cold start.
            if ok, let ollama = primary as? OllamaProvider { await ollama.warmUpIfNeeded() }
        }
    }

    private func showHealth(_ qwenOK: Bool) {
        statusItem.button?.image = MenuBarIcon.image(qwenOK ? .ready : .unavailable)
        statusLine.title = ServerText.menuLine(available: qwenOK, model: engine.primary.name,
                                               fallback: config.fallback == .none ? nil : (config.fallback == .apple ? "Apple" : "Google"))
        statusItem.button?.toolTip = statusLine.title
    }

    // MARK: - Menu bar

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: ServerText.menuChecking, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        accessItem = item("⚠︎ Нужен доступ Accessibility для двойного ⌘C", #selector(openAccessibility))
        menu.addItem(accessItem)
        menu.addItem(.separator())
        menu.addItem(item("Открыть Tolk", #selector(openMain)))
        menu.addItem(item("Перевести буфер обмена", #selector(translateClipboard)))
        menu.addItem(item("Перевести область экрана  ⌥⇧S", #selector(captureScreen)))
        menu.addItem(.separator())
        quickMenuItems = [
            (QuickAction.translateReplace, item("", #selector(quickTranslate))),
            (QuickAction.polishReplace, item("", #selector(quickPolish))),
            (QuickAction.fixLayout, item("", #selector(quickFixLayout))),
        ]
        for (_, mi) in quickMenuItems { menu.addItem(mi) }
        refreshHotKeyLabels()
        menu.addItem(.separator())
        ttItem = item("Перевод при наборе", #selector(toggleTypeTranslate))
        menu.addItem(ttItem)
        let acMenuItem = NSMenuItem(title: "Автодополнение", action: nil, keyEquivalent: "")
        let acMenu = NSMenu()
        acItem = item("Включено (Tab)", #selector(toggleAutocomplete))
        acMenu.addItem(acItem)
        acStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        acStatusItem.isEnabled = false
        acMenu.addItem(acStatusItem)
        acStatsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        acStatsItem.isEnabled = false
        acMenu.addItem(acStatsItem)
        acRetryItem = item("Повторить запуск модели", #selector(retryAutocompleteServer))
        acRetryItem.isHidden = true
        acMenu.addItem(acRetryItem)
        acMenu.addItem(.separator())
        let flags: [(String, WritableKeyPath<TolkConfig, Bool>)] = [
            ("Исправлять опечатки", \.autocorrect), ("Эмодзи", \.autocompleteEmoji),
            ("Буфер обмена", \.autocompleteClipboard), ("Учиться на моих сообщениях", \.autocompleteLearnStyle)]
        acFlagItems = flags.map { (title, kp) in (item(title, #selector(toggleAutocompleteFlag(_:))), kp) }
        for (i, f) in acFlagItems.enumerated() { f.item.tag = i; acMenu.addItem(f.item) }
        let lengthItem = NSMenuItem(title: "Длина", action: nil, keyEquivalent: "")
        let lengthMenu = NSMenu()
        for (key, title) in [("short", "Короткая"), ("medium", "Средняя"), ("long", "Длинная")] {
            let it = item(title, #selector(setAutocompleteLength(_:)))
            it.representedObject = key
            lengthMenu.addItem(it)
            acLengthItems.append(it)
        }
        lengthItem.submenu = lengthMenu
        acMenu.addItem(lengthItem)
        let freqItem = NSMenuItem(title: "Частота", action: nil, keyEquivalent: "")
        let freqMenu = NSMenu()
        for (key, title) in [("rare", "Реже, но точнее"), ("normal", "Обычно"), ("often", "Чаще")] {
            let it = item(title, #selector(setAutocompleteFrequency(_:)))
            it.representedObject = key
            freqMenu.addItem(it)
            acFreqItems.append(it)
        }
        freqItem.submenu = freqMenu
        acMenu.addItem(freqItem)
        acMenu.addItem(.separator())
        acAppItem = item("", #selector(toggleAutocompleteForApp))
        acMenu.addItem(acAppItem)
        SuggestionJournal.shared.menuItems().forEach(acMenu.addItem)
        acMenuItem.submenu = acMenu
        menu.addItem(acMenuItem)
        refreshAutocompleteMenu()
        menu.addItem(.separator())
        profileItem = NSMenuItem(title: "Профиль", action: nil, keyEquivalent: "")
        profileItem.submenu = NSMenu()
        menu.addItem(profileItem)
        rebuildProfileMenu()
        menu.addItem(item("Глоссарий", #selector(openGlossary)))
        menu.addItem(item("Настройки…", #selector(openSettings)))
        menu.addItem(item("Как пользоваться", #selector(openHelp)))
        menu.addItem(item("Сообщить о проблеме…", #selector(reportProblem)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из Tolk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        showHealth(true)
        statusLine.title = ServerText.menuChecking
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func openMain() { mainWindow.show() }

    // MARK: - Glossary profiles

    private func rebuildProfileMenu() {
        guard let profileItem else { return }
        profileItem.title = "Профиль: \(config.activeProfile.name)"
        let sub = NSMenu()
        for p in config.profiles {
            let i = NSMenuItem(title: p.name, action: #selector(switchProfile(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.id
            i.state = p.id == config.activeProfileID ? .on : .off
            sub.addItem(i)
        }
        profileItem.submenu = sub
    }

    @objc private func switchProfile(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, id != config.activeProfileID else { return }
        var c = config
        c.activeProfileID = id
        try? c.save() // posts didChange → configChanged rebuilds the engine
    }

    /// A new profile starts with a style for its purpose instead of an empty file.
    static func ensureProfileFile(_ p: GlossaryProfile) {
        let path = (p.rulesPath as NSString).expandingTildeInPath
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let isHome = p.id == "home"
        let style = isHome ? """
        - Книги, статьи, документы, письма: естественный литературный язык, без канцелярита и кальки.
        - Сохраняй стиль и интонацию автора, имена и реалии; не упрощай и не пересказывай.
        - Названия и термины — так, как принято в русскоязычных изданиях.
        - Официальные документы — точно и нейтрально, без вольностей.
        """ : """
        - Пиши естественно, как носитель языка; сохраняй тон оригинала.
        """
        let text = """
        <!-- Профиль «\(p.name)»: правила и глоссарий Tolk. Редактируйте в разделе «Глоссарий». -->

        ## Стиль
        \(style)

        ## Глоссарий EN → RU (обратно — так же)

        """
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        Diagnostics.log("created rules file for profile \(p.id)")
    }
    @objc private func openHelp() { mainWindow.show(.help) }
    @objc private func reportProblem() { Diagnostics.copyProblemReport() }
    @objc private func openGlossary() { mainWindow.show(.glossary) }
    @objc private func openSettings() { mainWindow.show(.settings) }
    /// Screen area capture (⌥⇧S or menu). Rule (`CaptureFocus.route`): Tolk was the frontmost app and its big
    /// window is open → the image page gets the picture (preview, paragraphs, translation) and Tolk stays active;
    /// otherwise → OCR text in the popup and the focus goes back to the app the user was in.
    @objc private func captureScreen() {
        // Read at the moment of the press: a window that is merely visible behind another app does not count.
        let tolkWasFrontmost = NSWorkspace.shared.frontmostApplication == NSRunningApplication.current
        // Async: let the status menu close first, so it is not in the screenshot.
        DispatchQueue.main.async { [self] in
            if CaptureFocus.route(tolkWasFrontmost: tolkWasFrontmost, mainWindowUsable: mainWindowOnScreen) == .mainWindow {
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
        if popup.window?.isKeyWindow == true || reply.window?.isKeyWindow == true || (NSApp.isActive && NSApp.keyWindow != nil) {
            Diagnostics.log("double Cmd+C inside Tolk (\(NSApp.keyWindow?.title ?? "popup")) — ignored")
            return
        }
        Diagnostics.log("double Cmd+C: \(text.count) chars")
        popup.show(text: text, at: point)
    }

    @objc private func quickTranslate() { quickActions.perform(.translateReplace) }
    @objc private func quickPolish() { quickActions.perform(.polishReplace) }
    @objc private func quickFixLayout() { quickActions.perform(.fixLayout) }

    private var typeTranslateHotKey: HotKeyCombo? {
        QuickActionHotKeyStore().hotKey(id: QuickActionHotKeyStore.typeTranslateID, default: TypeTranslateController.defaultHotKey)
    }
    private static func hotKeySuffix(_ combo: HotKeyCombo?) -> String { combo.map { "  " + $0.display } ?? "" }

    /// Menu titles show the user's current shortcuts (settings → «Горячие клавиши»).
    private func refreshHotKeyLabels() {
        let titles: [String: String] = [
            QuickAction.translateReplace.id: "Перевести и заменить выделенное",
            QuickAction.polishReplace.id: "Причесать выделенное",
            QuickAction.fixLayout.id: "Исправить раскладку выделенного",
        ]
        for (action, mi) in quickMenuItems {
            mi.title = (titles[action.id] ?? action.title) + Self.hotKeySuffix(QuickActionHotKeyStore().hotKey(for: action))
        }
        if let ttItem, lastExternalApp == nil { ttItem.title = "Перевод при наборе" + Self.hotKeySuffix(typeTranslateHotKey) }
    }

    @objc private func hotKeysChanged() {
        quickActions.reregister()
        ttController?.reregister()
        refreshHotKeyLabels()
        refreshAutocompleteMenu()
    }

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
