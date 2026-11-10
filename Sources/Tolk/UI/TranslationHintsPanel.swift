// «Подсказки» — panel for the big translate page: checks, footnotes, back-translation, word alternatives,
// glossary form, editor before/after. Built from the same jobs/views as the popup (HintsKit).
//
// Requests: only after the translation is finished and the user has paused typing for `pause`;
// any new typing cancels them. Order: back-translation, then footnotes (the Ollama server has two slots;
// the alternatives request is the second one, on demand).
import AppKit
import TolkCore

// MARK: - Collapsible card

private final class HintHeaderRow: NSStackView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

@MainActor
final class HintCard: NSView {
    private let box = NSBox()
    private let chevron = NSImageView()
    private let titleLabel = UIFactory.label("", size: 12.5, weight: .semibold, color: .labelColor)
    private let countBadge = UIFactory.badge()
    private let bodyHolder = NSStackView()
    private let header = HintHeaderRow()
    /// Buttons at the right of the header.
    let accessory = NSStackView()
    private let key: String
    private(set) var isCollapsed: Bool

    init(id: String, title: String, symbol: String, body: NSView, tint: NSColor? = nil, collapsedByDefault: Bool = false) {
        key = "tolk.hints.collapsed.\(id)"
        isCollapsed = UserDefaults.standard.object(forKey: "tolk.hints.collapsed.\(id)") as? Bool ?? collapsedByDefault
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = Self.fill(tint)
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        chevron.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = tint == nil ? .secondaryLabelColor : tint
        titleLabel.stringValue = title
        countBadge.text = ""
        accessory.orientation = .horizontal
        accessory.spacing = 4
        header.setViews([chevron, icon, titleLabel, countBadge, UIFactory.spacer(), accessory], in: .leading)
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        header.heightAnchor.constraint(equalToConstant: 34).isActive = true
        header.onClick = { [weak self] in self?.toggle() }

        bodyHolder.orientation = .vertical
        bodyHolder.alignment = .leading
        bodyHolder.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        bodyHolder.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: bodyHolder.widthAnchor, constant: -24).isActive = true

        let inner = NSStackView(views: [header, bodyHolder])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        guard let cv = box.contentView else { return }
        cv.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: cv.leadingAnchor), inner.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            inner.topAnchor.constraint(equalTo: cv.topAnchor), inner.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            header.widthAnchor.constraint(equalTo: inner.widthAnchor),
            bodyHolder.widthAnchor.constraint(equalTo: inner.widthAnchor),
        ])
        applyCollapsed()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setCount(_ n: Int?) { countBadge.text = n.map(String.init) ?? "" }

    private func toggle() {
        isCollapsed.toggle()
        UserDefaults.standard.set(isCollapsed, forKey: key)
        applyCollapsed()
    }

    private func applyCollapsed() {
        bodyHolder.isHidden = isCollapsed
        chevron.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
    }

    /// Dynamic: follows light/dark; a tint is blended in lightly.
    private static func fill(_ tint: NSColor?) -> NSColor {
        NSColor(name: nil) { appearance in
            let base = NSColor.textBackgroundColor
            var result = base
            appearance.performAsCurrentDrawingAppearance {
                let mixed = tint.flatMap { base.blended(withFraction: 0.09, of: $0) } ?? base
                result = mixed.usingColorSpace(.sRGB) ?? base
            }
            return result
        }
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - Panel

@MainActor
final class TranslationHintsPanel: NSView {
    var engine: TranslationEngine
    /// A footnote replacement was saved to the glossary: translate again.
    var onRetranslate: (() -> Void)?
    /// An alternative was chosen: replace `range` of the translation with the text.
    var onReplace: ((NSRange, String) -> Void)?
    /// «Вернуть» in the editor card.
    var onRevertEdit: (() -> Void)?
    /// Pause in typing (after a finished translation) before any request goes out.
    var pause: Duration = .milliseconds(1500)

    private struct Context {
        var source: String
        var translation: String
        var from: Language
        var to: Language
        var provider: String
        var stale = false // translation edited after the back-translation was made
    }
    private var ctx: Context?
    private var generation = 0
    private var startTask: Task<Void, Never>?
    private let back = BackTranslationJob()
    private let notesJob = HintTask()
    private let altJob = HintTask()
    private var altWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    private var pendingNotes = false
    private var requestsStarted = false
    private var backShown = false
    private var warnings: [String] = []
    private var scrollBottom: NSLayoutConstraint!

    // Views
    private let notesCheck = NSButton(checkboxWithTitle: "Сноски", target: nil, action: nil)
    private let backCheck = NSButton(checkboxWithTitle: "Обратный", target: nil, action: nil)
    private let stack = NSStackView()
    private let emptyLabel = UIFactory.wrappingLabel("", size: 12, color: .tertiaryLabelColor)
    private let feedback = UIFactory.label("", size: 11.5, color: .secondaryLabelColor)

    private let warnBody = NSStackView()
    private let backCaption = UIFactory.label("", size: 11, color: .tertiaryLabelColor)
    private let backText = UIFactory.flexibleLabel("", size: 12.5, color: .secondaryLabelColor)
    private let backLegend = UIFactory.label("Подсвечены слова, которых нет в оригинале", size: 10.5, color: .tertiaryLabelColor)
    private let notesBody = NSStackView()
    private let altBody = NSStackView()
    private let editBefore = UIFactory.flexibleLabel("", size: 12.5, color: .secondaryLabelColor)
    private let editAfter = UIFactory.flexibleLabel("", size: 12.5, color: .labelColor)
    private let glossary = GlossaryFormView(stacked: true, showsTitle: false)

    private var warnCard: HintCard!
    private var backCard: HintCard!
    private var notesCard: HintCard!
    private var altCard: HintCard!
    private var editCard: HintCard!
    private var glossaryCard: HintCard!
    private var backRefresh: NSButton!

    init(engine: TranslationEngine) {
        self.engine = engine
        super.init(frame: .zero)
        build()
        back.onUpdate = { [weak self] in self?.handleBack($0) }
        refreshAll()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Driver (called by the page)

    /// New typing / new translation under way: everything shown is out of date. The context is kept for `resume()`.
    func suspend() {
        generation += 1
        startTask?.cancel(); startTask = nil
        back.cancel(); notesJob.cancel(); altJob.cancel(); altWork?.cancel()
        pendingNotes = false
        requestsStarted = false
        backShown = false
        clearNotes(); clearAlternatives()
        refreshAll()
    }

    /// Nothing to hint about (empty input, a new translation starts).
    func invalidate() {
        suspend()
        ctx = nil
        warnings = []
        setEditorChange(before: nil, after: nil)
        refreshAll()
    }

    /// Same translation as before is still valid (typing changed nothing): ask again after the pause.
    func resume() {
        guard let c = ctx else { return }
        ready(source: c.source, translation: c.translation, from: c.from, to: c.to, provider: c.provider, statsWarnings: nil)
    }

    /// The translation is finished. Checks show at once (no network); requests start after the pause.
    /// `statsWarnings` are the engine's own findings (nil = keep the last ones for the same text).
    func ready(source: String, translation: String, from: Language, to: Language, provider: String,
               statsWarnings: [String]?) {
        suspend()
        ctx = Context(source: source, translation: translation, from: from, to: to, provider: provider)
        if let statsWarnings {
            var all = TranslationCheck.warnings(source: source, translation: translation, from: from, to: to)
            for w in statsWarnings where !all.contains(w) { all.append(w) }
            warnings = all
        } else {
            warnings = TranslationCheck.warnings(source: source, translation: translation, from: from, to: to)
        }
        if glossary.termField.stringValue.isEmpty, glossary.valueField.stringValue.isEmpty {
            glossary.fill(term: source.count <= 60 ? source : "", value: translation.count <= 60 ? translation : "")
        }
        refreshAll()
        let gen = generation
        startTask = Task { @MainActor [weak self, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.runRequests()
        }
    }

    /// The text of the translation changed under the panel (an alternative was applied).
    func translationEdited(_ translation: String) {
        guard var c = ctx else { return }
        c.translation = translation
        c.stale = true
        ctx = c
        warnings = TranslationCheck.warnings(source: c.source, translation: translation, from: c.from, to: c.to)
        clearAlternatives()
        refreshAll()
    }

    /// Editor pass result for the before/after card (nil, nil = hide).
    func setEditorChange(before: String?, after: String?) {
        if let before, let after {
            let (b, a) = Self.diff(old: before, new: after)
            editBefore.attributedStringValue = b
            editAfter.attributedStringValue = a
            editCard.isHidden = false
        } else {
            editCard.isHidden = true
        }
        refreshEmpty()
    }

    /// The user selected text in the input: a candidate for the term field.
    func suggestTerm(_ text: String) { glossary.fill(term: text) }

    /// The user selected `fragment` in the translation: its alternatives (after a short wait) and the glossary value.
    func fragmentSelected(_ fragment: String, range: NSRange) {
        glossary.fill(value: fragment)
        altWork?.cancel()
        guard let c = ctx, !UIText.isFallbackProvider(c.provider), fragment.count >= 2, range.length <= 60 else { return }
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.loadAlternatives(fragment: fragment, range: range)
            }
        }
        altWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    var hasContext: Bool { ctx != nil }

    // MARK: - Requests

    private func runRequests() {
        guard ctx != nil else { return }
        requestsStarted = true
        if HintsSettings.backEnabled {
            pendingNotes = HintsSettings.notesEnabled
            startBack()
        } else if HintsSettings.notesEnabled {
            startNotes()
        }
    }

    private func startBack() {
        guard let c = ctx else { return }
        backShown = true
        backCaption.stringValue = "На \(c.from.russianName): \(c.to.flag) → \(c.from.flag)"
        backText.stringValue = "Перевожу обратно…"
        backText.textColor = .tertiaryLabelColor
        backLegend.isHidden = true
        refreshAll()
        back.start(engine: engine, translation: c.translation, from: c.to, to: c.from)
    }

    private func handleBack(_ update: BackTranslationJob.Update) {
        guard let c = ctx else { return }
        switch update {
        case let .running(text):
            if !text.isEmpty { backText.stringValue = text; backText.textColor = .secondaryLabelColor }
        case let .finished(text):
            if text.isEmpty {
                backText.stringValue = "—"; backText.textColor = .tertiaryLabelColor
            } else {
                backText.attributedStringValue = Self.highlight(text, against: c.source)
                backLegend.isHidden = backText.attributedStringValue.string.isEmpty || !Self.hasHighlight(backText.attributedStringValue)
            }
            if var cc = ctx { cc.stale = false; ctx = cc }
            startPendingNotes()
        case let .failed(message):
            backText.stringValue = message; backText.textColor = .systemRed
            startPendingNotes()
        }
        refreshAll()
    }

    private func startPendingNotes() {
        guard pendingNotes else { return }
        pendingNotes = false
        if HintsSettings.notesEnabled { startNotes() }
    }

    private func startNotes() {
        // Notes come from the home model; with a web fallback there is nobody to ask.
        guard let c = ctx, !UIText.isFallbackProvider(c.provider) else { return }
        let gen = generation
        let engine = self.engine, source = c.source, translated = c.translation, from = c.from, to = c.to
        notesBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addFull(UIFactory.label("Ищу спорные термины…", size: 12, color: .tertiaryLabelColor), to: notesBody)
        notesCard.setCount(nil)
        notesCard.isHidden = false
        refreshEmpty()
        notesJob.run({ await engine.notes(source: source, translation: translated, from: from, to: to) }) { [weak self] notes in
            guard let self, self.generation == gen else { return }
            self.showNotes(notes)
        }
    }

    private func showNotes(_ notes: [TranslationNote]) {
        notesBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !notes.isEmpty else { notesCard.isHidden = true; refreshEmpty(); return }
        for (i, n) in notes.enumerated() {
            let row = NoteRow.make(n, index: i + 1, width: nil) { [weak self] value, retranslate in
                self?.saveNote(term: n.term, value: value, retranslate: retranslate)
            }
            addFull(row, to: notesBody)
        }
        notesCard.setCount(notes.count)
        notesCard.isHidden = false
        refreshEmpty()
    }

    private func clearNotes() {
        notesBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        notesCard.isHidden = true
    }

    private func saveNote(term: String, value: String, retranslate: Bool) {
        do {
            try engine.addGlossaryTerm(source: term, translation: value)
            if retranslate {
                flash("В глоссарии: «\(term)» → «\(value)». Перевожу заново.", color: .systemGreen)
                onRetranslate?()
            } else {
                flash("В глоссарии: «\(term)» → «\(value)»", color: .systemGreen)
            }
        } catch {
            flash("Не удалось сохранить в глоссарий: \(error.localizedDescription)", color: .systemRed)
        }
    }

    // MARK: - Alternatives

    private func loadAlternatives(fragment: String, range: NSRange) {
        guard let c = ctx else { return }
        let gen = generation
        altJob.cancel()
        showAlternatives(fragment: fragment, range: range, options: nil)
        let engine = self.engine, source = c.source, translated = c.translation, from = c.from, to = c.to
        altJob.run({ await engine.alternatives(for: fragment, in: translated, source: source, from: from, to: to) }) { [weak self] options in
            guard let self, self.generation == gen else { return }
            self.showAlternatives(fragment: fragment, range: range, options: options)
        }
    }

    private func showAlternatives(fragment: String, range: NSRange, options: [String]?) {
        altBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = UIFactory.label("Вместо «\(fragment)»:", size: 11.5, weight: .semibold, color: .secondaryLabelColor)
        title.lineBreakMode = .byTruncatingMiddle
        addFull(title, to: altBody)
        if let options {
            if options.isEmpty { addFull(UIFactory.label("вариантов нет", size: 12, color: .tertiaryLabelColor), to: altBody) }
            for o in options {
                let b = ClosureButton(title: o) { [weak self] in self?.onReplace?(range, o) }
                b.toolTip = "Заменить «\(fragment)» на «\(o)»"
                altBody.addArrangedSubview(b)
            }
            altCard.setCount(options.isEmpty ? nil : options.count)
        } else {
            addFull(UIFactory.label("подбираю варианты…", size: 12, color: .tertiaryLabelColor), to: altBody)
            altCard.setCount(nil)
        }
        altCard.isHidden = false
        refreshEmpty()
        // The card may sit below the fold: bring it into view once the layout has settled.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.altCard.isHidden else { return }
                self.altCard.superview?.layoutSubtreeIfNeeded()
                self.altCard.scrollToVisible(self.altCard.bounds)
            }
        }
    }

    private func clearAlternatives() {
        altJob.cancel()
        altBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        altCard.isHidden = true
    }

    // MARK: - Toggles / actions

    @objc private func notesToggled() {
        HintsSettings.notesEnabled = notesCheck.state == .on
        if HintsSettings.notesEnabled {
            if ctx != nil, requestsStarted, !back.isRunning { startNotes() }
        } else {
            notesJob.cancel(); pendingNotes = false; clearNotes(); refreshEmpty()
        }
    }

    @objc private func backToggled() {
        HintsSettings.backEnabled = backCheck.state == .on
        if HintsSettings.backEnabled {
            if ctx != nil, requestsStarted { pendingNotes = false; startBack() } else { refreshAll() }
        } else {
            back.cancel(); backShown = false; refreshAll()
        }
    }

    @objc private func refreshBack() { if ctx != nil { pendingNotes = false; startBack() } }

    @objc private func revertEdit() { onRevertEdit?() }

    private func setFeedbackVisible(_ v: Bool) {
        feedback.isHidden = !v
        scrollBottom.constant = v ? -22 : 0
    }

    private func flash(_ text: String, color: NSColor) {
        feedback.stringValue = text
        feedback.textColor = color
        setFeedbackVisible(true)
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setFeedbackVisible(false) } }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    // MARK: - Display

    private func refreshAll() {
        notesCheck.state = HintsSettings.notesEnabled ? .on : .off
        backCheck.state = HintsSettings.backEnabled ? .on : .off
        // checks
        warnBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for w in warnings {
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 10.5, weight: .regular)
            icon.contentTintColor = .systemOrange
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = UIFactory.flexibleLabel(w, size: 12.5, color: .labelColor)
            let row = NSStackView(views: [icon, label])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            addFull(row, to: warnBody)
        }
        warnCard.isHidden = warnings.isEmpty
        warnCard.setCount(warnings.isEmpty ? nil : warnings.count)
        // back-translation
        backCard.isHidden = !(HintsSettings.backEnabled && ctx != nil && backShown)
        backRefresh.isHidden = !(ctx?.stale ?? false)
        glossaryCard.isHidden = ctx == nil
        if let c = ctx, c.stale, backShown { backCaption.stringValue = "Перевод изменён — обратный перевод устарел" }
        refreshEmpty()
    }

    private func refreshEmpty() {
        let visible = [warnCard, backCard, notesCard, altCard, editCard].contains { $0?.isHidden == false }
        emptyLabel.isHidden = visible
        let anyEnabled = HintsSettings.backEnabled || HintsSettings.notesEnabled
        if ctx == nil {
            emptyLabel.stringValue = "Подсказки появятся, когда перевод будет готов."
        } else if back.isRunning || notesJob.isRunning {
            emptyLabel.stringValue = "Смотрю, что можно улучшить…"
        } else if !requestsStarted && anyEnabled {
            emptyLabel.stringValue = "Подсказки появятся, когда вы закончите печатать."
        } else if !anyEnabled {
            emptyLabel.stringValue = "Предупреждений нет. Сноски и обратный перевод выключены — включите их вверху."
        } else {
            emptyLabel.stringValue = "Спорных мест не найдено. Выделите слово в переводе — предложу варианты."
        }
    }

    private func addFull(_ v: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private static func words(_ s: String) -> [(String, NSRange)] {
        var out: [(String, NSRange)] = []
        let ns = s as NSString
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+") else { return out }
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append((ns.substring(with: m.range).lowercased(), m.range))
        }
        return out
    }

    /// Back-translated text with the words that the original does not contain marked (a quick visual diff).
    static func highlight(_ back: String, against source: String) -> NSAttributedString {
        let known = Set(words(source).map(\.0))
        let stems = Set(known.filter { $0.count >= 5 }.map { String($0.prefix(5)) })
        let out = NSMutableAttributedString(string: back, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
        for (w, r) in words(back) where w.count >= 4 {
            if known.contains(w) { continue }
            if w.count >= 5, stems.contains(String(w.prefix(5))) { continue }
            out.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.2), range: r)
        }
        return out
    }

    /// Word-level before/after: removed words marked in the old text, added words in the new one.
    static func diff(old: String, new: String) -> (NSAttributedString, NSAttributedString) {
        let a = words(old), b = words(new)
        let d = b.map(\.0).difference(from: a.map(\.0))
        let base: (NSColor) -> [NSAttributedString.Key: Any] = { [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: $0] }
        let oldOut = NSMutableAttributedString(string: old, attributes: base(.secondaryLabelColor))
        let newOut = NSMutableAttributedString(string: new, attributes: base(.labelColor))
        for change in d {
            switch change {
            case let .remove(offset, _, _):
                oldOut.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.22), range: a[offset].1)
            case let .insert(offset, _, _):
                newOut.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.28), range: b[offset].1)
            }
        }
        return (oldOut, newOut)
    }

    private static func hasHighlight(_ a: NSAttributedString) -> Bool {
        var found = false
        a.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: a.length)) { v, _, stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }

    // MARK: - Building

    private func build() {
        // Header
        let title = UIFactory.label("Подсказки", size: 13, weight: .semibold, color: .labelColor)
        for c in [notesCheck, backCheck] {
            c.controlSize = .small
            c.font = .systemFont(ofSize: 11.5)
        }
        notesCheck.target = self; notesCheck.action = #selector(notesToggled)
        backCheck.target = self; backCheck.action = #selector(backToggled)
        notesCheck.toolTip = "Пояснения к спорным отраслевым терминам (общая настройка с всплывающим окном)"
        backCheck.toolTip = "Перевести перевод обратно, чтобы проверить смысл (общая настройка с всплывающим окном)"
        let header = NSStackView(views: [title, UIFactory.spacer(), notesCheck, backCheck])
        header.orientation = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        // Card bodies
        for s in [warnBody, notesBody, altBody] {
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 8
        }
        backCaption.lineBreakMode = .byTruncatingTail
        let backBody = NSStackView(views: [backCaption, backText, backLegend])
        backBody.orientation = .vertical
        backBody.alignment = .leading
        backBody.spacing = 6
        backText.widthAnchor.constraint(equalTo: backBody.widthAnchor).isActive = true
        let editBody = NSStackView(views: [
            UIFactory.label("Было", size: 11, weight: .semibold, color: .tertiaryLabelColor), editBefore,
            UIFactory.label("Стало", size: 11, weight: .semibold, color: .tertiaryLabelColor), editAfter,
        ])
        editBody.orientation = .vertical
        editBody.alignment = .leading
        editBody.spacing = 4
        editBody.setCustomSpacing(10, after: editBefore)
        editBefore.widthAnchor.constraint(equalTo: editBody.widthAnchor).isActive = true
        editAfter.widthAnchor.constraint(equalTo: editBody.widthAnchor).isActive = true
        glossary.onSave = { [weak self] term, value in
            guard let self else { return }
            do {
                try self.engine.addGlossaryTerm(source: term, translation: value)
                self.flash("Добавлено в глоссарий: «\(term)» → «\(value)»", color: .systemGreen)
                self.glossary.clear()
            } catch {
                self.flash("Не удалось сохранить в глоссарий: \(error.localizedDescription)", color: .systemRed)
            }
        }
        glossary.onCancel = { [weak self] in self?.glossary.clear() }

        warnCard = HintCard(id: "warnings", title: "Проверка", symbol: "checkmark.shield", body: warnBody, tint: .systemOrange)
        notesCard = HintCard(id: "notes", title: "Сноски", symbol: "lightbulb", body: notesBody)
        backCard = HintCard(id: "back", title: "Обратный перевод", symbol: "arrow.uturn.backward", body: backBody)
        altCard = HintCard(id: "alternatives", title: "Варианты слова", symbol: "text.word.spacing", body: altBody)
        editCard = HintCard(id: "editor", title: "Правка редактора", symbol: "wand.and.stars", body: editBody)
        glossaryCard = HintCard(id: "glossary", title: "В глоссарий", symbol: "book", body: glossary, collapsedByDefault: true)

        backRefresh = UIFactory.symbolButton("arrow.clockwise", tooltip: "Перевести обратно заново", target: self,
                                             action: #selector(refreshBack))
        backCard.accessory.addArrangedSubview(backRefresh)
        let revert = UIFactory.symbolButton("arrow.uturn.backward.circle", tooltip: "Вернуть перевод до редактирования",
                                            target: self, action: #selector(revertEdit))
        editCard.accessory.addArrangedSubview(revert)

        // Cards stack inside a scroll view
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.maximumNumberOfLines = 0
        let cards = [warnCard!, notesCard!, backCard!, altCard!, editCard!, glossaryCard!]
        for v in [emptyLabel] + cards { stack.addArrangedSubview(v) }
        for v in [emptyLabel] + cards { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: v === emptyLabel ? -8 : 0).isActive = true }
        emptyLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        for c in [warnCard!, notesCard!, backCard!, altCard!, editCard!] { c.isHidden = true }

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),
        ])

        feedback.isHidden = true
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        feedback.translatesAutoresizingMaskIntoConstraints = false
        for v in [header, scroll, feedback] { addSubview(v) }
        NSLayoutConstraint.activate([
            scrollBottom,
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            header.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            feedback.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            feedback.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            feedback.bottomAnchor.constraint(equalTo: bottomAnchor),
            feedback.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
}
