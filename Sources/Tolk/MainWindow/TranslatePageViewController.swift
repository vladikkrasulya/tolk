import AppKit
import TolkCore

/// Dashed frame «отпустите файл» shown while a document is dragged over the page; never takes mouse events.
private final class DropOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 10, dy: 10)
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        let text = "Отпустите файл — он откроется в «Документах»" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

/// Root view of the translate page: catches ⌘↩ wherever the focus is inside the page and accepts dropped files.
private final class TranslatePageView: NSView {
    var onCommandReturn: (() -> Void)?
    var onRetranslate: (() -> Void)?
    /// A document was dropped (nil: the page does not take files).
    var onFileDrop: ((URL) -> Void)?
    let dropOverlay = DropOverlay()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called last by `loadView`, so that the frame lies above the cards.
    func installOverlay() {
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay.isHidden = true
        addSubview(dropOverlay)
        NSLayoutConstraint.activate([
            dropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor), dropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropOverlay.topAnchor.constraint(equalTo: topAnchor), dropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func showDropTarget(_ on: Bool) {
        dropOverlay.isHidden = !on
        dropOverlay.needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onFileDrop != nil, PlaceholderTextView.droppedFile(sender) != nil else { return [] }
        showDropTarget(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDrop != nil && PlaceholderTextView.droppedFile(sender) != nil ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { showDropTarget(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropTarget(false)
        guard let url = PlaceholderTextView.droppedFile(sender) else { return false }
        onFileDrop?(url)
        return onFileDrop != nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command, event.keyCode == 36 || event.keyCode == 76,
           window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: self) ?? false }) ?? false {
            onCommandReturn?()
            return true
        }
        if event.type == .keyDown, flags == .command, event.charactersIgnoringModifiers == "r",
           window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: self) ?? false }) ?? false {
            onRetranslate?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Notice in the bottom line: while it shows, it takes the place of the status line.
private final class NoticeLabel: NSTextField {
    var onVisibility: (() -> Void)?
    override var isHidden: Bool { didSet { onVisibility?() } }
}

/// Button that tells when it gets enabled / disabled (the rewrite buttons follow the editor button).
private final class FollowButton: NSButton {
    var onEnabledChange: (() -> Void)?
    override var isEnabled: Bool { didSet { onEnabledChange?() } }
}

/// "Перевод" page: text in, live translation out. Used embedded in the main window and,
/// wrapped by `InputWindowController`, as the standalone translate window.
@MainActor
final class TranslatePageViewController: NSViewController, NSTextViewDelegate {
    /// Replaceable: after `TolkConfig.didChange` the app may rebuild the engine and assign it here.
    var engine: TranslationEngine {
        didSet {
            runner.cancel()
            runner = TranslationRunner(engine: engine)
            runner.onUpdate = { [weak self] in self?.handle($0) }
            runner.onStats = { [weak self] in self?.gotStats($0) }
            messageRunner?.cancel()
            messageRunner = makeMessageRunner()
            cancelRewrite()
            lastTranslatedRequest = nil
            live.reset()
            hints?.engine = engine
            hints?.invalidate()
            updateHintsVisibility()
            if isViewLoaded {
                spinner.stopAnimation(nil)
                DispatchQueue.main.async { [weak self] in self?.translateNow(force: true) }
            }
        }
    }
    private var runner: TranslationRunner
    private var statusLine: StatusLineView!
    private let debounce: Duration = .milliseconds(400)

    /// ⌘↩. Default (nil): copy the translation. The standalone window sets "copy and close".
    var onCommandReturn: (() -> Void)?
    /// Esc inside the input. nil = ignored.
    var onEscape: (() -> Void)?
    /// Hint in the footer under the panes.
    var footerHint = "⌘↩ — скопировать перевод" { didSet { if isViewLoaded { hintLabel.stringValue = footerHint } } }
    /// Extra top inset (the standalone window has a transparent title bar).
    var topInset: CGFloat = 16 { didSet { if isViewLoaded { rootTop?.constant = topInset } } }

    private var sourcePopup: NSPopUpButton!
    private var targetPopup: NSPopUpButton!
    private var toneControl: NSSegmentedControl!
    private var providerBadge: BadgeView!
    private var spinner: NSProgressIndicator!
    private var inputView: PlaceholderTextView!
    private var outputView: NSTextView!
    /// The output pane draws its own placeholder ("Перевод" / "Перевожу…"), like the input pane.
    private var outputPlaceholderView: PlaceholderTextView { outputView as! PlaceholderTextView }
    private var counterLabel: NSTextField!
    private var clearButton: NSButton!
    private var noticeLabel: NSTextField!
    private var copyButton: NSButton!
    private var hintLabel: NSTextField!
    private var rootTop: NSLayoutConstraint?

    private var debounceTask: Task<Void, Never>?
    private(set) var translation = ""
    private var lastTranslatedRequest: TranslationRequest?
    private var detectedSource: Language?
    private var detectedTarget: Language?
    private var fellBackFrom: String?
    private var awaitingFirstDelta = false
    private var copyResetWork: DispatchWorkItem?

    // Live typing: sentence cache + the current request's plan.
    private let live = LiveTranslation()
    private var step: LiveTranslation.Step?
    private var keptPrefix = ""
    private var tail = ""
    private var finalPassTask: Task<Void, Never>?
    // Editor pass
    private let refiner = RefineRunner()
    private var refineButton: NSButton!
    private var beforeRefine: String?
    // Rewrite (Короче / Мягче / …)
    private var rewriteBar: RewriteBar!
    private var rewriteTask: Task<Void, Never>?
    private var rewriteGeneration = 0
    private var noticeWork: DispatchWorkItem?
    // Sentence pairs, glossary marks
    private var pairs: [SentencePair] = []
    private var hoveredPair: Int?
    private var pinnedPair: Int?
    private var glossaryMarks: [GlossaryMark] = []
    private var appliedPronoun: RewriteMode?
    private var messageInfo = ""
    // Reply mode
    enum Mode { case translate, reply, compose }
    private(set) var mode: Mode = .translate
    private var modeControl: NSSegmentedControl!
    private var swapButton: NSButton!
    private var messageCard: ReplyMessageCard!
    private var composePanel: ComposePanel!
    private var leftCardView: NSView!, rightCardView: NSView!, footerToneLabel: NSView!
    private var messageHeight: NSLayoutConstraint!
    private var leftTopPlain: NSLayoutConstraint!
    private var leftTopReply: NSLayoutConstraint!
    private var messageRunner: TranslationRunner!
    private var messageTask: Task<Void, Never>?
    // Recent translations, dropped files
    private var recentButton: NSButton!
    private var recentPopover: NSPopover?
    /// History for «Последние переводы» (nil: the button is hidden).
    var history: HistoryStore? { didSet { if isViewLoaded { recentButton.isHidden = history == nil } } }
    /// A document file was dropped on the page: the app opens it in «Документы».
    var onOpenDocument: ((URL) -> Void)? { didSet { if isViewLoaded { applyFileDrop() } } }

    /// Files dropped on the page or on any of its text fields go to `onOpenDocument`.
    private func applyFileDrop() {
        let handler: ((URL) -> Void)? = onOpenDocument.map { open in { [weak self] url in _ = self; open(url) } }
        (view as? TranslatePageView)?.onFileDrop = handler
        let targeted: ((Bool) -> Void)? = handler == nil ? nil : { [weak self] on in (self?.view as? TranslatePageView)?.showDropTarget(on) }
        for tv in [inputView, outputView as? PlaceholderTextView, messageCard?.messageView] {
            tv?.onFileDrop = handler
            tv?.onFileDragTargeted = targeted
            if handler != nil { tv?.registerForDraggedTypes([.fileURL]) }
        }
    }
    private var configObserver: NSObjectProtocol?
    // Hints panel («Подсказки»)
    private var hints: TranslationHintsPanel!
    private var lastProvider = ""
    private var lastStatsWarnings: [String] = []
    private var hintsShown = false
    private var suppressSelection = false
    private var wideLayout: Bool?
    private var wideConstraints: [NSLayoutConstraint] = []
    private var narrowConstraints: [NSLayoutConstraint] = []
    private var hintsWidth: NSLayoutConstraint!
    private var hintsGap: NSLayoutConstraint!
    private var hintsNarrowHeight: NSLayoutConstraint!
    private var hintsNarrowGap: NSLayoutConstraint!
    /// Content width from which the panel becomes a third column.
    static let wideThreshold: CGFloat = 1000

    static let inputFontSize: CGFloat = 18

    /// The tone of the popup a text was opened from (same request = the translation comes from the cache). Not saved;
    /// until the user touches the tone switch or opens other text.
    private var loadedTone: Tone?
    private var loadedThread: String?
    /// Start «Подобрать варианты» as soon as the loaded text is translated.
    private var pendingVariants = false
    private var tone: Tone {
        get { loadedTone ?? Tone(rawValue: UserDefaults.standard.string(forKey: "tolk.input.tone") ?? "") ?? .auto }
        set { loadedTone = nil; UserDefaults.standard.set(newValue.rawValue, forKey: "tolk.input.tone") }
    }

    init(engine: TranslationEngine) {
        self.engine = engine
        self.runner = TranslationRunner(engine: engine)
        super.init(nibName: nil, bundle: nil)
        runner.onUpdate = { [weak self] in self?.handle($0) }
        runner.onStats = { [weak self] in self?.gotStats($0) }
        messageRunner = makeMessageRunner()
        configObserver = NotificationCenter.default.addObserver(forName: TolkConfig.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.live.reset() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = configObserver { NotificationCenter.default.removeObserver(o) } }

    private func makeMessageRunner() -> TranslationRunner {
        let r = TranslationRunner(engine: engine)
        r.onUpdate = { [weak self] in self?.handleMessage($0) }
        return r
    }

    // MARK: - Public

    /// Puts text into the input and translates it (used by the popup's "expand" button).
    func load(text: String) {
        loadViewIfNeeded()
        loadedTone = nil; loadedThread = nil; pendingVariants = false
        open(text)
    }

    /// The popup's «Открыть в окне» / «Варианты»: the same request as the popup made (languages, tone, chat context),
    /// so the translation comes from the cache; the tone switch shows what the popup showed (e.g. «Авто»).
    /// «Подобрать варианты» starts by itself when the translation is on screen.
    func load(_ h: PopupHandoff, suggestVariants: Bool) {
        loadViewIfNeeded()
        loadedTone = h.requestTone
        loadedThread = h.threadContext
        pendingVariants = suggestVariants
        sourcePopup.selectItem(at: index(of: h.source))
        targetPopup.selectItem(at: index(of: h.target))
        open(h.text)
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: h.displayTone) ?? 0
    }

    private func open(_ text: String) {
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: tone) ?? 0
        inputView.string = text
        inputView.needsDisplay = true
        updateCounter()
        translateNow(force: true)
        focusInput()
    }

    func focusInput() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(inputView)
    }

    /// Stops a running translation (e.g. when the window closes).
    func stop() {
        guard isViewLoaded else { return }
        debounceTask?.cancel()
        runner.cancel()
        refiner.cancel()
        messageRunner.cancel()
        messageTask?.cancel()
        cancelRewrite()
        composePanel?.cancel()
        hints?.invalidate()
        spinner.stopAnimation(nil)
        lastTranslatedRequest = nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusInput()
    }

    // MARK: - Translation

    private var selectedSource: Language? { language(at: sourcePopup.indexOfSelectedItem) }
    private var selectedTarget: Language? { language(at: targetPopup.indexOfSelectedItem) }

    private func language(at index: Int) -> Language? {
        index <= 0 ? nil : Language.allCases[index - 1]
    }

    private func index(of language: Language?) -> Int {
        language.flatMap { Language.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    }

    func textDidChange(_ notification: Notification) {
        if (notification.object as? NSTextView) === messageCard.messageView { messageChanged(); return }
        updateCounter()
        clearPairs()
        cancelRewrite()
        hints?.suspend()
        pendingVariants = false
        finalPassTask?.cancel() // typing cancels the quiet whole-text pass
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.translateNow()
        }
    }

    private func updateCounter() {
        let n = inputView.string.count
        counterLabel.stringValue = n == 0 ? "" : "\(n.formatted()) \(Self.symbolsWord(n))"
        clearButton.isHidden = n == 0
    }

    static func symbolsWord(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "символ" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "символа" }
        return "символов"
    }

    /// «Перевести заново» (⌘R, click on «из кеша»): the same text, a fresh request that skips the cache.
    private func retranslate() {
        guard !inputView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        bypassNext = true
        translateNow(force: true)
    }
    private var bypassNext = false

    private func translateNow(force: Bool = false) {
        debounceTask?.cancel()
        finalPassTask?.cancel()
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyActive = mode == .reply && !replyMessage.isEmpty
        let request = replyActive
            ? engine.replyRequest(message: replyMessage, reply: text, tone: tone)
            : TranslationRequest(text: text, source: selectedSource, target: selectedTarget, tone: tone)
        if !force, request == lastTranslatedRequest { hints?.resume(); return }
        lastTranslatedRequest = request
        if force { live.reset() } // ⌘↩, engine/profile change, loaded text: one full request

        let wasRunning = runner.isRunning
        runner.cancel()
        resetRefine()
        cancelRewrite()
        clearPairs()
        appliedPronoun = nil
        rewriteBar.setPronoun(nil)
        hints.invalidate()
        lastStatsWarnings = []
        fellBackFrom = nil
        noticeLabel.isHidden = true
        guard !text.isEmpty else {
            live.reset(); step = nil
            translation = ""; tail = ""; keptPrefix = ""
            copyButton.isEnabled = false
            refineButton.isEnabled = false
            setOutput("", color: .labelColor)
            spinner.stopAnimation(nil)
            providerBadge.text = ""
            detectedSource = nil
            detectedTarget = nil
            updateStatus()
            updateHintsVisibility(forceHide: !(mode == .reply && !replyMessage.isEmpty))
            return
        }
        if replyActive {
            // Reply: the whole answer goes in one request with the partner's message as context (no live typing cache).
            live.reset(); step = nil; keptPrefix = ""; tail = ""
            translation = ""
            awaitingFirstDelta = true
            copyButton.isEnabled = false
            refineButton.isEnabled = false
            if outputView.string.isEmpty { outputPlaceholderView.placeholder = "Перевожу…" }
            else { outputView.textStorage?.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                                        range: NSRange(location: 0, length: outputView.textStorage?.length ?? 0)) }
            spinner.startAnimation(nil)
            statusLine?.waiting(provider: "…")
            var req = request
            req.bypassCache = bypassNext
            bypassNext = false
            runner.start(req)
            return
        }
        let key = LiveTranslation.key(source: selectedSource, target: selectedTarget, tone: tone, mode: .translate,
                                      config: TolkConfig.load())
        let st = live.prepare(text: text, source: selectedSource, target: selectedTarget, tone: tone, key: key)
        Diagnostics.log(st.logLine)
        step = st
        keptPrefix = st.kind == .partial ? st.kept : ""
        tail = ""
        guard var toSend = st.request else {
            // Nothing meaningful changed: the shown translation must equal the kept one.
            if wasRunning { statusLine?.reset() }
            spinner.stopAnimation(nil)
            awaitingFirstDelta = false
            translation = st.kept
            setOutput(st.kept, color: .labelColor)
            copyButton.isEnabled = !st.kept.isEmpty
            refineButton.isEnabled = !st.kept.isEmpty
            pushHints(useStats: false)
            return
        }
        copyButton.isEnabled = false
        refineButton.isEnabled = false
        if let t = loadedThread, !t.isEmpty { toSend.threadContext = t }
        toSend.bypassCache = bypassNext
        bypassNext = false
        if st.kind == .partial {
            // The kept part stays on screen without flicker; the tail streams in after it.
            translation = st.kept
            awaitingFirstDelta = false
            setOutput(st.kept, color: .labelColor)
        } else {
            translation = ""
            awaitingFirstDelta = true
            // Like DeepL: keep the previous translation visible but dimmed until the new one starts;
            // an empty pane says «Перевожу…».
            if outputView.string.isEmpty {
                outputPlaceholderView.placeholder = "Перевожу…"
            } else if let storage = outputView.textStorage {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                     range: NSRange(location: 0, length: storage.length))
            }
        }
        spinner.startAnimation(nil)
        statusLine?.waiting(provider: "…")
        runner.start(toSend)
    }

    private func handle(_ update: TranslationRunner.Update) {
        switch update {
        case let .started(provider, source, target):
            statusLine?.waiting(provider: provider)
            live.started(source: source, target: target)
            detectedSource = source
            detectedTarget = target
            lastProvider = provider
            providerBadge.text = UIText.providerName(provider)
            providerBadge.tint = UIText.isFallbackProvider(provider) ? .systemOrange : .secondaryLabelColor
            updateStatus()
            view.needsLayout = true
            if let from = fellBackFrom {
                showNotice(UIText.fallbackDone(from: from, to: provider),
                           color: .systemOrange)
            }
        case let .delta(chunk):
            statusLine?.chunk()
            if awaitingFirstDelta {
                awaitingFirstDelta = false
                setOutput("", color: .labelColor)
            }
            tail += chunk
            translation = keptPrefix + tail
            outputView.textStorage?.append(NSAttributedString(string: chunk, attributes: textAttributes()))
            copyButton.isEnabled = true
        case let .fellBack(from, reason):
            statusLine?.fellBack(reason: reason)
            fellBackFrom = from
            // Only the streamed tail goes; the kept part stays on screen.
            tail = ""
            translation = keptPrefix
            awaitingFirstDelta = true
            setOutput(keptPrefix, color: .labelColor)
            awaitingFirstDelta = keptPrefix.isEmpty
            copyButton.isEnabled = false
            showNotice(UIText.fallbackSwitching(from: from), color: .systemOrange)
            noticeLabel.toolTip = reason
        case .finished:
            spinner.stopAnimation(nil)
            awaitingFirstDelta = false
            outputView.scrollRangeToVisible(NSRange(location: 0, length: 0))   // streaming scrolled to the end: show the beginning
            if let st = step, !tail.isEmpty { live.commit(st, tail: tail) }
            refineButton.isEnabled = !translation.isEmpty
            pushHints(useStats: true)
            scheduleFinalPass()
            // Official text (or «всегда» in settings): the editor looks at the translation right away. Not while the
            // text is still being typed (live pieces) — the pass would restart on every pause.
            let typed = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == .translate, beforeRefine == nil, !translation.isEmpty, !live.hadPartials,
               AutoEditor.wanted(mode: TolkConfig.load().autoEditor, source: typed) {
                Diagnostics.log("editor: started by itself (page, \(typed.count) chars)")
                refineClicked()
            }
        case let .failed(message):
            statusLine?.failed(message)
            spinner.stopAnimation(nil)
            lastTranslatedRequest = nil // allow retry with the same text
            if translation.isEmpty { setOutput(message, color: .systemRed) } else { showNotice(message, color: .systemRed) }
        }
    }

    // MARK: Final whole-text pass (quiet)

    /// After a pause of ≥ 2.5 s, if the translation on screen is stitched from partial pieces (live typing), translate the
    /// whole short text in one request. Only a different result replaces the text — without flicker, scroll position kept.
    private func scheduleFinalPass() {
        finalPassTask?.cancel()
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode != .reply, !translation.isEmpty,
              FinalPass.shouldRun(text: text, hadPartials: live.hadPartials) else { return }
        let shownBefore = translation
        let key = LiveTranslation.key(source: selectedSource, target: selectedTarget, tone: tone, mode: .translate,
                                      config: TolkConfig.load())
        var request = TranslationRequest(text: text, source: selectedSource, target: selectedTarget, tone: tone)
        if let t = loadedThread, !t.isEmpty { request.threadContext = t }
        let engine = self.engine
        finalPassTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(FinalPass.pause))
            guard !Task.isCancelled else { return }
            let result = try? await TextCollector.collect(engine.translate(request)) { _ in }
            guard let self, !Task.isCancelled, let result,
                  // The user may have typed, refined or rewritten meanwhile: then the result is stale.
                  self.translation == shownBefore, !self.runner.isRunning,
                  self.inputView.string.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            let changed = FinalPass.differs(shown: shownBefore, final: result.text)
            Diagnostics.log("incremental: final pass changed=\(changed)")
            self.live.adoptFinal(text: text, key: key, translation: changed ? result.text : shownBefore)
            guard changed else { return }
            self.replaceOutputQuietly(with: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Replaces the translation text keeping the scroll position (no dimming, no placeholder).
    private func replaceOutputQuietly(with text: String) {
        let clip = outputView.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        translation = text
        keptPrefix = ""
        tail = ""
        setOutput(text, color: .labelColor)
        if let clip, let origin {
            clip.scroll(to: origin)
            outputView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        copyButton.isEnabled = true
        refineButton.isEnabled = true
        pushHints(useStats: false)
    }

    private func textAttributes(color: NSColor = .labelColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: Self.inputFontSize), .foregroundColor: color, .paragraphStyle: p]
    }

    private func setOutput(_ text: String, color: NSColor) {
        outputView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: textAttributes(color: color)))
        outputPlaceholderView.placeholder = awaitingFirstDelta ? "Перевожу…" : "Перевод"
    }

    private func showNotice(_ text: String, color: NSColor) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = color
        noticeLabel.isHidden = false
    }

    private func updateStatus() {
        sourcePopup.item(at: 0)?.title = detectedSource.map { "Авто · \(UIText.capitalized($0))" } ?? "Определить язык"
        targetPopup.item(at: 0)?.title = detectedTarget.map { "Авто · \(UIText.capitalized($0))" } ?? "Авто"
        sourcePopup.synchronizeTitleAndSelectedItem()
        targetPopup.synchronizeTitleAndSelectedItem()
    }

    // MARK: - Actions

    @objc private func directionChanged(_ sender: NSPopUpButton) { live.reset(); translateNow() }

    @objc private func swapDirection() {
        let newSource = selectedTarget ?? detectedTarget
        let newTarget = selectedSource ?? detectedSource
        live.reset()
        sourcePopup.selectItem(at: index(of: newSource))
        targetPopup.selectItem(at: index(of: newTarget))
        let result = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty {
            inputView.string = result
            inputView.needsDisplay = true
            updateCounter()
        }
        translateNow()
    }

    @objc private func toneChanged(_ sender: NSSegmentedControl) {
        tone = Tone.allCases[max(0, sender.selectedSegment)]
        live.reset()
        translateNow()
    }

    @objc private func clearInput() {
        inputView.string = ""
        inputView.needsDisplay = true
        updateCounter()
        translateNow()
        focusInput()
    }

    // MARK: - Editor pass

    private func resetRefine() {
        refiner.cancel()
        beforeRefine = nil
        refineButton?.title = "Отредактировать"
        hints?.setEditorChange(before: nil, after: nil)
    }

    @objc private func refineClicked() {
        if let old = beforeRefine {   // «Вернуть»
            beforeRefine = nil
            translation = old
            setOutput(old, color: .labelColor)
            refineButton.title = "Отредактировать"
            appliedPronoun = nil
            rewriteBar.setPronoun(nil)
            live.reset()
            hints.setEditorChange(before: nil, after: nil)
            pushHints(useStats: false)
            return
        }
        let source = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty, !runner.isRunning, !source.isEmpty,
              let from = selectedSource ?? detectedSource, let to = selectedTarget ?? detectedTarget else { return }
        let old = translation
        var refined = ""
        spinner.startAnimation(nil)
        refineButton.isEnabled = false
        copyButton.isEnabled = false
        live.reset()
        hints.invalidate()
        awaitingFirstDelta = false
        refiner.start(engine: engine, source: source, translation: old, from: from, to: to, tone: tone,
                      onDelta: { [weak self] chunk in
            guard let self else { return }
            if refined.isEmpty { self.setOutput("", color: .labelColor) }
            refined += chunk
            self.translation = refined
            self.outputView.textStorage?.append(NSAttributedString(string: chunk, attributes: self.textAttributes()))
        }, onDone: { [weak self] in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            let t = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == old.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.translation = old; self.setOutput(old, color: .labelColor)
            } else {
                self.beforeRefine = old
                self.refineButton.title = "Вернуть"
            }
            self.refineButton.isEnabled = true
            self.copyButton.isEnabled = true
            self.pushHints(useStats: false)
            if self.beforeRefine != nil { self.hints.setEditorChange(before: old, after: self.translation, title: "Правка · Редактор") }
        }, onFail: { [weak self] message in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.translation = old; self.setOutput(old, color: .labelColor)
            self.refineButton.isEnabled = true
            self.copyButton.isEnabled = true
            self.showNotice(message, color: .systemRed)
            self.pushHints(useStats: false)
        })
    }

    @objc func copyTranslation() {
        guard !translation.isEmpty else { NSSound.beep(); return }
        Clipboard.copy(translation)
        copyButton.title = "Скопировано"
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copyButton.title = "Копировать"
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func commandReturn() {
        if mode == .compose { composePanel.run(); return }
        if let onCommandReturn { onCommandReturn() } else { copyTranslation() }
    }

    // Esc in an editable NSTextView would open the completion list.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return true
        }
        return false
    }

    #if DEBUG
    // Hooks for the off-screen render (TranslateHintsDemo): no real clicks needed.
    func debugSelectOutput(_ fragment: String) {
        let r = (outputView.string as NSString).range(of: fragment)
        if r.location != NSNotFound { outputView.setSelectedRange(r) }
    }
    func debugRefine() { refineClicked() }
    var debugHintsReady: Bool { hints.hasContext }
    /// Pretends the mouse is over `fragment` in the original (or, with `inOutput`, in the translation).
    func debugHover(_ fragment: String, inOutput: Bool = false) {
        let tv: NSTextView = inOutput ? outputView : inputView
        let r = (tv.string as NSString).range(of: fragment)
        hover(input: !inOutput, index: r.location == NSNotFound ? nil : r.location + r.length / 2)
    }
    /// A click on the sentence of the translation that contains `fragment`.
    func debugClickSentence(_ fragment: String) {
        let r = (outputView.string as NSString).range(of: fragment)
        if r.location != NSNotFound { variantsForSentence(at: r.location) }
    }
    func debugRewrite(_ m: RewriteMode) { rewriteRequested(m) }
    /// «Сформулировать» with filled fields (and optionally the run).
    func debugCompose(points: String, message: String = "", tone: ComposeTone = .neutral, run: Bool) {
        setMode(.compose)
        composePanel.debugFill(points: points, message: message, tone: tone)
        if run { composePanel.run() }
    }
    var debugComposeIdle: Bool { composePanel.debugIdle }
    func debugExplain() { hints.explainClicked() }
    func debugSuggestVariants() { hints.suggestTranslationVariants() }
    func debugTakeVariant(_ i: Int) { hints.debugTakeVariant(i) }
    /// Reply mode with the partner's message and the user's answer, without typing.
    func debugReply(message: String, answer: String) {
        setMode(.reply)
        messageCard.messageView.string = message
        messageCard.messageView.needsDisplay = true
        inputView.string = answer
        inputView.needsDisplay = true
        updateCounter()
        updateHintsVisibility()
        hints.refresh()
        translateMessage()
        translateNow(force: true)
    }
    var debugNotice: String { "hidden=\(noticeLabel.isHidden) text=\(noticeLabel.stringValue) frame=\(noticeLabel.frame) rw=\(rewriteTask != nil)" }
    func debugScrollOutputToEnd() { outputView.scrollRangeToVisible(NSRange(location: (outputView.string as NSString).length, length: 0)) }
    var debugIdle: Bool { !runner.isRunning && !messageRunner.isRunning && rewriteTask == nil && hints.busyCount == 0 }
    #endif

    // MARK: - Hints panel

    private func gotStats(_ st: TranslationStats) {
        statusLine?.finished(st)
        lastStatsWarnings = st.warnings
    }

    /// The translation on screen is final: show the checks, and ask for the rest after a pause.
    private func pushHints(useStats: Bool) {
        let source = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty, !runner.isRunning, !source.isEmpty,
              let from = selectedSource ?? detectedSource, let to = selectedTarget ?? detectedTarget else { return }
        hints.ready(source: source, translation: translation, from: from, to: to, provider: lastProvider,
                    statsWarnings: useStats ? lastStatsWarnings : nil)
        refreshPairs()
        decorateOutput()
        updateHintsVisibility()
        if pendingVariants { pendingVariants = false; hints.suggestTranslationVariants() }
    }

    /// The panel shows up with the first finished translation and goes away when the input is empty.
    private func updateHintsVisibility(forceHide: Bool = false) {
        // Settings can change (model, ⌃⌥R toggle…) before the page was ever opened: no views yet, nothing to update.
        // Touching the implicitly unwrapped `hints` here crashed Tolk on every settings save in that state.
        guard isViewLoaded, hints != nil else { return }
        let replyReady = mode == .reply && !replyMessage.isEmpty
        if mode == .compose { hintsShown = false } else if forceHide { hintsShown = false } else if hints.hasContext || replyReady { hintsShown = true }
        hints.isHidden = !hintsShown
        hintsWidth?.constant = hintsShown ? 300 : 0
        hintsGap?.constant = hintsShown ? -12 : 0
        hintsNarrowHeight?.constant = hintsShown ? 240 : 0
        hintsNarrowGap?.constant = hintsShown ? 10 : 0
    }

    /// Wide window: the panel is a third column; narrow: it sits under the two panes.
    override func viewWillLayout() {
        super.viewWillLayout()
        messageHeight?.constant = mode == .reply ? min(max(view.bounds.height * 0.28, 120), 230) : 200
        let columns: CGFloat = view.bounds.width >= Self.wideThreshold && hintsShown ? 312 : 0
        rewriteBar?.setWidth((view.bounds.width - 48 - columns) / 2)
        // A narrow translation column has no room for the provider badge next to the mode switch (the status line names it anyway).
        let narrowColumn = (view.bounds.width - 48 - columns) / 2 < 470
        if let providerBadge { providerBadge.isHidden = narrowColumn || providerBadge.text.isEmpty }
        let wide = view.bounds.width >= Self.wideThreshold
        guard wide != wideLayout, !wideConstraints.isEmpty else { return }
        wideLayout = wide
        if wide {
            NSLayoutConstraint.deactivate(narrowConstraints)
            NSLayoutConstraint.activate(wideConstraints)
        } else {
            NSLayoutConstraint.deactivate(wideConstraints)
            NSLayoutConstraint.activate(narrowConstraints)
        }
    }

    // A word selected (or clicked) in the translation → its alternatives; text selected in the input → glossary term.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !suppressSelection, let tv = notification.object as? NSTextView else { return }
        let ns = tv.string as NSString
        let range = tv.selectedRange()
        guard NSMaxRange(range) <= ns.length else { return }
        if tv === inputView {
            let t = range.length > 0 ? ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !t.isEmpty, t.count <= 60 { hints.suggestTerm(t) }
            return
        }
        guard tv === outputView, hints.hasContext, !runner.isRunning, !translation.isEmpty else { return }
        if range.length == 0 { return }   // a plain click opens the sentence variants (PlaceholderTextView.onClickAt)
        let fragment = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard fragment.count >= 2, range.length <= 60 else { return }
        hints.fragmentSelected(fragment, range: range)
    }

    private func replaceInOutput(_ range: NSRange, with text: String) {
        guard let storage = outputView.textStorage, NSMaxRange(range) <= storage.length else { return }
        suppressSelection = true
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: textAttributes()))
        outputView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
        suppressSelection = false
        translation = outputView.string
        live.reset()
        hints.translationEdited(translation)
        refreshPairs()
        decorateOutput()
    }

    // MARK: - Reply mode

    private var replyMessage: String { messageCard.messageView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(sender.selectedSegment == 2 ? .compose : sender.selectedSegment == 1 ? .reply : .translate)
    }

    /// «Сформулировать» replaces both panes (and the hints panel); the mode switch stays.
    private func setComposeVisible(_ on: Bool) {
        composePanel.isHidden = !on
        hintLabel.stringValue = on ? "⌘↩ — сформулировать" : footerHint
        for v in [sourcePopup, targetPopup, leftCardView, rightCardView, footerToneLabel, toneControl, recentButton] as [NSView?] { v?.isHidden = on }
        if on {
            swapButton.isHidden = true; messageCard.isHidden = true; providerBadge.isHidden = true
            spinner.stopAnimation(nil)
        } else {
            swapButton.isHidden = mode == .reply
            messageCard.isHidden = mode != .reply
            recentButton.isHidden = history == nil
        }
    }

    func setMode(_ new: Mode) {
        loadViewIfNeeded()
        modeControl.selectedSegment = new == .compose ? 2 : new == .reply ? 1 : 0
        guard new != mode else { return }
        mode = new
        setComposeVisible(new == .compose)
        if new == .compose {
            debounceTask?.cancel(); runner.cancel(); refiner.cancel(); messageTask?.cancel(); messageRunner.cancel()
            cancelRewrite()
            hints.invalidate()
            lastTranslatedRequest = nil
            updateHintsVisibility(forceHide: true)
            view.needsLayout = true
            composePanel.focus()
            return
        }
        let reply = new == .reply
        messageCard.isHidden = !reply
        leftTopPlain.isActive = !reply
        leftTopReply.isActive = reply
        swapButton.isHidden = reply
        sourcePopup.isEnabled = !reply
        targetPopup.isEnabled = !reply
        inputView.placeholder = reply ? "Ваш ответ" : "Введите или вставьте текст"
        inputView.setAccessibilityLabel(reply ? "Мой ответ" : "Исходный текст")
        outputPlaceholderView.placeholder = reply ? "Ответ на языке собеседника" : "Перевод"
        outputPlaceholderView.needsDisplay = true
        inputView.needsDisplay = true
        // Coming from a translated foreign text (popup → «развернуть» → «Ответ»): that text is the partner's message, not my answer.
        if reply, replyMessage.isEmpty {
            let carried = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !carried.isEmpty, LanguageDetector.detect(carried) != TolkConfig.load().primaryLanguage {
                messageCard.messageView.string = carried
                messageCard.messageView.needsDisplay = true
                inputView.string = ""
                inputView.needsDisplay = true
                updateCounter()
            }
        }
        clearPairs()
        cancelRewrite()
        hints.invalidate()
        lastTranslatedRequest = nil
        live.reset()
        view.needsLayout = true
        if reply { translateMessage() } else { messageTask?.cancel(); messageRunner.cancel() }
        translateNow(force: true)
        updateHintsVisibility(forceHide: !hints.hasContext && !(reply && !replyMessage.isEmpty))
        hints.refresh()
        view.window?.makeFirstResponder(reply && replyMessage.isEmpty ? messageCard.messageView : inputView)
        // The answer card changes height with the mode: without this the text stays scrolled with its first line cut off.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.inputView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            self.inputView.scrollRangeToVisible(self.inputView.selectedRange())
        }
    }

    /// The partner's message changed: its translation (to the user's language) and the answer's translation follow.
    private func messageChanged() {
        messageTask?.cancel()
        hints.refresh()
        updateHintsVisibility()
        messageTask = Task { @MainActor [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.translateMessage()
            if !self.inputView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.translateNow() }
        }
    }

    private func translateMessage() {
        messageRunner.cancel()
        let msg = replyMessage
        guard !msg.isEmpty else { messageCard.setTranslation(""); messageCard.setInfo("", busy: false); return }
        let cfg = TolkConfig.load()
        let lang = LanguageDetector.detect(msg)
        if lang == cfg.primaryLanguage {
            messageInfo = "\(lang.flag) \(UIText.capitalized(lang))"
            messageCard.setInfo(messageInfo, busy: false)
            messageCard.setTranslation("Сообщение уже на вашем языке — перевод не нужен.", dim: true)
            return
        }
        messageInfo = "\(lang.flag) → \(cfg.primaryLanguage.flag)"
        messageCard.setInfo(messageInfo, busy: true)
        messageCard.setTranslation("")
        messageRunner.start(TranslationRequest(text: msg, source: lang, target: cfg.primaryLanguage, tone: .auto))
    }

    private func handleMessage(_ update: TranslationRunner.Update) {
        switch update {
        case .started, .fellBack: messageCard.setTranslation("")
        case let .delta(chunk): messageCard.appendTranslation(chunk)
        case .finished: messageCard.setInfo(messageInfo, busy: false)
        case let .failed(message):
            messageCard.setTranslation(message, error: true)
            messageCard.setInfo(messageInfo, busy: false)
        }
    }

    // MARK: - Two server slots

    /// Ollama has two slots. Before a button request: count what is running; the automatic hints give way.
    private func slotAvailable() -> Bool {
        func used() -> Int {
            [runner.isRunning, messageRunner.isRunning, rewriteTask != nil, refiner.isRunning].filter { $0 }.count + hints.busyCount
        }
        if used() >= 2 { hints.cancelBackground() }
        return used() < 2
    }

    // MARK: - Rewrite

    private func syncRewrite() { rewriteBar?.setEnabled(refineButton.isEnabled && rewriteTask == nil) }

    private func cancelRewrite() {
        rewriteGeneration += 1
        rewriteTask?.cancel()
        rewriteTask = nil
        rewriteBar?.setBusy(nil)
        syncRewrite()
    }

    private func showTransientNotice(_ text: String, color: NSColor) {
        showNotice(text, color: color)
        noticeLabel.toolTip = text
        noticeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.noticeLabel.isHidden = true } }
        noticeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    private func rewriteRequested(_ mode: RewriteMode) {
        let source = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty, !runner.isRunning, rewriteTask == nil, !refiner.isRunning, !source.isEmpty,
              let from = selectedSource ?? detectedSource, let to = selectedTarget ?? detectedTarget else { return }
        if UIText.isFallbackProvider(lastProvider) {
            showTransientNotice(ServerText.homeOnly("Переписывание"), color: .systemOrange)
            return
        }
        guard slotAvailable() else {
            showTransientNotice("Сервер занят двумя запросами — подождите или отмените один.", color: .systemOrange)
            return
        }
        rewriteGeneration += 1
        let gen = rewriteGeneration
        rewriteBar.setBusy(mode)
        refineButton.isEnabled = false
        let eng = engine, current = translation
        rewriteTask = Task { @MainActor [weak self] in
            let result: Result<RewriteResult, Error>
            do { result = .success(try await eng.rewrite(translation: current, source: source, from: from, to: to, mode: mode)) }
            catch { result = .failure(error) }
            guard let self, self.rewriteGeneration == gen, !Task.isCancelled else { return }
            self.rewriteTask = nil
            self.rewriteBar.setBusy(nil)
            self.refineButton.isEnabled = !self.translation.isEmpty
            self.rewriteFinished(mode, old: current, result: result)
        }
    }

    /// «Взять» in «Варианты перевода»: the variant replaces the translation; «Вернуть» goes back to the text before any edit.
    private func takeVariant(_ text: String, label: String) {
        guard !runner.isRunning, rewriteTask == nil, !refiner.isRunning,
              text.trimmingCharacters(in: .whitespacesAndNewlines) != translation.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let original = beforeRefine ?? translation
        beforeRefine = original
        translation = text
        setOutput(text, color: .labelColor)
        refineButton.title = "Вернуть"
        copyButton.isEnabled = true
        appliedPronoun = nil
        rewriteBar.setPronoun(nil)
        live.reset()
        pushHints(useStats: false)
        hints.setEditorChange(before: original, after: text, title: "Правка · \(label)")
    }

    private func rewriteFinished(_ mode: RewriteMode, old: String, result: Result<RewriteResult, Error>) {
        switch result {
        case let .failure(error):
            showTransientNotice(UIText.errorMessage(error), color: .systemRed)
        case let .success(r):
            guard r.accepted else {
                showTransientNotice("Не применено: \(r.rejection ?? "перевод не прошёл проверку")", color: .systemOrange)
                noticeLabel.toolTip = "«\(mode.russianTitle)» не применено, перевод не тронут. Причина: \(r.rejection ?? "перевод не прошёл проверку")"
                return
            }
            if mode == .formal || mode == .informal { appliedPronoun = mode; rewriteBar.setPronoun(mode) }
            guard r.changed else {
                showTransientNotice("«\(mode.russianTitle)»: перевод уже такой", color: .secondaryLabelColor)
                return
            }
            let original = beforeRefine ?? old   // one «Вернуть» goes back to the translation before any edit
            beforeRefine = original
            translation = r.text
            setOutput(r.text, color: .labelColor)
            refineButton.title = "Вернуть"
            copyButton.isEnabled = true
            live.reset()
            pushHints(useStats: false)
            hints.setEditorChange(before: original, after: r.text, title: "Правка · \(mode.russianTitle)")
        }
    }

    // MARK: - Sentence pairs

    private func refreshPairs() {
        pinnedPair = nil
        hoveredPair = nil
        let src = inputView.string, tr = outputView.string
        pairs = translation.isEmpty || src.isEmpty ? [] : SentencePairing.pairs(source: src, translation: tr)
        applyPairHighlight()
    }

    private func clearPairs() {
        pairs = []; hoveredPair = nil; pinnedPair = nil
        applyPairHighlight()
    }

    private func hover(input: Bool, index: Int?) {
        var found: Int?
        if let index, !pairs.isEmpty {
            found = pairs.firstIndex { NSLocationInRange(index, input ? $0.source : $0.translation) }
        }
        guard found != hoveredPair else { return }
        hoveredPair = found
        applyPairHighlight()
    }

    private func trimmedRange(_ r: NSRange, in s: String) -> NSRange {
        let ns = s as NSString
        guard NSMaxRange(r) <= ns.length else { return NSRange(location: r.location, length: 0) }
        var start = r.location, len = r.length
        while len > 0, let u = Unicode.Scalar(ns.character(at: start)), CharacterSet.whitespacesAndNewlines.contains(u) { start += 1; len -= 1 }
        while len > 0, let u = Unicode.Scalar(ns.character(at: start + len - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { len -= 1 }
        return NSRange(location: start, length: len)
    }

    /// The hovered (or last clicked) pair is tinted in both panes; an unsure pair is paler.
    private func applyPairHighlight() {
        guard inputView != nil, outputView != nil else { return }
        for tv in [inputView!, outputView!] {
            guard let lm = tv.layoutManager else { continue }
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
        }
        guard let i = hoveredPair ?? pinnedPair, pairs.indices.contains(i) else { return }
        let p = pairs[i]
        let color = NSColor.controlAccentColor.withAlphaComponent(p.isConfident ? 0.26 : 0.10)
        for (tv, range) in [(inputView!, p.source), (outputView!, p.translation)] {
            let r = trimmedRange(range, in: tv.string)
            if r.length > 0 { tv.layoutManager?.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: r) }
        }
    }

    // MARK: - Sentence variants

    private func variantsForSentence(at index: Int) {
        guard hints.hasContext, !runner.isRunning, !translation.isEmpty,
              let i = pairs.firstIndex(where: { NSLocationInRange(index, $0.translation) }) else { return }
        let p = pairs[i]
        let range = trimmedRange(p.translation, in: outputView.string)
        let srcRange = trimmedRange(p.source, in: inputView.string)
        guard range.length > 0, srcRange.length > 0 else { return }
        pinnedPair = i
        applyPairHighlight()
        hints.requestVariants(sentence: (inputView.string as NSString).substring(with: srcRange),
                              current: (outputView.string as NSString).substring(with: range), range: range, tone: tone)
    }

    @objc private func variantsFromMenu(_ sender: NSMenuItem) { variantsForSentence(at: sender.tag) }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard view === outputView, hints.hasContext, !runner.isRunning,
              pairs.contains(where: { NSLocationInRange(charIndex, $0.translation) }) else { return menu }
        let item = NSMenuItem(title: "Варианты предложения", action: #selector(variantsFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.tag = charIndex
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    // MARK: - Glossary marks

    /// Terms the glossary put into the translation: dashed underline, tooltip «из глоссария: X → Y».
    private func decorateOutput() {
        guard let storage = outputView.textStorage else { return }
        let len = storage.length
        storage.beginEditing()
        for key in [NSAttributedString.Key.underlineStyle, .underlineColor, .toolTip] {
            storage.removeAttribute(key, range: NSRange(location: 0, length: len))
        }
        glossaryMarks = []
        if len > 0, let to = detectedTarget ?? selectedTarget {
            let hits = engine.glossaryHits(in: inputView.string, target: to)
            glossaryMarks = RulesStore.marks(of: hits, in: outputView.string)
            for m in glossaryMarks where NSMaxRange(m.range) <= len {
                let shown = (outputView.string as NSString).substring(with: m.range)
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue,
                    .underlineColor: NSColor.controlAccentColor,
                    .toolTip: "из глоссария: \(m.hit.source) → \(shown)",
                ], range: m.range)
            }
        }
        storage.endEditing()
    }

    // MARK: - Recent translations, dropped files

    @objc private func showRecents() {
        if let pop = recentPopover, pop.isShown { pop.close(); return }
        guard let history else { return }
        let vc = RecentTranslationsViewController(store: history)
        let pop = NSPopover()
        vc.onPick = { [weak self, weak pop] entry in pop?.close(); self?.loadFromHistory(entry) }
        pop.behavior = .transient
        pop.contentViewController = vc
        recentPopover = pop
        pop.show(relativeTo: recentButton.bounds, of: recentButton, preferredEdge: .maxY)
    }

    /// Puts a saved pair on the page: the original and its translation, no new request.
    func loadFromHistory(_ e: HistoryEntry) {
        loadViewIfNeeded()
        if mode != .translate { setMode(.translate) }
        debounceTask?.cancel(); runner.cancel(); refiner.cancel(); cancelRewrite()
        resetRefine(); clearPairs()
        inputView.string = e.source
        inputView.needsDisplay = true
        updateCounter()
        live.reset(); step = nil; keptPrefix = ""; tail = ""
        awaitingFirstDelta = false
        detectedSource = e.sourceLanguage
        detectedTarget = e.targetLanguage
        lastProvider = e.provider
        providerBadge.text = UIText.providerName(e.provider)
        providerBadge.tint = UIText.isFallbackProvider(e.provider) ? .systemOrange : .secondaryLabelColor
        updateStatus()
        translation = e.translation
        setOutput(e.translation, color: .labelColor)
        spinner.stopAnimation(nil)
        statusLine.reset()
        copyButton.isEnabled = true
        refineButton.isEnabled = true
        lastStatsWarnings = []
        lastTranslatedRequest = TranslationRequest(text: e.source.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   source: selectedSource, target: selectedTarget, tone: tone)
        showTransientNotice("Из истории — запрос не отправлялся", color: .secondaryLabelColor)
        pushHints(useStats: false)
    }

    // MARK: - Building

    private func makeTextPane(editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let tv = PlaceholderTextView()
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isEditable = editable
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = editable
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: Self.inputFontSize)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 14, height: 16)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.typingAttributes = textAttributes()
        scroll.documentView = tv
        return (scroll, tv)
    }

    /// Rounded card: text pane on top, a thin bottom bar with controls.
    private func card(_ content: NSView, bottom: NSView, tinted: Bool, top: NSView? = nil) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = TolkStyle.cardRadius
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        // Dynamic: resolved at draw time, so the card follows the window's appearance (not the one at creation).
        box.fillColor = tinted
            ? NSColor(name: nil) { appearance in
                var result = NSColor.textBackgroundColor
                appearance.performAsCurrentDrawingAppearance {
                    result = (NSColor.textBackgroundColor.blended(withFraction: 0.035, of: .labelColor) ?? .textBackgroundColor)
                        .usingColorSpace(.sRGB) ?? .textBackgroundColor
                }
                return result
            }
            : .textBackgroundColor
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
        guard let cv = box.contentView else { return box }
        for v in [content, bottom] { v.translatesAutoresizingMaskIntoConstraints = false; cv.addSubview(v) }
        if let top {
            top.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(top)
            NSLayoutConstraint.activate([
                top.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 1),
                top.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -1),
                top.topAnchor.constraint(equalTo: cv.topAnchor, constant: 3),
                top.heightAnchor.constraint(equalToConstant: 28),
            ])
            // A hairline under the bar: scrolled text is cut off by it, not hidden under the buttons.
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
                line.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
                line.topAnchor.constraint(equalTo: top.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -1),
            top.map { content.topAnchor.constraint(equalTo: $0.bottomAnchor, constant: 0) } ?? content.topAnchor.constraint(equalTo: cv.topAnchor, constant: 1),
            bottom.topAnchor.constraint(equalTo: content.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -10),
            bottom.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            bottom.heightAnchor.constraint(equalToConstant: 28),
        ])
        return box
    }

    private func languagePopup(first: String) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: [first] + Language.allCases.map { "\($0.flag)  " + UIText.capitalized($0) })
        p.target = self
        p.action = #selector(directionChanged(_:))
        p.bezelStyle = .push
        p.isBordered = false
        p.font = .systemFont(ofSize: 14, weight: .medium)
        p.contentTintColor = .controlAccentColor
        return p
    }

    override func loadView() {
        let root = TranslatePageView()
        root.onCommandReturn = { [weak self] in self?.commandReturn() }
        root.onRetranslate = { [weak self] in self?.retranslate() }
        view = root

        // Language bar: [source]  ⇄  [target]      tone      spinner badge
        sourcePopup = languagePopup(first: "Определить язык")
        targetPopup = languagePopup(first: "Авто")
        sourcePopup.toolTip = "Язык оригинала"
        targetPopup.toolTip = "Язык перевода. «Авто»: с основного языка — на второй, с остальных — на основной"
        let swap = NSButton(image: NSImage(systemSymbolName: "arrow.left.arrow.right",
                                           accessibilityDescription: "Поменять языки")!,
                            target: self, action: #selector(swapDirection))
        swap.bezelStyle = .circular
        swap.controlSize = .large
        swap.toolTip = "Поменять языки местами (и тексты)"
        swap.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        swapButton = swap

        modeControl = NSSegmentedControl(labels: ["Перевод", "Ответ", "Составить"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        modeControl.controlSize = .small
        modeControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modeControl.selectedSegment = 0
        modeControl.setToolTip("Обычный перевод: текст слева, перевод справа", forSegment: 0)
        modeControl.setToolTip("Ответ собеседнику: сообщение сверху, мой ответ ниже, перевод ответа справа", forSegment: 1)
        modeControl.setToolTip("Сформулировать сообщение из тезисов: что нужно сказать — своими словами, на выходе готовый текст на языке получателя", forSegment: 2)
        modeControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        toneControl = UIFactory.toneControl(target: self, action: #selector(toneChanged(_:)))
        toneControl.controlSize = .regular
        toneControl.font = .systemFont(ofSize: NSFont.systemFontSize)
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: tone) ?? 0
        toneControl.toolTip = "Тон перевода"

        providerBadge = UIFactory.badge()
        providerBadge.text = ""
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        // Source + target selectors sit above their panes, the swap button between them.
        let leftBar = NSStackView(views: [sourcePopup, UIFactory.spacer()])
        let rightBar = NSStackView(views: [targetPopup, UIFactory.spacer(), spinner, providerBadge, modeControl])
        for b in [leftBar, rightBar] { b.orientation = .horizontal; b.spacing = 8 }

        // Input pane
        let (inScroll, inTV) = makeTextPane(editable: true)
        inputView = inTV as? PlaceholderTextView
        inputView.placeholder = "Введите или вставьте текст"
        inputView.placeholderFont = .systemFont(ofSize: Self.inputFontSize)
        inputView.delegate = self
        inputView.setAccessibilityLabel("Исходный текст")
        inputView.setHover { [weak self] in self?.hover(input: true, index: $0) }
        counterLabel = UIFactory.label("", size: 11.5, color: .tertiaryLabelColor)
        clearButton = UIFactory.symbolButton("xmark.circle.fill", tooltip: "Очистить", target: self,
                                             action: #selector(clearInput))
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        clearButton.isHidden = true
        let inBottom = NSStackView(views: [counterLabel, UIFactory.spacer(), clearButton])
        inBottom.orientation = .horizontal

        // Output pane
        let (outScroll, outTV) = makeTextPane(editable: false)
        outputView = outTV
        outputView.delegate = self
        outputView.setAccessibilityLabel("Перевод")
        (outputView as? PlaceholderTextView)?.setHover { [weak self] in self?.hover(input: false, index: $0) }
        (outputView as? PlaceholderTextView)?.onClickAt = { [weak self] in self?.variantsForSentence(at: $0) }
        outputPlaceholderView.placeholder = "Перевод"
        outputPlaceholderView.placeholderFont = .systemFont(ofSize: Self.inputFontSize)
        let notice = NoticeLabel(labelWithString: "")
        notice.font = .systemFont(ofSize: 11.5)
        notice.textColor = .systemOrange
        noticeLabel = notice
        noticeLabel.isHidden = true
        copyButton = NSButton(title: "Копировать", target: self, action: #selector(copyTranslation))
        copyButton.bezelStyle = .push
        copyButton.controlSize = .regular
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.isEnabled = false
        copyButton.toolTip = "Копировать перевод (⌘↩)"
        let follow = FollowButton(title: "Отредактировать", target: self, action: #selector(refineClicked))
        follow.onEnabledChange = { [weak self] in self?.syncRewrite() }
        refineButton = follow
        refineButton.bezelStyle = .push
        refineButton.controlSize = .small
        refineButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        refineButton.isEnabled = false
        refineButton.toolTip = "Второй проход: убрать кальки, сохранить смысл"
        refineButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLine = StatusLineView()
        statusLine.compactWarnings = true
        statusLine.onRetranslate = { [weak self] in self?.retranslate() }
        statusLine.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        noticeLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        noticeLabel.lineBreakMode = .byTruncatingTail
        // Bottom line of the translation card: the buttons are pinned to the right and always fit; the status line
        // (or, instead of it, a short notice) takes what is left and is truncated.
        let outBottom = NSView()
        for v in [statusLine!, noticeLabel!, refineButton!, copyButton!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            outBottom.addSubview(v)
        }
        NSLayoutConstraint.activate([
            copyButton.trailingAnchor.constraint(equalTo: outBottom.trailingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: outBottom.centerYAnchor),
            refineButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
            refineButton.centerYAnchor.constraint(equalTo: outBottom.centerYAnchor),
            statusLine.leadingAnchor.constraint(equalTo: outBottom.leadingAnchor),
            statusLine.centerYAnchor.constraint(equalTo: outBottom.centerYAnchor),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: refineButton.leadingAnchor, constant: -10),
            noticeLabel.leadingAnchor.constraint(equalTo: outBottom.leadingAnchor),
            noticeLabel.centerYAnchor.constraint(equalTo: outBottom.centerYAnchor),
            noticeLabel.trailingAnchor.constraint(lessThanOrEqualTo: refineButton.leadingAnchor, constant: -10),
        ])
        notice.onVisibility = { [weak self] in self?.statusLine.alphaValue = self?.noticeLabel.isHidden == false ? 0 : 1 }

        // Rows never force the window wider: when short of room their contents are clipped / truncated.
        for row in [inBottom, leftBar, rightBar] { row.setClippingResistancePriority(.init(1), for: .horizontal) }
        // Narrow window: the language selector gives way (its title is truncated) before the mode switch gets clipped.
        rightBar.setClippingResistancePriority(.init(490), for: .horizontal)
        targetPopup.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        let leftCard = card(inScroll, bottom: inBottom, tinted: false)
        rewriteBar = RewriteBar()
        rewriteBar.onMode = { [weak self] in self?.rewriteRequested($0) }
        rewriteBar.onCancel = { [weak self] in self?.cancelRewrite() }
        let rightCard = card(outScroll, bottom: outBottom, tinted: true, top: rewriteBar)

        hintLabel = UIFactory.label(footerHint, size: 11, color: .tertiaryLabelColor)
        let toneLabel = UIFactory.label("Тон", size: 12)
        footerToneLabel = toneLabel
        leftCardView = leftCard
        rightCardView = rightCard
        recentButton = NSButton(title: "Последние", target: self, action: #selector(showRecents))
        recentButton.bezelStyle = .roundRect
        recentButton.controlSize = .small
        recentButton.font = .systemFont(ofSize: 11.5)
        recentButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        recentButton.imagePosition = .imageLeading
        recentButton.toolTip = "Последние переводы из истории — выбор подставляет текст и перевод без нового запроса"
        recentButton.isHidden = history == nil
        let footer = NSStackView(views: [hintLabel, UIFactory.spacer(), recentButton, toneLabel, toneControl])
        footer.orientation = .horizontal
        footer.spacing = 8

        hints = TranslationHintsPanel(engine: engine)
        hints.isHidden = true
        hints.onRetranslate = { [weak self] in self?.translateNow(force: true) }
        hints.onReplace = { [weak self] range, text in self?.replaceInOutput(range, with: text) }
        hints.onRevertEdit = { [weak self] in if self?.beforeRefine != nil { self?.refineClicked() } }
        hints.onTakeVariant = { [weak self] text, label in self?.takeVariant(text, label: label) }
        hints.toneProvider = { [weak self] in self?.tone ?? .auto }
        hints.replyContext = { [weak self] in
            guard let self, self.mode == .reply, !self.replyMessage.isEmpty else { return nil }
            return self.replyMessage
        }
        hints.canStartRequest = { [weak self] in self?.slotAvailable() ?? false }
        hints.explainSource = { [weak self] in
            guard let self else { return nil }
            return self.mode == .reply ? self.replyMessage : self.inputView.string
        }

        // Reply mode: the partner's message above the answer.
        messageCard = ReplyMessageCard()
        messageCard.isHidden = true
        messageCard.messageView.delegate = self
        applyFileDrop()
        composePanel = ComposePanel(engine: engine)
        composePanel.isHidden = true

        for v in [leftBar, rightBar, swap, messageCard!, leftCard, rightCard, footer, hints!, composePanel!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let m: CGFloat = 18
        let top = leftBar.topAnchor.constraint(equalTo: root.topAnchor, constant: topInset)
        rootTop = top
        NSLayoutConstraint.activate([
            top,
            leftBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m + 4),
            leftBar.trailingAnchor.constraint(equalTo: leftCard.trailingAnchor),
            rightBar.topAnchor.constraint(equalTo: leftBar.topAnchor),
            rightBar.trailingAnchor.constraint(equalTo: rightCard.trailingAnchor, constant: -4),
            rightBar.leadingAnchor.constraint(equalTo: rightCard.leadingAnchor, constant: 26),
            leftBar.heightAnchor.constraint(equalToConstant: 28),
            rightBar.heightAnchor.constraint(equalTo: leftBar.heightAnchor),

            swap.centerXAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: 6),
            swap.centerYAnchor.constraint(equalTo: leftBar.centerYAnchor),

            messageCard.topAnchor.constraint(equalTo: leftBar.bottomAnchor, constant: 10),
            messageCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            messageCard.trailingAnchor.constraint(equalTo: leftCard.trailingAnchor),
            leftCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            composePanel.topAnchor.constraint(equalTo: leftBar.bottomAnchor, constant: 10),
            composePanel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            composePanel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            composePanel.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),
            rightCard.topAnchor.constraint(equalTo: leftBar.bottomAnchor, constant: 10),
            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: 12),
            rightCard.widthAnchor.constraint(equalTo: leftCard.widthAnchor),
            rightCard.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m + 2),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        messageHeight = messageCard.heightAnchor.constraint(equalToConstant: 200)
        messageHeight.isActive = true
        leftTopPlain = leftCard.topAnchor.constraint(equalTo: leftBar.bottomAnchor, constant: 10)
        leftTopReply = leftCard.topAnchor.constraint(equalTo: messageCard.bottomAnchor, constant: 10)
        leftTopPlain.isActive = true
        // Wide: [input][translation][hints]. Narrow: hints under the panes. The set is chosen in viewWillLayout.
        hintsWidth = hints.widthAnchor.constraint(equalToConstant: 0)
        hintsNarrowHeight = hints.heightAnchor.constraint(equalToConstant: 0)
        hintsNarrowHeight.priority = .init(750)
        hintsNarrowGap = hints.topAnchor.constraint(equalTo: leftCard.bottomAnchor, constant: 0)
        // rightCard.trailing = hints.leading - gap  (the constant is negative)
        hintsGap = rightCard.trailingAnchor.constraint(equalTo: hints.leadingAnchor, constant: 0)
        wideConstraints = [
            hintsGap,
            hints.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            hintsWidth,
            hints.topAnchor.constraint(equalTo: leftBar.topAnchor),
            hints.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),
            footer.topAnchor.constraint(equalTo: leftCard.bottomAnchor, constant: 10),
        ]
        narrowConstraints = [
            rightCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            hints.leadingAnchor.constraint(equalTo: leftCard.leadingAnchor),
            hints.trailingAnchor.constraint(equalTo: rightCard.trailingAnchor),
            hintsNarrowGap,
            hintsNarrowHeight,
            footer.topAnchor.constraint(equalTo: hints.bottomAnchor, constant: 10),
            { let c = leftCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 140); c.priority = .init(740); return c }(),
        ]
        // The source popup must not run under the swap button.
        sourcePopup.trailingAnchor.constraint(lessThanOrEqualTo: swap.leadingAnchor, constant: -8).isActive = true
        for p in [sourcePopup!, targetPopup!] {
            p.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        updateStatus()
        root.installOverlay()
    }
}
