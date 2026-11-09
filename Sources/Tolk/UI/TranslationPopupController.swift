// Owned by the "UI" session.
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
final class TranslationPopupController: NSObject, NSTextFieldDelegate {
    let engine: TranslationEngine

    // Layout
    private let width: CGFloat = 440
    private let inset: CGFloat = 14
    private let minTextHeight: CGFloat = 22
    private let maxTextHeight: CGFloat = 340

    private var panel: PopupPanel!
    private let runner: TranslationRunner

    // Views
    private var directionButton: NSButton!
    private var swapButton: NSButton!
    private var providerBadge: BadgeView!
    private var spinner: NSProgressIndicator!
    private var noticeLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var textHeight: NSLayoutConstraint!
    private var glossaryForm: NSStackView!
    private var termField: NSTextField!
    private var termTranslationField: NSTextField!
    private var toneControl: NSSegmentedControl!
    private var glossaryButton: NSButton!
    private var copyButton: NSButton!

    // State
    private var sourceText = ""
    private var translation = ""
    private var requestedSource: Language?
    private var requestedTarget: Language?
    private var detectedSource: Language?
    private var detectedTarget: Language?
    private var fellBackFrom: String?
    private var showsPlaceholder = false
    private var tone: Tone {
        get { Tone(rawValue: UserDefaults.standard.string(forKey: "tolk.popup.tone") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tolk.popup.tone") }
    }

    // Placement
    private var anchor: NSPoint = .zero
    private var placedAbove = false
    private var monitors: [Any] = []
    private var copyResetWork: DispatchWorkItem?

    init(engine: TranslationEngine) {
        self.engine = engine
        self.runner = TranslationRunner(engine: engine)
        super.init()
        runner.onUpdate = { [weak self] in self?.handle($0) }
    }

    // MARK: - Public API

    /// Shows the popup at `point` (screen coords) and starts translating `text`.
    /// Callable from nonisolated code (e.g. `@objc` actions, event-tap callbacks); must run on the main thread.
    nonisolated func show(text: String, at point: NSPoint) {
        MainActor.assumeIsolated { self.present(text: text, at: point) }
    }

    nonisolated func hide() {
        MainActor.assumeIsolated { self.dismiss() }
    }

    private func present(text: String, at point: NSPoint) {
        buildIfNeeded()
        runner.cancel()
        removeMonitors()

        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

        panel.orderFrontRegardless()
        panel.makeKey() // .nonactivatingPanel: takes keystrokes, the other app stays active
        panel.makeFirstResponder(textView)
        installMonitors()
    }

    private func dismiss() {
        runner.cancel()
        removeMonitors()
        copyResetWork?.cancel()
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Translation

    private func startTranslation() {
        translation = ""
        fellBackFrom = nil
        noticeLabel.isHidden = true
        copyButton.isEnabled = false
        glossaryButton.isEnabled = false
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
        runner.start(TranslationRequest(text: sourceText, source: requestedSource,
                                        target: requestedTarget, tone: tone))
    }

    private func handle(_ update: TranslationRunner.Update) {
        switch update {
        case let .started(provider, source, target):
            detectedSource = source
            detectedTarget = target
            updateDirectionTitle()
            providerBadge.text = UIText.providerName(provider)
            providerBadge.tint = UIText.isFallbackProvider(provider) ? .systemOrange : .secondaryLabelColor
            if let from = fellBackFrom {
                showNotice("\(UIText.providerName(from)) недоступен — перевод от \(UIText.providerName(provider))",
                           color: .systemOrange)
            }
        case let .delta(chunk):
            if showsPlaceholder {
                showsPlaceholder = false
                textView.string = ""
            }
            translation += chunk
            textView.textStorage?.append(NSAttributedString(string: chunk, attributes: textAttributes))
            copyButton.isEnabled = true
            glossaryButton.isEnabled = true
            updateSize()
        case let .fellBack(from, reason):
            fellBackFrom = from
            translation = ""
            showMessage("Перевожу через запасной сервис…", color: .tertiaryLabelColor)
            showsPlaceholder = true
            copyButton.isEnabled = false
            showNotice("\(UIText.providerName(from)) недоступен — переключаюсь на Google", color: .systemOrange)
            noticeLabel.toolTip = reason
        case .finished:
            spinner.stopAnimation(nil)
            if translation.isEmpty { showMessage("Пустой перевод.", color: .secondaryLabelColor) }
        case let .failed(message):
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
        return [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
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
        let src = (requestedSource ?? detectedSource)?.label ?? "Авто"
        let dst = (requestedTarget ?? detectedTarget)?.label ?? "…"
        directionButton.title = "\(src) → \(dst)"
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
        for lang in Language.allCases {
            let item = NSMenuItem(title: UIText.intoLanguage(lang), action: #selector(chooseTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = requestedTarget == lang ? .on : .off
            menu.addItem(item)
        }
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
        copyButton.title = "Скопировано ✓"
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resetCopyButton() }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func resetCopyButton() { copyButton?.title = "Копировать" }

    @objc private func closeClicked() { dismiss() }

    @objc private func toggleGlossaryForm() {
        let show = glossaryForm.isHidden
        if show {
            termField.stringValue = sourceText.count <= 60 ? sourceText : ""
            termTranslationField.stringValue = translation.count <= 60
                ? translation.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        setGlossaryFormVisible(show)
        if show { panel.makeFirstResponder(termField) }
    }

    private func setGlossaryFormVisible(_ visible: Bool) {
        glossaryForm.isHidden = !visible
        glossaryButton.state = visible ? .on : .off
        updateSize()
    }

    @objc private func saveGlossaryTerm() {
        let term = termField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = termTranslationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !value.isEmpty else {
            NSSound.beep()
            panel.makeFirstResponder(term.isEmpty ? termField : termTranslationField)
            return
        }
        do {
            try engine.addGlossaryTerm(source: term, translation: value)
            setGlossaryFormVisible(false)
            showNotice("Добавлено в глоссарий: «\(term)» → «\(value)»", color: .systemGreen)
            panel.makeFirstResponder(textView)
        } catch {
            showNotice("Не удалось сохранить в глоссарий: \(error.localizedDescription)", color: .systemRed)
        }
    }

    @objc private func cancelGlossary() {
        setGlossaryFormVisible(false)
        panel.makeFirstResponder(textView)
    }

    // Enter in the second field saves.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if control === termField { panel.makeFirstResponder(termTranslationField) } else { saveGlossaryTerm() }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelGlossary()
            return true
        }
        return false
    }

    // MARK: - Monitors (Esc, click outside)

    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel, event.keyCode == 53 else { return event }
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
        // Prefer below the cursor; go above if the fully grown popup would not fit.
        let expectedMax = min(size.height + maxTextHeight, vf.height * 0.6)
        placedAbove = anchor.y - 18 - expectedMax < vf.minY && vf.maxY - anchor.y > anchor.y - vf.minY
        var origin = NSPoint(x: anchor.x - 24, y: 0)
        origin.y = placedAbove ? anchor.y + 14 : anchor.y - 18 - size.height
        panel.setFrame(clamped(NSRect(origin: origin, size: size), in: vf), display: true)
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

    private func updateSize() {
        guard let panel, panel.isVisible || panel.frame.width > 0 else { return }
        let size = fittingSize()
        var frame = panel.frame
        if placedAbove {
            frame.size = size // bottom edge stays
        } else {
            frame.origin.y = frame.maxY - size.height // top edge stays
            frame.size = size
        }
        let newFrame = clamped(frame, in: screen(for: anchor).visibleFrame)
        if newFrame != panel.frame { panel.setFrame(newFrame, display: true) }
        if !showsPlaceholder { textView.scrollToEndOfDocument(nil) }
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

        swapButton = UIFactory.symbolButton("arrow.left.arrow.right", tooltip: "Поменять направление",
                                            target: self, action: #selector(swapDirection))
        providerBadge = UIFactory.badge()
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let close = UIFactory.symbolButton("xmark", tooltip: "Закрыть (Esc)", target: self, action: #selector(closeClicked))

        let header = NSStackView(views: [directionButton, swapButton, providerBadge, spinner, UIFactory.spacer(), close])
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
        textView.font = .systemFont(ofSize: 15)
        textView.setAccessibilityLabel("Перевод")
        textHeight = scrollView.heightAnchor.constraint(equalToConstant: minTextHeight)
        textHeight.isActive = true

        // Glossary form
        termField = NSTextField()
        termField.placeholderString = "Термин"
        termField.delegate = self
        termTranslationField = NSTextField()
        termTranslationField.placeholderString = "Как переводить"
        termTranslationField.delegate = self
        [termField, termTranslationField].forEach { $0?.controlSize = .small; $0?.font = .systemFont(ofSize: 12) }
        let arrow = UIFactory.label("→", size: 12)
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveGlossaryTerm))
        save.controlSize = .small
        save.bezelStyle = .push
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelGlossary))
        cancel.controlSize = .small
        cancel.bezelStyle = .push
        let fields = NSStackView(views: [termField, arrow, termTranslationField])
        fields.orientation = .horizontal
        fields.spacing = 6
        termField.widthAnchor.constraint(equalTo: termTranslationField.widthAnchor).isActive = true
        let formButtons = NSStackView(views: [UIFactory.label("Добавить в глоссарий", size: 11, weight: .medium),
                                              UIFactory.spacer(), cancel, save])
        formButtons.orientation = .horizontal
        glossaryForm = NSStackView(views: [fields, formButtons])
        glossaryForm.orientation = .vertical
        glossaryForm.alignment = .leading
        glossaryForm.spacing = 6
        glossaryForm.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 2, right: 0)
        fields.widthAnchor.constraint(equalTo: glossaryForm.widthAnchor).isActive = true
        formButtons.widthAnchor.constraint(equalTo: glossaryForm.widthAnchor).isActive = true
        glossaryForm.isHidden = true

        // Footer: tone … glossary, copy
        toneControl = UIFactory.toneControl(target: self, action: #selector(toneChanged(_:)))
        glossaryButton = NSButton(title: "В глоссарий", target: self, action: #selector(toggleGlossaryForm))
        glossaryButton.setButtonType(.pushOnPushOff)
        copyButton = NSButton(title: "Копировать", target: self, action: #selector(copyTranslation))
        for b in [glossaryButton!, copyButton!] {
            b.controlSize = .small
            b.bezelStyle = .push
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        glossaryButton.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        glossaryButton.imagePosition = .imageLeading
        copyButton.imagePosition = .imageLeading
        let footer = NSStackView(views: [toneControl, UIFactory.spacer(), glossaryButton, copyButton])
        footer.orientation = .horizontal
        footer.spacing = 6

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSStackView(views: [header, noticeLabel, scrollView, glossaryForm, separator, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: inset, bottom: 10, right: inset)
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
        for v in [header, noticeLabel!, scrollView!, glossaryForm!, separator, footer] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -inset * 2).isActive = true
        }
        noticeLabel.preferredMaxLayoutWidth = width - inset * 2
    }
}
