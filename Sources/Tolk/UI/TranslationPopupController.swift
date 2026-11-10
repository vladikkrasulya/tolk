import AppKit
import TolkCore

/// Panel that can take keyboard focus (Esc, text selection, glossary form) without
/// activating the app, so the app the user copied from stays frontmost.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditShortcuts.handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// DeepL-style floating popup near the cursor that renders a streaming translation.
@MainActor
final class TranslationPopupController: NSObject, NSTextViewDelegate {
    private(set) var engine: TranslationEngine

    // Layout
    private let width: CGFloat = 460
    private let inset: CGFloat = 16
    private let minTextHeight: CGFloat = 22
    private let maxTextHeight: CGFloat = 340

    private var panel: PopupPanel!
    private var runner: TranslationRunner

    // Views
    private var directionButton: NSButton!
    private var providerBadge: BadgeView!
    private var spinner: NSProgressIndicator!
    private var noticeLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var textHeight: NSLayoutConstraint!
    private var glossaryForm: GlossaryFormView!
    private var toneControl: NSSegmentedControl!
    private var glossaryButton: NSButton!
    private var copyButton: NSButton!
    private var insertButton: NSButton!
    private var backButton: NSButton!
    private var backBox: NSStackView!
    private var backTitle: NSTextField!
    private var backText: NSTextField!
    private var notesBox: NSStackView!
    private var statusLine: StatusLineView!
    /// «🕒 10:00 EST → 16:00 у вас» under the translation (SF Symbol clock), only when a certain conversion was found.
    private var timeRow: NSStackView!
    private var timeLabel: NSTextField!
    private var notesButton: NSButton!
    private let notesJob = HintTask()
    private var lastProvider = ""
    private var presentGeneration = 0
    private var notesAfterBack = false
    private var resizeScheduled = false

    /// Called with the source text when the user expands the popup into the input window.
    var onExpand: ((String) -> Void)?
    /// «Варианты»: the big window opens with this text, the tone and chat context of this popup, and starts the variants.
    var onVariants: ((_ text: String, _ tone: Tone, _ threadContext: String?) -> Void)?
    private var variantsButton: NSButton!
    private var lastThreadContext: String?
    /// Tone for the app the user copied from (bundle id); used when the tone switch is "Авто".
    var toneForApp: ((String?) -> Tone)?
    /// «Ответить» (R): the app opens the reply window with this message.
    var onReply: ((ReplyContext) -> Void)?
    private var frontApp: String?
    private var frontAppRef: NSRunningApplication?
    private var replyButton: NSButton!
    // Editor pass («Отредактировать» / «Вернуть»)
    private var refineButton: NSButton!
    private let refiner = RefineRunner()
    private var beforeRefine: String?
    private var altBox: NSStackView!
    private let altJob = HintTask()
    private var altWork: DispatchWorkItem?

    // State
    private var sourceText = ""
    private var translation = ""
    private var requestedSource: Language?
    private var requestedTarget: Language?
    private var detectedSource: Language?
    private var detectedTarget: Language?
    private var fellBackFrom: String?
    private var showsPlaceholder = false
    private var mainFinished = false
    private let backJob = BackTranslationJob()
    /// The two toggles are shared with the «Перевод» page (HintsSettings).
    private var backEnabled: Bool {
        get { HintsSettings.backEnabled }
        set { HintsSettings.backEnabled = newValue }
    }
    private var notesEnabled: Bool {
        get { HintsSettings.notesEnabled }
        set { HintsSettings.notesEnabled = newValue }
    }
    /// Recently chosen target languages, newest first.
    private var recentTargets: [Language] {
        get { (UserDefaults.standard.stringArray(forKey: "tolk.recentTargets") ?? []).compactMap(Language.init) }
        set { UserDefaults.standard.set(newValue.prefix(4).map(\.rawValue), forKey: "tolk.recentTargets") }
    }
    private var tone: Tone {
        get { Tone(rawValue: UserDefaults.standard.string(forKey: "tolk.popup.tone") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tolk.popup.tone") }
    }

    // Placement
    private var anchor: NSPoint = .zero
    private var lastApply: CFTimeInterval = 0
    /// Where the panel is heading: an animation may still be running, and panel.frame is mid-way.
    private var targetFrame = NSRect.zero
    private let resizeInterval: CFTimeInterval = 0.11
    private var monitors: [Any] = []
    private var copyResetWork: DispatchWorkItem?

    init(engine: TranslationEngine) {
        self.engine = engine
        self.runner = TranslationRunner(engine: engine)
        super.init()
        runner.onUpdate = { [weak self] in self?.handle($0) }
        runner.onStats = { [weak self] in self?.statusLine?.finished($0) }
        backJob.onUpdate = { [weak self] in self?.handleBack($0) }
    }

    // MARK: - Public API

    /// Shows the popup at `point` (screen coords) and starts translating `text`.
    /// Callable from nonisolated code (e.g. `@objc` actions, event-tap callbacks); must run on the main thread.
    nonisolated func show(text: String, at point: NSPoint) {
        MainActor.assumeIsolated { self.present(text: text, at: point) }
    }

    #if DEBUG
    /// Dev: render the current popup to PNG.
    func renderForReview(to path: String) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        // Where the panel really is (multi-monitor checks) and which screen frames exist.
        let info = "panel=\(panel.frame) screens=\(NSScreen.screens.map { "\($0.frame) visible=\($0.visibleFrame)" })\n"
        try? info.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }
    #endif

    /// Swaps the engine after settings change (cancels anything running).
    func replaceEngine(_ new: TranslationEngine) {
        dismiss()
        engine = new
        runner = TranslationRunner(engine: new)
        runner.onUpdate = { [weak self] in self?.handle($0) }
        runner.onStats = { [weak self] in self?.statusLine?.finished($0) }
    }

    /// Hide at once, no fade: a quick action is about to send ⌘C/⌘V to the app underneath.
    func hideNow() {
        guard let panel, panel.isVisible else { return }
        presentGeneration += 1
        runner.cancel(); refiner.cancel(); backJob.cancel(); notesJob.cancel(); altJob.cancel(); altWork?.cancel()
        removeMonitors()
        stopWaiting()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// Nothing may keep ticking behind a hidden popup (spinner, the "model is loading" counter).
    private func stopWaiting() {
        spinner?.stopAnimation(nil)
        statusLine?.reset()
    }

    nonisolated func hide() {
        MainActor.assumeIsolated { self.dismiss() }
    }

    private func present(text: String, at point: NSPoint) {
        presentGeneration += 1
        buildIfNeeded()
        runner.cancel(); refiner.cancel()
        backJob.cancel()
        removeMonitors()

        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        frontAppRef = NSWorkspace.shared.frontmostApplication
        frontApp = frontAppRef?.bundleIdentifier
        requestedSource = nil
        requestedTarget = nil
        detectedSource = nil
        detectedTarget = nil
        anchor = point
        setGlossaryFormVisible(false)
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: tone) ?? 0

        // Measure with the final width before the first placement.
        panel.setContentSize(NSSize(width: width, height: 120))
        startTranslation()
        placeInitially()

        // Soft appearance instead of popping in.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        panel.makeKey() // .nonactivatingPanel: takes keystrokes, the other app stays active
        panel.makeFirstResponder(textView)
        #if DEBUG
        // Frame measurements must not be cut short by clicks the user makes elsewhere.
        if ProcessInfo.processInfo.environment["TOLK_FRAME_LOG"] == nil { installMonitors() }
        startFrameLog()
        #else
        installMonitors()
        #endif
    }

    #if DEBUG
    /// Dev (invisible render): the same start as `present`, but the panel is NEVER ordered in or made key — it only
    /// exists so that AppKit lays the views out and `renderInvisible` can draw them. alpha 0, far outside every screen,
    /// no monitors, no animation, no `orderFront*` / `makeKey*`. Returns false if the panel nevertheless became visible.
    func presentInvisibly(text: String, appearance: NSAppearance?) -> Bool {
        presentGeneration += 1
        buildIfNeeded()
        panel.alphaValue = 0
        panel.appearance = appearance
        panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        runner.cancel(); refiner.cancel(); backJob.cancel()
        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        frontApp = nil
        requestedSource = nil; requestedTarget = nil; detectedSource = nil; detectedTarget = nil
        anchor = NSPoint(x: 100, y: 800)
        setGlossaryFormVisible(false)
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: tone) ?? 0
        panel.setContentSize(NSSize(width: width, height: 120))
        startTranslation()
        return !panel.isVisible
    }

    var debugPanelVisible: Bool { panel?.isVisible ?? false }
    var debugFinished: Bool { mainFinished && !runner.isRunning }

    /// Draws the (invisible) popup to a PNG over a plain window-like background.
    func renderInvisible(to path: String, dark: Bool) {
        guard let view = panel?.contentView else { return }
        let size = fittingSize()
        panel.setContentSize(size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // The content hangs from the top of the (taller) view; in an unflipped view that is its upper part.
        let area = NSRect(x: 0, y: view.bounds.height - size.height, width: size.width, height: size.height)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: area) else { return }
        view.cacheDisplay(in: area, to: rep)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        let px = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        out.size = px // 1 unit = 1 pixel: whatever scale the off-screen panel picked, the PNG is 1:1 with `rep`
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        rep.draw(in: NSRect(origin: .zero, size: px))
        ctx.cgContext.setBlendMode(.destinationOver)
        ctx.cgContext.setFillColor(dark ? CGColor(srgbRed: 0.18, green: 0.18, blue: 0.19, alpha: 1)
                                        : CGColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1))
        ctx.cgContext.fill(CGRect(origin: .zero, size: px))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Dev: TOLK_FRAME_LOG=file samples the panel frame every 10 ms (only changes): "ms top height".
    private func startFrameLog() {
        guard let path = ProcessInfo.processInfo.environment["TOLK_FRAME_LOG"] else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        let t0 = Date()
        var last = NSRect.zero
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel, p.isVisible else { if self?.panel?.isVisible != true { t.invalidate() }; return }
                if p.frame != last {
                    last = p.frame
                    let line = String(format: "%5d top=%.1f y=%.1f h=%.1f\n", Int(Date().timeIntervalSince(t0) * 1000), p.frame.maxY, p.frame.minY, p.frame.height)
                    fh.write(line.data(using: .utf8)!)
                }
            }
        }
    }
    #endif

    private func dismiss() {
        runner.cancel(); refiner.cancel()
        backJob.cancel()
        notesJob.cancel()
        altJob.cancel()
        altWork?.cancel()
        removeMonitors()
        copyResetWork?.cancel()
        stopWaiting()
        guard let panel, panel.isVisible else { return }
        let generation = presentGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new show() during the fade wins — don't hide the fresh popup.
            MainActor.assumeIsolated {
                guard let self, self.presentGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    /// The popup's panel (nil until first shown) — lets the app tell it apart from other windows.
    var window: NSWindow? { panel }

    // MARK: - Translation

    private func resetRefine() {
        refiner.cancel()
        beforeRefine = nil
        refineButton?.isEnabled = false
        refineButton?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Отредактировать")
        refineButton?.toolTip = "Отредактировать. Второй проход: убрать кальки, сохранить смысл"
    }

    @objc private func refineClicked() {
        if let old = beforeRefine {   // «Вернуть»
            resetRefine()
            translation = old
            textView.string = ""
            textView.textStorage?.append(NSAttributedString(string: old, attributes: textAttributes))
            refineButton.isEnabled = true
            resetBack(); resetNotes(); hideAlternatives()
            updateSize()
            return
        }
        guard mainFinished, !translation.isEmpty, let from = requestedSource ?? detectedSource,
              let to = requestedTarget ?? detectedTarget else { return }
        let old = translation
        var refined = ""
        refineButton.isEnabled = false
        spinner.startAnimation(nil)
        resetBack(); resetNotes(); hideAlternatives()
        refiner.start(engine: engine, source: sourceText, translation: old, from: from, to: to, tone: effectiveTone,
                      onDelta: { [weak self] chunk in
            guard let self else { return }
            if refined.isEmpty { self.textView.string = "" }
            refined += chunk
            self.translation = refined
            self.textView.textStorage?.append(NSAttributedString(string: chunk, attributes: self.textAttributes))
            self.updateSize()
        }, onDone: { [weak self] in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            let t = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == old.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.translation = old
                self.textView.string = ""
                self.textView.textStorage?.append(NSAttributedString(string: old, attributes: self.textAttributes))
            } else {
                self.beforeRefine = old
                self.refineButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Вернуть")
                self.refineButton.toolTip = "Вернуть перевод до редактирования"
            }
            self.refineButton.isEnabled = true
            self.updateSize()
        }, onFail: { [weak self] message in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.translation = old
            self.textView.string = ""
            self.textView.textStorage?.append(NSAttributedString(string: old, attributes: self.textAttributes))
            self.refineButton.isEnabled = true
            self.showNotice(message, color: .systemRed)
        })
    }

    private func showTimeConversions() {
        let lines = TimezoneLine.lines(in: sourceText)
        timeRow.isHidden = lines.isEmpty
        guard !lines.isEmpty else { return }
        timeLabel.stringValue = lines.joined(separator: "; ")
        updateSize()
    }

    /// «Перевести заново»: the next request skips the in-memory cache.
    private var bypassNext = false
    private func retranslate() {
        guard !sourceText.isEmpty, !runner.isRunning else { return }
        bypassNext = true
        startTranslation()
    }

    private func startTranslation() {
        timeRow.isHidden = true
        resetRefine()
        translation = ""
        fellBackFrom = nil
        mainFinished = false
        noticeLabel.isHidden = true
        copyButton.isEnabled = false
        insertButton.isEnabled = false
        replyButton.isEnabled = false
        variantsButton?.isEnabled = false
        glossaryButton.isEnabled = false
        notesAfterBack = false
        resetBack()
        resetNotes()
        hideAlternatives()
        resetCopyButton()

        guard !sourceText.isEmpty else {
            providerBadge.text = ""
            directionButton.title = "Перевод"
            showMessage("Нет текста. Выделите текст и дважды нажмите ⌘C.", color: .secondaryLabelColor)
            return
        }
        updateDirectionTitle()
        providerBadge.text = ""
        spinner.startAnimation(nil)
        showMessage("Перевожу…", color: .tertiaryLabelColor)
        showsPlaceholder = true
        statusLine.waiting(provider: "…")
        var request = TranslationRequest(text: sourceText, source: requestedSource,
                                         target: requestedTarget, tone: effectiveTone)
        // Short replies from the same chat get the previous lines as context (pronouns), never translated.
        request.threadContext = ThreadMemory.shared.context(for: sourceText, app: frontApp)
        lastThreadContext = request.threadContext
        request.bypassCache = bypassNext
        bypassNext = false
        runner.start(request)
    }

    /// Manual tone wins; "Авто" picks the tone configured for the app the text came from (Slack → chat, Mail → formal).
    private var effectiveTone: Tone { tone == .auto ? (toneForApp?(frontApp) ?? .auto) : tone }

    private func handle(_ update: TranslationRunner.Update) {
        switch update {
        case let .started(provider, source, target):
            statusLine.waiting(provider: provider)
            detectedSource = source
            detectedTarget = target
            updateDirectionTitle()
            lastProvider = provider
            providerBadge.text = UIText.providerName(provider)
            providerBadge.tint = UIText.isFallbackProvider(provider) ? .systemOrange : .secondaryLabelColor
            if let from = fellBackFrom {
                showNotice(UIText.fallbackDone(from: from, to: provider),
                           color: .systemOrange)
            }
        case let .delta(chunk):
            statusLine.chunk()
            if showsPlaceholder {
                showsPlaceholder = false
                textView.string = ""
            }
            translation += chunk
            textView.textStorage?.append(NSAttributedString(string: chunk, attributes: textAttributes))
            copyButton.isEnabled = true
            insertButton.isEnabled = frontApp != Bundle.main.bundleIdentifier
            replyButton.isEnabled = true
            variantsButton.isEnabled = true
            glossaryButton.isEnabled = true
            updateSize()
        case let .fellBack(from, reason):
            statusLine.fellBack(reason: reason)
            fellBackFrom = from
            translation = ""
            showMessage("Перевожу через запасной сервис…", color: .tertiaryLabelColor)
            showsPlaceholder = true
            copyButton.isEnabled = false
            showNotice(UIText.fallbackSwitching(from: from), color: .systemOrange)
            noticeLabel.toolTip = reason
        case .finished:
            spinner.stopAnimation(nil)
            mainFinished = true
            if !translation.isEmpty, let f = detectedSource, let t = detectedTarget {
                ThreadMemory.shared.record(source: sourceText, translation: translation, from: f, to: t, app: frontApp)
            }
            if translation.isEmpty { showMessage("Пустой перевод.", color: .secondaryLabelColor) }
            else {
                showTimeConversions()
                refineButton.isEnabled = true
                // Two Ollama slots: back-translation first, footnotes after it — so a word-alternatives
                // request or another user is not stuck behind both.
                if backEnabled { notesAfterBack = notesEnabled; startBack() }
                else if notesEnabled { startNotes() }
            }
        case let .failed(message):
            // The text area already shows the full message; the status line stays short (no duplicate).
            statusLine.failed(translation.isEmpty ? "Перевод не удался" : message)
            spinner.stopAnimation(nil)
            if translation.isEmpty {
                showMessage(message, color: .systemRed)
            } else {
                showNotice(message, color: .systemRed)
            }
        }
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
    }

    private func showMessage(_ text: String, color: NSColor) {
        var attrs = textAttributes
        attrs[.foregroundColor] = color
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        showsPlaceholder = true
        updateSize()
    }

    private func showNotice(_ text: String, color: NSColor) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = color
        noticeLabel.isHidden = false
        updateSize()
    }

    // MARK: - Direction & tone

    private func updateDirectionTitle() {
        let src = (requestedSource ?? detectedSource).map { "\($0.flag) \(UIText.capitalized($0))" } ?? "Авто"
        let dst = (requestedTarget ?? detectedTarget).map { "\($0.flag) \(UIText.capitalized($0))" } ?? "…"
        directionButton.title = "\(src)  →  \(dst)"
        directionButton.toolTip = requestedTarget == nil
            ? "Направление определяется автоматически. Нажмите, чтобы выбрать."
            : "Направление выбрано вручную"
    }

    @objc private func showDirectionMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let auto = NSMenuItem(title: "Определять автоматически", action: #selector(chooseAuto), keyEquivalent: "")
        auto.target = self
        auto.state = requestedTarget == nil ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        func addLanguage(_ lang: Language) {
            let item = NSMenuItem(title: "\(lang.flag)  \(UIText.capitalized(lang))", action: #selector(chooseTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = requestedTarget == lang ? .on : .off
            menu.addItem(item)
        }
        let recents = recentTargets
        if !recents.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Недавние"))
            recents.forEach(addLanguage)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem.sectionHeader(title: "Перевести на"))
        Language.allCases.sorted { $0.russianName < $1.russianName }.forEach(addLanguage)
        menu.addItem(.separator())
        let swap = NSMenuItem(title: "Поменять направление", action: #selector(swapDirection), keyEquivalent: "")
        swap.target = self
        swap.isEnabled = detectedSource != nil
        menu.addItem(swap)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func chooseAuto() {
        requestedSource = nil
        requestedTarget = nil
        startTranslation()
    }

    @objc private func chooseTarget(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let lang = Language(rawValue: raw) else { return }
        requestedTarget = lang
        recentTargets = [lang] + recentTargets.filter { $0 != lang }
        // Keep the detected source unless it equals the new target (then let the engine detect).
        requestedSource = (requestedSource == lang) ? nil : requestedSource
        startTranslation()
    }

    @objc private func swapDirection() {
        guard let src = requestedSource ?? detectedSource, let dst = requestedTarget ?? detectedTarget else { return }
        requestedSource = dst
        requestedTarget = src
        startTranslation()
    }

    @objc private func toneChanged(_ sender: NSSegmentedControl) {
        let new = Tone.allCases[max(0, sender.selectedSegment)]
        guard new != tone else { return }
        tone = new
        startTranslation()
    }

    // MARK: - Actions

    @objc private func copyTranslation() {
        guard !translation.isEmpty else { return }
        Clipboard.copy(translation)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Скопировано")
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resetCopyButton() }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func resetCopyButton() { copyButton?.title = ""; copyButton?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) }

    /// DeepL's "Insert": put the translation in place of the selection in the app the user copied from.
    @objc private func insertTranslation() {
        guard !translation.isEmpty else { return }
        Clipboard.copy(translation)
        dismiss()
        // The popup never activated our app, so the source app is still frontmost: paste there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // kVK_ANSI_V
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.setIntegerValueField(.eventSourceUserData, value: DoubleCopyMonitor.syntheticMarker)
            up?.setIntegerValueField(.eventSourceUserData, value: DoubleCopyMonitor.syntheticMarker)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Partner's message → reply window (their text stays on top while you write the answer).
    @objc private func replyClicked() {
        guard !translation.isEmpty, let src = detectedSource else { return }
        let ctx = ReplyContext(partnerText: sourceText, partnerTranslation: translation, partnerLanguage: src,
                               app: frontApp == Bundle.main.bundleIdentifier ? nil : frontAppRef,
                               anchor: NSPoint(x: panel.frame.minX + 24, y: panel.frame.maxY + 18))
        dismiss()
        onReply?(ctx)
    }

    @objc private func variantsClicked() {
        let text = sourceText, tone = effectiveTone, thread = lastThreadContext
        dismiss()
        onVariants?(text, tone, thread)
    }

    @objc private func expandClicked() {
        let text = sourceText
        dismiss()
        onExpand?(text)
    }

    // MARK: - Alternatives (select a word/phrase in the translation)

    func textViewDidChangeSelection(_ notification: Notification) {
        altWork?.cancel()
        guard mainFinished, !showsPlaceholder, !UIText.isFallbackProvider(lastProvider) else { return }
        let range = textView.selectedRange()
        guard range.length > 0, range.length <= 60, NSMaxRange(range) <= (textView.string as NSString).length else {
            hideAlternatives(); return
        }
        let fragment = (textView.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty, fragment.count >= 2 else { hideAlternatives(); return }
        // Wait until the user stops dragging the selection.
        let work = DispatchWorkItem { [weak self] in self?.loadAlternatives(fragment: fragment, range: range) }
        altWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func loadAlternatives(fragment: String, range: NSRange) {
        guard let src = detectedSource, let dst = detectedTarget else { return }
        altJob.cancel()
        showAlternatives(fragment: fragment, range: range, options: nil)
        let engine = self.engine, source = sourceText, translated = translation
        altJob.run({ await engine.alternatives(for: fragment, in: translated, source: source, from: src, to: dst) }) { [weak self] options in
            guard let self, self.translation == translated, self.textView.selectedRange() == range else { return }
            self.showAlternatives(fragment: fragment, range: range, options: options)
        }
    }

    private func showAlternatives(fragment: String, range: NSRange, options: [String]?) {
        altBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = UIFactory.label("«\(fragment)»:", size: 11.5, weight: .semibold, color: .secondaryLabelColor)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        altBox.addArrangedSubview(title)
        if let options {
            if options.isEmpty {
                altBox.addArrangedSubview(UIFactory.label("вариантов нет", size: 11.5, color: .tertiaryLabelColor))
            }
            for o in options {
                let b = ClosureButton(title: o) { [weak self] in self?.applyAlternative(o, range: range) }
                b.toolTip = "Заменить «\(fragment)» на «\(o)»"
                altBox.addArrangedSubview(b)
            }
        } else {
            altBox.addArrangedSubview(UIFactory.label("подбираю варианты…", size: 11.5, color: .tertiaryLabelColor))
        }
        altBox.addArrangedSubview(UIFactory.spacer())
        altBox.isHidden = false
        updateSize()
    }

    private func hideAlternatives() {
        altJob.cancel()
        guard altBox != nil, !altBox.isHidden else { return }
        altBox.isHidden = true
        updateSize()
    }

    private func applyAlternative(_ text: String, range: NSRange) {
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: textAttributes))
        translation = textView.string
        hideAlternatives()
        textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
        showNotice("Заменено. ⌘C или «Копировать» — уже с этим вариантом.", color: .secondaryLabelColor)
    }

    // MARK: - Footnotes

    @objc private func toggleNotes() {
        notesEnabled = notesButton.state == .on
        if notesEnabled { if mainFinished, !translation.isEmpty { startNotes() } }
        else { resetNotes() }
    }

    private func resetNotes() {
        notesJob.cancel()
        notesButton.state = notesEnabled ? .on : .off
        notesBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        notesBox.isHidden = true
        updateSize()
    }

    private func startNotes() {
        // Notes come from Qwen; with the Google fallback there is no model to ask.
        guard !UIText.isFallbackProvider(lastProvider), let src = detectedSource, let dst = detectedTarget else { return }
        let source = sourceText, translated = translation, engine = self.engine
        showNotesLoading()
        notesJob.run({ await engine.notes(source: source, translation: translated, from: src, to: dst) }) { [weak self] notes in
            guard let self, self.translation == translated else { return }
            self.showNotes(notes)
        }
    }

    private func showNotesLoading() {
        notesBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let l = UIFactory.label("Ищу спорные термины…", size: 11.5, color: .tertiaryLabelColor)
        notesBox.addArrangedSubview(l)
        notesBox.isHidden = false
        updateSize()
    }

    private func showNotes(_ notes: [TranslationNote]) {
        notesBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !notes.isEmpty else { notesBox.isHidden = true; updateSize(); return }
        let title = UIFactory.label("Сноски", size: 11, weight: .semibold, color: .tertiaryLabelColor)
        notesBox.addArrangedSubview(title)
        for (i, n) in notes.enumerated() {
            notesBox.addArrangedSubview(noteRow(n, index: i + 1))
        }
        notesBox.isHidden = false
        updateSize()
    }

    private func noteRow(_ n: TranslationNote, index: Int) -> NSView {
        NoteRow.make(n, index: index, width: width - inset * 2 - 20) { [weak self] value, retranslate in
            self?.saveNote(term: n.term, value: value, retranslate: retranslate)
        }
    }

    private func saveNote(term: String, value: String, retranslate: Bool) {
        do {
            try engine.addGlossaryTerm(source: term, translation: value)
            if retranslate {
                startTranslation()
                showNotice("В глоссарии: «\(term)» → «\(value)». Перевожу заново.", color: .systemGreen)
            } else {
                showNotice("В глоссарии: «\(term)» → «\(value)»", color: .systemGreen)
            }
        } catch {
            showNotice("Не удалось сохранить в глоссарий: \(error.localizedDescription)", color: .systemRed)
        }
    }

    // MARK: - Back-translation

    @objc private func toggleBack() {
        backEnabled = backButton.state == .on
        if backEnabled {
            backBox.isHidden = false
            if mainFinished, !translation.isEmpty { startBack() } else { setBack(title: "Обратный перевод", text: "Появится после перевода…", color: .tertiaryLabelColor) }
        } else {
            backJob.cancel()
            backBox.isHidden = true
        }
        updateSize()
    }

    private func resetBack() {
        backJob.cancel()
        backButton.state = backEnabled ? .on : .off
        backBox.isHidden = !backEnabled
        if backEnabled { setBack(title: "Обратный перевод", text: "Появится после перевода…", color: .tertiaryLabelColor) }
    }

    private func startBack() {
        guard let src = detectedTarget, let dst = detectedSource else { return }
        backBox.isHidden = false
        setBack(title: "Обратно: \(src.flag) → \(dst.flag) \(UIText.capitalized(dst))", text: "Перевожу обратно…", color: .tertiaryLabelColor)
        updateSize()
        backJob.start(engine: engine, translation: translation, from: src, to: dst)
    }

    private func handleBack(_ update: BackTranslationJob.Update) {
        switch update {
        case let .running(text):
            if !text.isEmpty { setBack(title: nil, text: text, color: .secondaryLabelColor) }
        case let .finished(text):
            if text.isEmpty { setBack(title: nil, text: "—", color: .tertiaryLabelColor) }
            startPendingNotes()
        case let .failed(message):
            setBack(title: nil, text: message, color: .systemRed)
            startPendingNotes()
        }
    }

    private func startPendingNotes() {
        guard notesAfterBack else { return }
        notesAfterBack = false
        if notesEnabled { startNotes() }
    }

    private func setBack(title: String?, text: String, color: NSColor) {
        if let title { backTitle.stringValue = title }
        backText.stringValue = text
        backText.textColor = color
        updateSize()
    }

    @objc private func closeClicked() { dismiss() }

    @objc private func toggleGlossaryForm() {
        let show = glossaryForm.isHidden
        if show {
            glossaryForm.fill(term: sourceText.count <= 60 ? sourceText : "",
                              value: translation.count <= 60 ? translation.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
        setGlossaryFormVisible(show)
        if show { glossaryForm.focusTerm() }
    }

    private func setGlossaryFormVisible(_ visible: Bool) {
        glossaryForm.isHidden = !visible
        glossaryButton.state = visible ? .on : .off
        updateSize()
    }

    private func saveGlossaryTerm(term: String, value: String) {
        do {
            try engine.addGlossaryTerm(source: term, translation: value)
            setGlossaryFormVisible(false)
            showNotice("Добавлено в глоссарий: «\(term)» → «\(value)»", color: .systemGreen)
            panel.makeFirstResponder(textView)
        } catch {
            showNotice("Не удалось сохранить в глоссарий: \(error.localizedDescription)", color: .systemRed)
        }
    }

    private func cancelGlossary() {
        setGlossaryFormVisible(false)
        panel.makeFirstResponder(textView)
    }

    // MARK: - Monitors (Esc, click outside)

    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            if event.keyCode == 36, event.modifierFlags.contains(.command) { self.insertTranslation(); return nil }
            // R — reply (only when not typing in the glossary form).
            if event.keyCode == 15, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               self.glossaryForm.isHidden, self.replyButton.isEnabled { self.replyClicked(); return nil }
            if event.keyCode == 8, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               self.textView.selectedRange().length == 0 { self.copyTranslation(); return nil }
            guard event.keyCode == 53 else { return event }
            if !self.glossaryForm.isHidden { self.cancelGlossary() } else { self.dismiss() }
            return nil
        }) { monitors.append(m) }

        // Esc while another app has the keyboard (works when Accessibility is granted).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(m) }

        // Clicks in other apps.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(m) }

        // Clicks in our other windows (e.g. the input window). Menus run at a higher level — ignore them.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, let w = event.window, w !== self.panel, w.level < .popUpMenu else { return event }
            self.dismiss()
            return event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    // MARK: - Placement & size

    private func screen(for point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func placeInitially() {
        let size = fittingSize()
        let vf = screen(for: anchor).visibleFrame
        // The top edge is the anchor: the popup grows downwards, along the text. If the grown
        // popup runs out of room, applySize() moves it up once.
        let top = min(anchor.y - 18, vf.maxY - 8)
        let x = anchor.x - 24
        panel.setFrame(clamped(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), in: vf), display: true)
        lastApply = 0
        targetFrame = panel.frame
    }

    private func fittingSize() -> NSSize {
        guard let content = panel.contentView else { return .zero }
        content.layoutSubtreeIfNeeded()
        textHeight.constant = measuredTextHeight()
        content.layoutSubtreeIfNeeded()
        return NSSize(width: width, height: ceil(content.fittingSize.height))
    }

    private func measuredTextHeight() -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return minTextHeight }
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height + textView.textContainerInset.height * 2)
        let vf = screen(for: anchor).visibleFrame
        let cap = min(maxTextHeight, vf.height * 0.55)
        scrollView.hasVerticalScroller = h > cap
        return min(max(h, minTextHeight), cap)
    }

    /// Streaming calls this on every chunk; the height changes at most ~9 times a second
    /// (leading edge immediately, then at most one step per `resizeInterval`), each step animated.
    private func updateSize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        let wait = max(0, lastApply + resizeInterval - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                self?.resizeScheduled = false
                self?.applySize()
            }
        }
    }

    private func applySize() {
        guard let panel, panel.isVisible || panel.frame.width > 0 else { return }
        lastApply = CACurrentMediaTime()
        let size = fittingSize()
        let vf = screen(for: anchor).visibleFrame
        // Mid-animation panel.frame is a transient value: build on where it is heading. Once the
        // size has settled use the real frame (the user may have dragged the popup).
        var frame = (targetFrame != .zero && panel.frame.size != targetFrame.size) ? targetFrame : panel.frame
        let previous = frame
        let top = frame.maxY // the top edge never follows the content
        frame.size = size
        frame.origin.y = top - size.height
        if frame.minY < vf.minY + 8 {
            // No room below: move up once, straight to where the fully grown popup fits.
            let fullHeight = size.height - textHeight.constant + min(maxTextHeight, vf.height * 0.55)
            let newTop = min(vf.minY + 8 + max(fullHeight + 20, size.height), vf.maxY - 8) // +20: status line appears at the end
            frame.origin.y = newTop - size.height
        }
        frame.origin.x = min(max(frame.minX, vf.minX + 8), vf.maxX - frame.width - 8)
        if frame != panel.frame || frame != targetFrame {
            let moved = frame.maxY != previous.maxY
            targetFrame = frame
            if panel.isVisible, abs(frame.height - panel.frame.height) < 400 {
                NSAnimationContext.runAnimationGroup { ctx in
                    // The one-off move up (no room below) is longer than a plain growth step.
                    ctx.duration = moved ? 0.25 : 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
        // Follow the end only once the text has reached its maximum height and scrolls.
        if !showsPlaceholder, scrollView.hasVerticalScroller { textView.scrollToEndOfDocument(nil) }
    }

    private func clamped(_ r: NSRect, in vf: NSRect) -> NSRect {
        var r = r
        let m: CGFloat = 8
        r.origin.x = min(max(r.minX, vf.minX + m), vf.maxX - r.width - m)
        if r.maxY > vf.maxY - m { r.origin.y = vf.maxY - m - r.height }
        if r.minY < vf.minY + m { r.origin.y = vf.minY + m }
        return r
    }

    // MARK: - Building

    private func buildIfNeeded() {
        guard panel == nil else { return }

        let p = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false
        p.isMovableByWindowBackground = true
        p.animationBehavior = .utilityWindow
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        panel = p

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        p.contentView = effect

        // Header: direction, swap, provider, spinner … close
        directionButton = NSButton(title: "Авто → …", target: self, action: #selector(showDirectionMenu(_:)))
        directionButton.isBordered = false
        directionButton.font = .systemFont(ofSize: 13, weight: .semibold)
        directionButton.contentTintColor = .labelColor
        directionButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        directionButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        directionButton.imagePosition = .imageTrailing

        let swapButton = UIFactory.symbolButton("arrow.left.arrow.right", tooltip: "Поменять направление",
                                                target: self, action: #selector(swapDirection))
        providerBadge = UIFactory.badge()
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let close = UIFactory.symbolButton("xmark", tooltip: EscText.closeTip, target: self, action: #selector(closeClicked))
        let expand = UIFactory.symbolButton("arrow.up.left.and.arrow.down.right", tooltip: "Открыть в окне перевода",
                                            target: self, action: #selector(expandClicked))

        // «Варианты» sits beside «Открыть в окне»: it opens the same window and starts the variants there (the footer has no room).
        variantsButton = UIFactory.symbolButton("list.bullet.rectangle", tooltip: "Варианты перевода: 2–3 версии с пояснением, чем отличаются (откроется окно перевода)",
                                                target: self, action: #selector(variantsClicked))
        variantsButton.isEnabled = false
        let header = NSStackView(views: [directionButton, swapButton, providerBadge, spinner, UIFactory.spacer(), variantsButton, expand, close])
        header.orientation = .horizontal
        header.spacing = 6

        noticeLabel = UIFactory.wrappingLabel("", size: 11.5, color: .systemOrange)
        noticeLabel.isHidden = true

        // Translation text
        scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        textView = scrollView.documentView as? NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = .systemFont(ofSize: 16)
        textView.setAccessibilityLabel("Перевод")
        textView.delegate = self
        textHeight = scrollView.heightAnchor.constraint(equalToConstant: minTextHeight)
        textHeight.isActive = true

        // Glossary form
        glossaryForm = GlossaryFormView(defaultButton: true)
        glossaryForm.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 2, right: 0)
        glossaryForm.onSave = { [weak self] term, value in self?.saveGlossaryTerm(term: term, value: value) }
        glossaryForm.onCancel = { [weak self] in self?.cancelGlossary() }
        glossaryForm.isHidden = true

        // Back-translation: the translation translated back, to check the meaning survived.
        backTitle = UIFactory.label("Обратный перевод", size: 11, weight: .semibold, color: .tertiaryLabelColor)
        backText = UIFactory.wrappingLabel("", size: 13, color: .secondaryLabelColor)
        backText.isSelectable = true
        backText.preferredMaxLayoutWidth = width - inset * 2 - 20
        backBox = NSStackView(views: [backTitle, backText])
        backBox.orientation = .vertical
        backBox.alignment = .leading
        backBox.spacing = 4
        backBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        backBox.wantsLayer = true
        backBox.layer?.cornerRadius = 8
        backBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        backBox.isHidden = true

        statusLine = StatusLineView()
        statusLine.onRetranslate = { [weak self] in self?.retranslate() }

        let clock = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: "Время") ?? NSImage())
        clock.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        clock.contentTintColor = .secondaryLabelColor
        clock.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel = UIFactory.wrappingLabel("", size: 12, color: .secondaryLabelColor)
        timeRow = NSStackView(views: [clock, timeLabel])
        timeRow.orientation = .horizontal
        timeRow.alignment = .firstBaseline
        timeRow.spacing = 5
        timeRow.isHidden = true

        altBox = NSStackView()
        altBox.orientation = .horizontal
        altBox.spacing = 6
        altBox.isHidden = true

        notesBox = NSStackView()
        notesBox.orientation = .vertical
        notesBox.alignment = .leading
        notesBox.spacing = 8
        notesBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        notesBox.wantsLayer = true
        notesBox.layer?.cornerRadius = 8
        notesBox.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.08).cgColor
        notesBox.isHidden = true

        // Footer: tone … glossary, copy
        toneControl = UIFactory.toneControl(target: self, action: #selector(toneChanged(_:)))
        glossaryButton = NSButton(title: "", target: self, action: #selector(toggleGlossaryForm))
        glossaryButton.setButtonType(.pushOnPushOff)
        copyButton = NSButton(title: "", target: self, action: #selector(copyTranslation))
        for b in [glossaryButton!, copyButton!] {
            b.controlSize = .small
            b.bezelStyle = .push
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        glossaryButton.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        glossaryButton.imagePosition = .imageOnly
        copyButton.imagePosition = .imageOnly
        backButton = NSButton(title: "", target: self, action: #selector(toggleBack))
        backButton.setButtonType(.pushOnPushOff)
        backButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        backButton.toolTip = "Обратный перевод — проверить, что смысл не потерялся"
        notesButton = NSButton(title: "", target: self, action: #selector(toggleNotes))
        notesButton.setButtonType(.pushOnPushOff)
        notesButton.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil)
        notesButton.imagePosition = .imageOnly
        notesButton.toolTip = "Сноски: пояснения к спорным отраслевым терминам"
        notesButton.controlSize = .small
        notesButton.bezelStyle = .push
        insertButton = NSButton(title: "", target: self, action: #selector(insertTranslation))
        insertButton.image = NSImage(systemSymbolName: "text.insert", accessibilityDescription: nil)
        insertButton.toolTip = "Заменить выделенный текст переводом (⌘↩)"
        for b in [backButton!, insertButton!] {
            b.controlSize = .small
            b.bezelStyle = .push
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.imagePosition = .imageOnly
        }
        glossaryButton.toolTip = "Добавить термин в глоссарий"
        copyButton.toolTip = "Копировать перевод (⌘C)"
        // The tone switch must never be squeezed into «А… Чат П…».
        toneControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        toneControl.setContentHuggingPriority(.required, for: .horizontal)
        replyButton = NSButton(title: "Ответить", target: self, action: #selector(replyClicked))
        replyButton.image = NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: nil)
        replyButton.imagePosition = .imageLeading
        replyButton.bezelStyle = .push
        replyButton.controlSize = .small
        replyButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replyButton.toolTip = "Ответить партнёру: пишите по-своему, перевод — на его язык (R)"
        replyButton.isEnabled = false
        replyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refineButton = NSButton(title: "", target: self, action: #selector(refineClicked))
        refineButton.controlSize = .small
        refineButton.bezelStyle = .push
        refineButton.imagePosition = .imageOnly
        refineButton.isEnabled = false
        resetRefine()
        for b in [backButton!, notesButton!, refineButton!, glossaryButton!, copyButton!, insertButton!] {
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true  // equal icon buttons
        }
        let footer = NSStackView(views: [toneControl, UIFactory.spacer(), backButton, notesButton, refineButton, glossaryButton, copyButton, insertButton, replyButton])
        footer.orientation = .horizontal
        footer.spacing = 6

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSStackView(views: [header, noticeLabel, scrollView, timeRow, statusLine, altBox, notesBox, backBox, glossaryForm, separator, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: inset, bottom: 12, right: inset)
        root.setCustomSpacing(10, after: scrollView)
        root.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            effect.widthAnchor.constraint(equalToConstant: width),
        ])
        for v in [header, noticeLabel!, scrollView!, timeRow!, statusLine!, altBox!, notesBox!, backBox!, glossaryForm!, separator, footer] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -inset * 2).isActive = true
        }
        noticeLabel.preferredMaxLayoutWidth = width - inset * 2
        timeLabel.preferredMaxLayoutWidth = width - inset * 2 - 20
    }
}
