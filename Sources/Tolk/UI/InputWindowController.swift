// Owned by the "UI" session.
import AppKit
import TolkCore

/// Window that routes edit shortcuts (no main menu in an `.accessory` app) and Cmd+Enter.
final class InputWindow: NSWindow {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        if EditShortcuts.handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

/// Window where the user types and the translation updates live while typing.
@MainActor
final class InputWindowController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let engine: TranslationEngine
    private let runner: TranslationRunner
    private let debounce: Duration = .milliseconds(400)

    private var window: InputWindow!
    private var sourcePopup: NSPopUpButton!
    private var targetPopup: NSPopUpButton!
    private var toneControl: NSSegmentedControl!
    private var statusLabel: NSTextField!
    private var providerBadge: BadgeView!
    private var spinner: NSProgressIndicator!
    private var inputView: NSTextView!
    private var placeholder: NSTextField!
    private var outputView: NSTextView!
    private var noticeLabel: NSTextField!
    private var copyButton: NSButton!

    private var debounceTask: Task<Void, Never>?
    private var translation = ""
    private var lastTranslatedRequest: TranslationRequest?
    private var detectedSource: Language?
    private var detectedTarget: Language?
    private var fellBackFrom: String?
    private var awaitingFirstDelta = false
    private var copyResetWork: DispatchWorkItem?

    private var tone: Tone {
        get { Tone(rawValue: UserDefaults.standard.string(forKey: "tolk.input.tone") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tolk.input.tone") }
    }

    init(engine: TranslationEngine) {
        self.engine = engine
        self.runner = TranslationRunner(engine: engine)
        super.init()
        runner.onUpdate = { [weak self] in self?.handle($0) }
    }

    /// Callable from nonisolated code (e.g. `@objc` menu actions); must run on the main thread.
    nonisolated func show() {
        MainActor.assumeIsolated { self.present() }
    }

    /// Opens the window with `text` already in the input (handy for "open in window" actions).
    nonisolated func show(text: String) {
        MainActor.assumeIsolated { self.present(text: text) }
    }

    private func present() {
        let firstTime = window == nil
        buildIfNeeded()
        if firstTime { window.center() }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputView)
    }

    private func present(text: String) {
        present()
        inputView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification))
        translateNow()
    }

    // MARK: - Translation

    private var selectedSource: Language? { language(at: sourcePopup.indexOfSelectedItem) }
    private var selectedTarget: Language? { language(at: targetPopup.indexOfSelectedItem) }

    private func language(at index: Int) -> Language? {
        index <= 0 ? nil : Language.allCases[index - 1]
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !inputView.string.isEmpty
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.translateNow()
        }
    }

    private func translateNow(force: Bool = false) {
        debounceTask?.cancel()
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = TranslationRequest(text: text, source: selectedSource, target: selectedTarget, tone: tone)
        if !force, request == lastTranslatedRequest { return }
        lastTranslatedRequest = request

        runner.cancel()
        translation = ""
        fellBackFrom = nil
        noticeLabel.isHidden = true
        copyButton.isEnabled = false
        guard !text.isEmpty else {
            setOutput("", color: .labelColor)
            spinner.stopAnimation(nil)
            providerBadge.text = ""
            detectedSource = nil
            detectedTarget = nil
            updateStatus()
            return
        }
        awaitingFirstDelta = true
        spinner.startAnimation(nil)
        runner.start(request)
    }

    private func handle(_ update: TranslationRunner.Update) {
        switch update {
        case let .started(provider, source, target):
            detectedSource = source
            detectedTarget = target
            providerBadge.text = UIText.providerName(provider)
            providerBadge.tint = UIText.isFallbackProvider(provider) ? .systemOrange : .secondaryLabelColor
            updateStatus()
            if let from = fellBackFrom {
                showNotice("\(UIText.providerName(from)) недоступен — перевод от \(UIText.providerName(provider))",
                           color: .systemOrange)
            }
        case let .delta(chunk):
            if awaitingFirstDelta {
                awaitingFirstDelta = false
                setOutput("", color: .labelColor)
            }
            translation += chunk
            outputView.textStorage?.append(NSAttributedString(string: chunk, attributes: outputAttributes()))
            copyButton.isEnabled = true
        case let .fellBack(from, reason):
            fellBackFrom = from
            translation = ""
            awaitingFirstDelta = true
            setOutput("", color: .labelColor)
            copyButton.isEnabled = false
            showNotice("\(UIText.providerName(from)) недоступен — переключаюсь на Google", color: .systemOrange)
            noticeLabel.toolTip = reason
        case .finished:
            spinner.stopAnimation(nil)
            awaitingFirstDelta = false
        case let .failed(message):
            spinner.stopAnimation(nil)
            lastTranslatedRequest = nil // allow retry with the same text
            if translation.isEmpty { setOutput(message, color: .systemRed) } else { showNotice(message, color: .systemRed) }
        }
    }

    private func outputAttributes(color: NSColor = .labelColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: color, .paragraphStyle: p]
    }

    private func setOutput(_ text: String, color: NSColor) {
        outputView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: outputAttributes(color: color)))
    }

    private func showNotice(_ text: String, color: NSColor) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = color
        noticeLabel.isHidden = false
    }

    private func updateStatus() {
        if let s = detectedSource, let t = detectedTarget {
            statusLabel.stringValue = "\(s.label) → \(t.label)"
        } else {
            statusLabel.stringValue = ""
        }
        sourcePopup.item(at: 0)?.title = detectedSource.map { "Авто (\($0.label))" } ?? "Определить язык"
        targetPopup.item(at: 0)?.title = detectedTarget.map { "Авто (\($0.label))" } ?? "Авто"
        sourcePopup.synchronizeTitleAndSelectedItem()
        targetPopup.synchronizeTitleAndSelectedItem()
    }

    // MARK: - Actions

    @objc private func directionChanged(_ sender: NSPopUpButton) {
        translateNow()
    }

    @objc private func swapDirection() {
        let newSource = selectedTarget ?? detectedTarget
        let newTarget = selectedSource ?? detectedSource
        sourcePopup.selectItem(at: newSource.flatMap { Language.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        targetPopup.selectItem(at: newTarget.flatMap { Language.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        let result = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty {
            inputView.string = result
            placeholder.isHidden = true
        }
        translateNow()
    }

    @objc private func toneChanged(_ sender: NSSegmentedControl) {
        tone = Tone.allCases[max(0, sender.selectedSegment)]
        translateNow()
    }

    @objc private func copyTranslation() {
        guard !translation.isEmpty else { NSSound.beep(); return }
        Clipboard.copy(translation)
        copyButton.title = "Скопировано ✓"
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copyButton.title = "Копировать перевод" }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func copyAndClose() {
        guard !translation.isEmpty else { NSSound.beep(); return }
        Clipboard.copy(translation)
        window.orderOut(nil)
        NSApp.hide(nil) // return focus to the app the user came from, ready to paste
    }

    // Esc in an editable NSTextView would open the completion list; close the window instead.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { window.performClose(nil); return true }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        debounceTask?.cancel()
        runner.cancel()
        spinner.stopAnimation(nil)
        lastTranslatedRequest = nil
    }

    // MARK: - Building

    private func makeTextPane(editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = editable
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = editable
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 15)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.typingAttributes = outputAttributes()
        return (scroll, tv)
    }

    private func card(_ content: NSView) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .textBackgroundColor
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 1),
                content.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -1),
                content.topAnchor.constraint(equalTo: cv.topAnchor, constant: 1),
                content.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -1),
            ])
        }
        return box
    }

    private func buildIfNeeded() {
        guard window == nil else { return }

        let w = InputWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 440),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        w.title = "Tolk — перевод"
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 560, height: 280)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.delegate = self
        w.onCommandReturn = { [weak self] in self?.copyAndClose() }
        w.setFrameAutosaveName("TolkInputWindow")
        window = w

        let effect = NSVisualEffectView()
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        w.contentView = effect

        // Top bar: [source] ⇄ [target]   tone   …   EN → RU [Qwen] spinner
        sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sourcePopup.addItems(withTitles: ["Определить язык"] + Language.allCases.map { $0.label + " — " + UIText.languageName($0) })
        targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        targetPopup.addItems(withTitles: ["Авто"] + Language.allCases.map { $0.label + " — " + UIText.languageName($0) })
        for p in [sourcePopup!, targetPopup!] {
            p.target = self
            p.action = #selector(directionChanged(_:))
            p.controlSize = .regular
        }
        sourcePopup.toolTip = "Язык оригинала"
        targetPopup.toolTip = "Язык перевода. «Авто»: RU/UA → EN, EN → RU"
        let swap = UIFactory.symbolButton("arrow.left.arrow.right", tooltip: "Поменять направление и тексты",
                                          target: self, action: #selector(swapDirection))
        toneControl = UIFactory.toneControl(target: self, action: #selector(toneChanged(_:)))
        toneControl.controlSize = .regular
        toneControl.font = .systemFont(ofSize: NSFont.systemFontSize)
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: tone) ?? 0
        let toneLabel = UIFactory.label("Тон:", size: 12)
        statusLabel = UIFactory.label("", size: 12, weight: .semibold, color: .secondaryLabelColor)
        providerBadge = UIFactory.badge()
        providerBadge.text = ""
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let topBar = NSStackView(views: [sourcePopup, swap, targetPopup, UIFactory.spacer(),
                                         toneLabel, toneControl, UIFactory.spacer(),
                                         spinner, statusLabel, providerBadge])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.setCustomSpacing(4, after: toneLabel)

        // Panes
        let (inScroll, inView) = makeTextPane(editable: true)
        inputView = inView
        inputView.delegate = self
        inputView.setAccessibilityLabel("Исходный текст")
        placeholder = UIFactory.label("Введите или вставьте текст — перевод появится справа", size: 15,
                                      color: .placeholderTextColor)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.setContentCompressionResistancePriority(.init(1), for: .horizontal) // must not widen the pane
        inScroll.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: inScroll.leadingAnchor, constant: 14),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: inScroll.trailingAnchor, constant: -14),
            placeholder.topAnchor.constraint(equalTo: inScroll.topAnchor, constant: 14),
        ])

        let (outScroll, outView) = makeTextPane(editable: false)
        outputView = outView
        outputView.setAccessibilityLabel("Перевод")

        let leftCard = card(inScroll)
        let rightCard = card(outScroll)
        (rightCard as? NSBox)?.fillColor = NSColor.textBackgroundColor.blended(withFraction: 0.04, of: .labelColor) ?? .textBackgroundColor
        let panes = NSStackView(views: [leftCard, rightCard])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.spacing = 10
        panes.setContentHuggingPriority(.defaultLow, for: .vertical)

        // Footer: hint … notice … copy
        let hint = UIFactory.label("⌘↩ — скопировать и закрыть   ·   Esc — закрыть", size: 11, color: .tertiaryLabelColor)
        noticeLabel = UIFactory.label("", size: 11.5, color: .systemOrange)
        noticeLabel.isHidden = true
        copyButton = NSButton(title: "Копировать перевод", target: self, action: #selector(copyTranslation))
        copyButton.bezelStyle = .push
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.isEnabled = false
        let footer = NSStackView(views: [hint, UIFactory.spacer(), noticeLabel, copyButton])
        footer.orientation = .horizontal
        footer.spacing = 10

        let root = NSStackView(views: [topBar, panes, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 36, left: 16, bottom: 14, right: 16) // 36: below the transparent titlebar
        root.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        for v in [topBar, panes, footer] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
    }
}
