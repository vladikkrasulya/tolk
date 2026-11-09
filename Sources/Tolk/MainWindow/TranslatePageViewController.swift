// Owned by the "main window" session.
import AppKit
import TolkCore

/// Root view of the translate page: catches ⌘↩ wherever the focus is inside the page.
private final class TranslatePageView: NSView {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command, event.keyCode == 36 || event.keyCode == 76,
           window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: self) ?? false }) ?? false {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Text view that shows a placeholder when empty.
private final class PlaceholderTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderFont: NSFont = .systemFont(ofSize: 18)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        let rect = NSRect(origin: origin, size: NSSize(width: bounds.width - origin.x * 2, height: bounds.height))
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: [.font: placeholderFont, .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() { super.didChangeText(); needsDisplay = true }
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
            lastTranslatedRequest = nil
            if isViewLoaded { spinner.stopAnimation(nil) }
        }
    }
    private var runner: TranslationRunner
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

    static let inputFontSize: CGFloat = 18

    private var tone: Tone {
        get { Tone(rawValue: UserDefaults.standard.string(forKey: "tolk.input.tone") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tolk.input.tone") }
    }

    init(engine: TranslationEngine) {
        self.engine = engine
        self.runner = TranslationRunner(engine: engine)
        super.init(nibName: nil, bundle: nil)
        runner.onUpdate = { [weak self] in self?.handle($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    /// Puts text into the input and translates it (used by the popup's "expand" button).
    func load(text: String) {
        loadViewIfNeeded()
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
        updateCounter()
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
        // Like DeepL: keep the previous translation visible but dimmed until the new one starts;
        // an empty pane says «Перевожу…».
        if outputView.string.isEmpty {
            outputPlaceholderView.placeholder = "Перевожу…"
        } else if let storage = outputView.textStorage {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                 range: NSRange(location: 0, length: storage.length))
        }
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
            outputView.textStorage?.append(NSAttributedString(string: chunk, attributes: textAttributes()))
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

    @objc private func directionChanged(_ sender: NSPopUpButton) { translateNow() }

    @objc private func swapDirection() {
        let newSource = selectedTarget ?? detectedTarget
        let newTarget = selectedSource ?? detectedSource
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
        translateNow()
    }

    @objc private func clearInput() {
        inputView.string = ""
        inputView.needsDisplay = true
        updateCounter()
        translateNow()
        focusInput()
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
    private func card(_ content: NSView, bottom: NSView, tinted: Bool) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 12
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = tinted ? (NSColor.textBackgroundColor.blended(withFraction: 0.035, of: .labelColor) ?? .textBackgroundColor)
                               : .textBackgroundColor
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
        guard let cv = box.contentView else { return box }
        for v in [content, bottom] { v.translatesAutoresizingMaskIntoConstraints = false; cv.addSubview(v) }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -1),
            content.topAnchor.constraint(equalTo: cv.topAnchor, constant: 1),
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
        let rightBar = NSStackView(views: [targetPopup, UIFactory.spacer(), spinner, providerBadge])
        for b in [leftBar, rightBar] { b.orientation = .horizontal; b.spacing = 8 }

        // Input pane
        let (inScroll, inTV) = makeTextPane(editable: true)
        inputView = inTV as? PlaceholderTextView
        inputView.placeholder = "Введите или вставьте текст"
        inputView.placeholderFont = .systemFont(ofSize: Self.inputFontSize)
        inputView.delegate = self
        inputView.setAccessibilityLabel("Исходный текст")
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
        outputView.setAccessibilityLabel("Перевод")
        outputPlaceholderView.placeholder = "Перевод"
        outputPlaceholderView.placeholderFont = .systemFont(ofSize: Self.inputFontSize)
        noticeLabel = UIFactory.label("", size: 11.5, color: .systemOrange)
        noticeLabel.isHidden = true
        copyButton = NSButton(title: "Копировать", target: self, action: #selector(copyTranslation))
        copyButton.bezelStyle = .push
        copyButton.controlSize = .regular
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.isEnabled = false
        copyButton.toolTip = "Скопировать перевод (⌘↩)"
        let outBottom = NSStackView(views: [noticeLabel, UIFactory.spacer(), copyButton])
        outBottom.orientation = .horizontal

        let leftCard = card(inScroll, bottom: inBottom, tinted: false)
        let rightCard = card(outScroll, bottom: outBottom, tinted: true)

        hintLabel = UIFactory.label(footerHint, size: 11, color: .tertiaryLabelColor)
        let toneLabel = UIFactory.label("Тон", size: 12)
        let footer = NSStackView(views: [hintLabel, UIFactory.spacer(), toneLabel, toneControl])
        footer.orientation = .horizontal
        footer.spacing = 8

        for v in [leftBar, rightBar, swap, leftCard, rightCard, footer] {
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
            rightBar.leadingAnchor.constraint(equalTo: rightCard.leadingAnchor, constant: 26),
            rightBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m - 4),
            leftBar.heightAnchor.constraint(equalToConstant: 28),
            rightBar.heightAnchor.constraint(equalTo: leftBar.heightAnchor),

            swap.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            swap.centerYAnchor.constraint(equalTo: leftBar.centerYAnchor),

            leftCard.topAnchor.constraint(equalTo: leftBar.bottomAnchor, constant: 10),
            leftCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            rightCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            rightCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: 12),
            rightCard.widthAnchor.constraint(equalTo: leftCard.widthAnchor),
            rightCard.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),

            footer.topAnchor.constraint(equalTo: leftCard.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m + 2),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        // The source popup must not run under the swap button.
        sourcePopup.trailingAnchor.constraint(lessThanOrEqualTo: swap.leadingAnchor, constant: -8).isActive = true
        for p in [sourcePopup!, targetPopup!] {
            p.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        updateStatus()
    }
}
