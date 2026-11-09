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
final class TranslationPopupController: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
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
    private var insertButton: NSButton!
    private var backButton: NSButton!
    private var backBox: NSStackView!
    private var backTitle: NSTextField!
    private var backText: NSTextField!
    private var notesBox: NSStackView!
    private var notesButton: NSButton!
    private var notesTask: Task<Void, Never>?
    private var lastProvider = ""
    private var presentGeneration = 0
    private var resizeScheduled = false

    /// Called with the source text when the user expands the popup into the input window.
    var onExpand: ((String) -> Void)?
    /// Tone for the app the user copied from (bundle id); used when the tone switch is "Авто".
    var toneForApp: ((String?) -> Tone)?
    private var frontApp: String?
    private var altBox: NSStackView!
    private var altTask: Task<Void, Never>?
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
    private var backRunner: TranslationRunner
    private var backTranslation = ""
    /// Back-translation toggle (remembered): after each translation, translate it back to check meaning.
    private var backEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "tolk.popup.back") }
        set { UserDefaults.standard.set(newValue, forKey: "tolk.popup.back") }
    }
    /// Footnotes toggle (remembered, on by default): notes on debatable industry terms.
    private var notesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "tolk.popup.notes") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tolk.popup.notes") }
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
    private var placedAbove = false
    private var monitors: [Any] = []
    private var copyResetWork: DispatchWorkItem?

    init(engine: TranslationEngine) {
        self.engine = engine
        self.runner = TranslationRunner(engine: engine)
        self.backRunner = TranslationRunner(engine: engine)
        super.init()
        runner.onUpdate = { [weak self] in self?.handle($0) }
        backRunner.onUpdate = { [weak self] in self?.handleBack($0) }
    }

    // MARK: - Public API

    /// Shows the popup at `point` (screen coords) and starts translating `text`.
    /// Callable from nonisolated code (e.g. `@objc` actions, event-tap callbacks); must run on the main thread.
    nonisolated func show(text: String, at point: NSPoint) {
        MainActor.assumeIsolated { self.present(text: text, at: point) }
    }

    /// Swaps the engine after settings change (cancels anything running).
    func replaceEngine(_ new: TranslationEngine) {
        dismiss()
        engine = new
        runner = TranslationRunner(engine: new)
        backRunner = TranslationRunner(engine: new)
        runner.onUpdate = { [weak self] in self?.handle($0) }
        backRunner.onUpdate = { [weak self] in self?.handleBack($0) }
    }

    nonisolated func hide() {
        MainActor.assumeIsolated { self.dismiss() }
    }

    private func present(text: String, at point: NSPoint) {
        presentGeneration += 1
        buildIfNeeded()
        runner.cancel()
        backRunner.cancel()
        removeMonitors()

        sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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
        installMonitors()
    }

    private func dismiss() {
        runner.cancel()
        backRunner.cancel()
        notesTask?.cancel()
        altTask?.cancel()
        altWork?.cancel()
        removeMonitors()
        copyResetWork?.cancel()
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

    // MARK: - Translation

    private func startTranslation() {
        translation = ""
        fellBackFrom = nil
        mainFinished = false
        noticeLabel.isHidden = true
        copyButton.isEnabled = false
        insertButton.isEnabled = false
        glossaryButton.isEnabled = false
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
        runner.start(TranslationRequest(text: sourceText, source: requestedSource,
                                        target: requestedTarget, tone: effectiveTone))
    }

    /// Manual tone wins; "Авто" picks the tone configured for the app the text came from (Slack → chat, Mail → formal).
    private var effectiveTone: Tone { tone == .auto ? (toneForApp?(frontApp) ?? .auto) : tone }

    private func handle(_ update: TranslationRunner.Update) {
        switch update {
        case let .started(provider, source, target):
            detectedSource = source
            detectedTarget = target
            updateDirectionTitle()
            lastProvider = provider
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
            insertButton.isEnabled = true
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
            mainFinished = true
            if translation.isEmpty { showMessage("Пустой перевод.", color: .secondaryLabelColor) }
            else {
                if backEnabled { startBack() }
                if notesEnabled { startNotes() }
            }
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
        copyButton.title = "Скопировано ✓"
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resetCopyButton() }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func resetCopyButton() { copyButton?.title = "Копировать" }

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
        altTask?.cancel()
        showAlternatives(fragment: fragment, range: range, options: nil)
        let engine = self.engine, source = sourceText, translated = translation
        altTask = Task { @MainActor [weak self] in
            let options = await engine.alternatives(for: fragment, in: translated, source: source, from: src, to: dst)
            guard let self, !Task.isCancelled, self.translation == translated,
                  self.textView.selectedRange() == range else { return }
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
        altTask?.cancel()
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
        notesTask?.cancel()
        notesTask = nil
        notesButton.state = notesEnabled ? .on : .off
        notesBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        notesBox.isHidden = true
        updateSize()
    }

    private func startNotes() {
        // Notes come from Qwen; with the Google fallback there is no model to ask.
        guard !UIText.isFallbackProvider(lastProvider), let src = detectedSource, let dst = detectedTarget else { return }
        let source = sourceText, translated = translation, engine = self.engine
        notesTask?.cancel()
        showNotesLoading()
        notesTask = Task { @MainActor [weak self] in
            let notes = await engine.notes(source: source, translation: translated, from: src, to: dst)
            guard let self, !Task.isCancelled, self.translation == translated else { return }
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
        let text = NSMutableAttributedString()
        let small = NSFont.systemFont(ofSize: 12.5)
        text.append(NSAttributedString(string: "\(index). ", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
        text.append(NSAttributedString(string: n.term, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: " → «\(n.used)»", attributes: [.font: small, .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "\n" + n.note, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width - inset * 2 - 20
        label.isSelectable = true

        var buttons: [NSView] = []
        let keep = ClosureButton(title: "Так и оставить", symbol: "checkmark") { [weak self] in
            self?.saveNote(term: n.term, value: n.used, retranslate: false)
        }
        keep.toolTip = "Сохранить «\(n.term) → \(n.used)» в глоссарий"
        buttons.append(keep)
        if let sug = n.suggestion {
            let use = ClosureButton(title: "«\(sug)»", symbol: "arrow.triangle.2.circlepath") { [weak self] in
                self?.saveNote(term: n.term, value: sug, retranslate: true)
            }
            use.toolTip = "Сохранить «\(n.term) → \(sug)» в глоссарий и перевести заново"
            buttons.append(use)
        }
        let row = NSStackView(views: buttons + [UIFactory.spacer()])
        row.orientation = .horizontal
        row.spacing = 6
        let box = NSStackView(views: [label, row])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        return box
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
            backRunner.cancel()
            backBox.isHidden = true
        }
        updateSize()
    }

    private func resetBack() {
        backRunner.cancel()
        backTranslation = ""
        backButton.state = backEnabled ? .on : .off
        backBox.isHidden = !backEnabled
        if backEnabled { setBack(title: "Обратный перевод", text: "Появится после перевода…", color: .tertiaryLabelColor) }
    }

    private func startBack() {
        guard let src = detectedTarget, let dst = detectedSource else { return }
        backTranslation = ""
        backBox.isHidden = false
        setBack(title: "Обратно: \(src.flag) → \(dst.flag) \(UIText.capitalized(dst))", text: "Перевожу обратно…", color: .tertiaryLabelColor)
        updateSize()
        backRunner.start(TranslationRequest(text: translation, source: src, target: dst, tone: .auto))
    }

    private func handleBack(_ update: TranslationRunner.Update) {
        switch update {
        case .started, .fellBack:
            backTranslation = ""
        case let .delta(chunk):
            backTranslation += chunk
            setBack(title: nil, text: backTranslation, color: .secondaryLabelColor)
        case .finished:
            if backTranslation.isEmpty { setBack(title: nil, text: "—", color: .tertiaryLabelColor) }
        case let .failed(message):
            setBack(title: nil, text: message, color: .systemRed)
        }
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
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            if event.keyCode == 36, event.modifierFlags.contains(.command) { self.insertTranslation(); return nil }
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

    /// Streaming calls this on every chunk; resize at most once per ~frame and animate it, so the
    /// popup grows smoothly instead of jumping on each word.
    private func updateSize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                self?.resizeScheduled = false
                self?.applySize()
            }
        }
    }

    private func applySize() {
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
        if newFrame != panel.frame {
            if panel.isVisible, abs(newFrame.height - panel.frame.height) < 400 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    panel.animator().setFrame(newFrame, display: true)
                }
            } else {
                panel.setFrame(newFrame, display: true)
            }
        }
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
        let expand = UIFactory.symbolButton("arrow.up.left.and.arrow.down.right", tooltip: "Открыть в окне перевода",
                                            target: self, action: #selector(expandClicked))

        let header = NSStackView(views: [directionButton, swapButton, providerBadge, spinner, UIFactory.spacer(), expand, close])
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
        insertButton.keyEquivalent = ""
        for b in [backButton!, insertButton!] {
            b.controlSize = .small
            b.bezelStyle = .push
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.imagePosition = .imageLeading
        }
        glossaryButton.title = ""
        glossaryButton.imagePosition = .imageOnly
        glossaryButton.toolTip = "Добавить термин в глоссарий"
        copyButton.toolTip = "Копировать перевод (⌘C)"
        for b in [backButton!, insertButton!] { b.imagePosition = .imageOnly }
        // The tone switch must never be squeezed into «А… Чат П…».
        toneControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        toneControl.setContentHuggingPriority(.required, for: .horizontal)
        let footer = NSStackView(views: [toneControl, UIFactory.spacer(), backButton, notesButton, glossaryButton, copyButton, insertButton])
        footer.orientation = .horizontal
        footer.spacing = 6

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSStackView(views: [header, noticeLabel, scrollView, altBox, notesBox, backBox, glossaryForm, separator, footer])
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
        for v in [header, noticeLabel!, scrollView!, altBox!, notesBox!, backBox!, glossaryForm!, separator, footer] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -inset * 2).isActive = true
        }
        noticeLabel.preferredMaxLayoutWidth = width - inset * 2
    }
}
