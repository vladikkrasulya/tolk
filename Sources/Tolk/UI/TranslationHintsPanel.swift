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

    func setTitle(_ t: String) { titleLabel.stringValue = t }

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
    /// «Взять» in «Варианты перевода»: replace the whole translation with this text (`label` names the variant).
    var onTakeVariant: ((_ text: String, _ label: String) -> Void)?
    /// Tone of the page and the partner's message (reply mode) for the variants request.
    var toneProvider: (() -> Tone)?
    var replyContext: (() -> String?)?
    /// Asked before every button-started request: the server has two slots, the page counts them all.
    var canStartRequest: (() -> Bool)?
    /// The text «Что он имел в виду» is about (the original; in reply mode the partner's message). nil/empty = no button.
    var explainSource: (() -> String?)?
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
    private let variantsJob = HintTask()
    private let explainJob = HintTask()
    private let tvJob = HintTask()
    private var tvGeneration = 0
    private var tvKeep = false
    private var tvSource = ""
    private var tvBase = ""
    private var tvList: [TranslationVariant] = []
    private var tvDone = false
    private var explainedText: String?
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
    private let backLegend = UIFactory.flexibleLabel("", size: 10.5, color: .tertiaryLabelColor, selectable: false)
    private let notesBody = NSStackView()
    private let altBody = NSStackView()
    private let editBefore = UIFactory.flexibleLabel("", size: 12.5, color: .secondaryLabelColor)
    private let editAfter = UIFactory.flexibleLabel("", size: 12.5, color: .labelColor)
    private let variantsBody = NSStackView()
    private let explainBody = NSStackView()
    private let tvBody = NSStackView()
    private let tvResults = NSStackView()
    private let tvButton = NSButton(title: "Подобрать варианты", target: nil, action: nil)
    private let tvSpinner = NSProgressIndicator()
    private var tvCard: HintCard!
    private let explainButton = NSButton(title: "Что он имел в виду", target: nil, action: nil)
    private let explainSpinner = NSProgressIndicator()
    private let glossary = GlossaryFormView(stacked: true, showsTitle: false)

    private var warnCard: HintCard!
    private var backCard: HintCard!
    private var notesCard: HintCard!
    private var altCard: HintCard!
    private var editCard: HintCard!
    private var scrollTopPlain: NSLayoutConstraint!
    private var scrollTopExplain: NSLayoutConstraint!
    private var variantsCancel: NSButton!
    private var explainRow: NSStackView!
    private var variantsCard: HintCard!
    private var explainCard: HintCard!
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
        clearNotes(); clearAlternatives(); clearVariants()
        if !tvKeep { clearTV() }
        // The explanation belongs to the text it was made for: it stays while that text stays (reply mode: typing the answer).
        if explainedText != nil, explainedText != currentExplainText() { clearExplanation() }
        refreshAll()
    }

    /// Requests running now that count against the server's two slots.
    var busyCount: Int { [back.isRunning, notesJob.isRunning, altJob.isRunning, variantsJob.isRunning, explainJob.isRunning, tvJob.isRunning].filter { $0 }.count }

    /// A button request needs the slot: the automatic hints (back-translation, footnotes) give way.
    func cancelBackground() {
        back.cancel(); notesJob.cancel(); altJob.cancel(); altWork?.cancel(); pendingNotes = false
        refreshAll()
    }

    private func currentExplainText() -> String? {
        let t = explainSource?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
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
        // The variants stay while the translation on screen is the one they were made for or one of them (after «Взять» / «Вернуть»).
        tvKeep = !tvList.isEmpty && tvSource == source && (translation == tvBase || tvList.contains { $0.text == translation })
        let keepTV = tvKeep
        suspend()
        tvKeep = false
        ctx = Context(source: source, translation: translation, from: from, to: to, provider: provider)
        if keepTV, tvDone { showTV(nil) }
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
        clearAlternatives(); clearVariants()
        if !tvList.isEmpty { showTV(nil) }
        refreshAll()
    }

    /// Editor / rewrite result for the before/after card (nil, nil = hide). `title`: «Правка · Короче».
    func setEditorChange(before: String?, after: String?, title: String = "Правка") {
        if let before, let after {
            editCard.setTitle(title)
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

    /// The text behind «Что он имел в виду» changed (or appeared): refresh the button.
    func refresh() { refreshAll() }

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
                let diff = BackDiff.compare(source: c.source, back: text, glossary: engine.glossaryHits(in: c.source, target: c.to))
                backText.attributedStringValue = Self.highlight(text, diff: diff)
                backLegend.stringValue = Self.legend(diff)
                backLegend.isHidden = diff.isClean
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

    // MARK: - Sentence variants

    /// Click on a sentence of the translation: 2–3 other renderings (one request, on demand). `range` = the sentence in the
    /// translation; a chosen variant goes through `onReplace(range, text)`.
    func requestVariants(sentence: String, current: String, range: NSRange, tone: Tone) {
        guard let c = ctx else { return }
        if UIText.isFallbackProvider(c.provider) {
            flash(ServerText.homeOnly("Варианты предложений"), color: .systemOrange)
            return
        }
        variantsJob.cancel()
        guard canStartRequest?() ?? true else {
            flash("Сервер занят двумя запросами — подождите или отмените один.", color: .systemOrange)
            return
        }
        showVariants(current: current, range: range, result: nil)
        let engine = self.engine, fullSource = c.source, fullTranslation = c.translation, from = c.from, to = c.to
        variantsJob.run({ () async -> Result<[SentenceVariant], Error> in
            do {
                return .success(try await engine.sentenceVariants(sentence: sentence, current: current, fullSource: fullSource,
                                                                  fullTranslation: fullTranslation, from: from, to: to, tone: tone))
            } catch { return .failure(error) }
        }) { [weak self] result in
            self?.showVariants(current: current, range: range, result: result)
        }
    }

    private func showVariants(current: String, range: NSRange, result: Result<[SentenceVariant], Error>?) {
        variantsBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let now = UIFactory.flexibleLabel("Сейчас: «\(current)»", size: 11.5, color: .secondaryLabelColor, selectable: false)
        now.maximumNumberOfLines = 3
        now.cell?.truncatesLastVisibleLine = true
        addFull(now, to: variantsBody)
        variantsCancel.isHidden = result != nil
        switch result {
        case nil:
            addFull(UIFactory.label("подбираю варианты…", size: 12, color: .tertiaryLabelColor), to: variantsBody)
            variantsCard.setCount(nil)
        case let .failure(error)?:
            addFull(UIFactory.flexibleLabel(UIText.errorMessage(error), size: 12, color: .systemRed, selectable: false), to: variantsBody)
            variantsCard.setCount(nil)
        case let .success(list)?:
            if list.isEmpty { addFull(UIFactory.label("других вариантов нет", size: 12, color: .tertiaryLabelColor), to: variantsBody) }
            for v in list {
                let row = VariantRowView(label: v.label, text: v.text)
                row.onClick = { [weak self] in
                    self?.onReplace?(range, v.text)
                    self?.flash("Предложение заменено", color: .systemGreen)
                }
                addFull(row, to: variantsBody)
            }
            variantsCard.setCount(list.isEmpty ? nil : list.count)
        }
        variantsCard.isHidden = false
        refreshEmpty()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.variantsCard.isHidden else { return }
                self.variantsCard.superview?.layoutSubtreeIfNeeded()
                self.variantsCard.scrollToVisible(self.variantsCard.bounds)
            }
        }
    }

    // MARK: - «Варианты перевода»

    /// Button (and the popup's «Варианты»): 2–3 alternatives of the whole translation, one request. A second press cancels.
    @objc func suggestTranslationVariants() {
        if tvJob.isRunning { tvGeneration += 1; tvJob.cancel(); showTV(nil); refreshAll(); return }
        guard let c = ctx else { NSSound.beep(); return }
        if UIText.isFallbackProvider(c.provider) {
            flash(ServerText.homeOnly("Варианты перевода"), color: .systemOrange)
            return
        }
        guard canStartRequest?() ?? true else {
            flash("Сервер занят двумя запросами — подождите или отмените один.", color: .systemOrange)
            return
        }
        tvGeneration += 1
        let gen = tvGeneration
        tvSource = c.source; tvBase = c.translation; tvList = []; tvDone = false
        showTV(nil, loading: true)
        let engine = self.engine, source = c.source, translation = c.translation, from = c.from, to = c.to
        let tone = toneProvider?() ?? .auto, reply = replyContext?()
        tvJob.run({ () async -> Result<[TranslationVariant], Error> in
            do {
                return .success(try await engine.translationVariants(source: source, translation: translation, from: from, to: to,
                                                                     tone: tone, replyTo: reply))
            } catch { return .failure(error) }
        }) { [weak self] result in
            guard let self, self.tvGeneration == gen else { return }
            self.tvDone = true
            switch result {
            case let .success(list): self.tvList = list; self.showTV(nil)
            case let .failure(e): self.showTV(UIText.errorMessage(e))
            }
            self.refreshAll()
        }
        refreshAll()
    }

    private func showTV(_ error: String?, loading: Bool = false) {
        tvResults.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if loading {
            addFull(UIFactory.label("подбираю варианты…", size: 12, color: .tertiaryLabelColor), to: tvResults)
            tvCard.setCount(nil)
            return
        }
        if let error {
            addFull(UIFactory.flexibleLabel(error, size: 12, color: .systemRed, selectable: false), to: tvResults)
            tvCard.setCount(nil)
            return
        }
        let current = ctx?.translation ?? tvBase
        for v in tvList {
            let row = TranslationVariantRow(variant: v, base: tvBase, taken: v.text == current)
            row.onTake = { [weak self] in self?.take(v) }
            addFull(row, to: tvResults)
        }
        if tvDone, tvList.isEmpty {
            addFull(UIFactory.flexibleLabel("Достойных вариантов не нашлось: модель предложила только то, что меняет смысл или похоже на текущий перевод.",
                                            size: 12, color: .tertiaryLabelColor, selectable: false), to: tvResults)
        }
        tvCard.setCount(tvList.isEmpty ? nil : tvList.count)
        if tvDone {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.tvCard.isHidden else { return }
                    self.tvCard.superview?.layoutSubtreeIfNeeded()
                    // The card is taller than the panel: bring its TOP (button, first variant) into view.
                    guard let scroll = self.tvCard.enclosingScrollView, let doc = scroll.documentView else { return }
                    let top = self.tvCard.convert(self.tvCard.bounds, to: doc).minY
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, top - 4)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }

    private func take(_ v: TranslationVariant) {
        onTakeVariant?(v.text, v.label)
        flash("Перевод заменён на «\(v.label)»", color: .systemGreen)
        showTV(nil)
    }

    #if DEBUG
    func debugTakeVariant(_ i: Int) { if tvList.indices.contains(i) { take(tvList[i]) } }
    var debugVariantsRunning: Bool { tvJob.isRunning }
    #endif

    private func clearTV() {
        tvGeneration += 1
        tvJob.cancel()
        tvList = []; tvDone = false; tvSource = ""; tvBase = ""
        tvResults.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tvCard?.setCount(nil)
    }

    private func clearVariants() {
        variantsJob.cancel()
        variantsBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        variantsCard.isHidden = true
    }

    @objc private func cancelVariants() { clearVariants(); refreshEmpty() }

    // MARK: - «Что он имел в виду»

    @objc func explainClicked() {
        if explainJob.isRunning { clearExplanation(); refreshAll(); return }
        guard let text = currentExplainText() else { NSSound.beep(); return }
        if let c = ctx, UIText.isFallbackProvider(c.provider) {
            flash(ServerText.homeOnly("Разбор смысла"), color: .systemOrange)
            return
        }
        guard canStartRequest?() ?? true else {
            flash("Сервер занят двумя запросами — подождите или отмените один.", color: .systemOrange)
            return
        }
        explainedText = text
        showExplanation(nil, error: nil)
        let engine = self.engine
        explainJob.run({ () async -> Result<MessageExplanation, Error> in
            do { return .success(try await engine.explain(message: text)) } catch { return .failure(error) }
        }) { [weak self] result in
            guard let self, self.explainedText == text else { return }
            switch result {
            case let .success(e): self.showExplanation(e, error: nil)
            case let .failure(e): self.showExplanation(nil, error: UIText.errorMessage(e))
            }
        }
    }

    private func showExplanation(_ e: MessageExplanation?, error: String?) {
        explainBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        explainCard.setCount(nil)
        if let e {
            let badge = UIFactory.badge()
            badge.text = e.tone
            badge.tint = UIText.toneColor(e.tone)
            let toneRow = NSStackView(views: [UIFactory.label("Тон", size: 11, weight: .semibold, color: .tertiaryLabelColor), badge, UIFactory.spacer()])
            toneRow.orientation = .horizontal
            toneRow.spacing = 6
            addFull(toneRow, to: explainBody)
            addFull(UIFactory.flexibleLabel(e.meaning, size: 12.5, color: .labelColor), to: explainBody)
            if !e.terms.isEmpty {
                addFull(UIFactory.label("Термины", size: 11, weight: .semibold, color: .tertiaryLabelColor), to: explainBody)
                for t in e.terms {
                    let text = NSMutableAttributedString(string: t.term, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
                    text.append(NSAttributedString(string: " — " + t.meaning, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
                    let l = WrapLabel(wrappingLabelWithString: "")
                    l.attributedStringValue = text
                    l.isSelectable = true
                    l.maximumNumberOfLines = 0
                    l.setContentCompressionResistancePriority(.init(250), for: .horizontal)
                    addFull(l, to: explainBody)
                }
                explainCard.setCount(e.terms.count)
            }
        } else if let error {
            addFull(UIFactory.flexibleLabel(error, size: 12, color: .systemRed, selectable: false), to: explainBody)
        } else {
            addFull(UIFactory.label("разбираю смысл…", size: 12, color: .tertiaryLabelColor), to: explainBody)
        }
        explainCard.isHidden = false
        refreshAll()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.explainCard.isHidden else { return }
                self.explainCard.superview?.layoutSubtreeIfNeeded()
                self.explainCard.scrollToVisible(self.explainCard.bounds)
            }
        }
    }

    private func clearExplanation() {
        explainJob.cancel()
        explainedText = nil
        explainBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        explainCard.isHidden = true
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
        // Times with a zone in the text → the reader's local time (informational, not counted as a warning).
        let times = ctx.map { TimezoneLine.lines(in: $0.source) } ?? []
        for t in times {
            let icon = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 10.5, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = UIFactory.flexibleLabel(t, size: 12.5, color: .labelColor)
            let row = NSStackView(views: [icon, label])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            addFull(row, to: warnBody)
        }
        warnCard.isHidden = warnings.isEmpty && times.isEmpty
        warnCard.setCount(warnings.isEmpty ? nil : warnings.count)
        // back-translation
        backCard.isHidden = !(HintsSettings.backEnabled && ctx != nil && backShown)
        backRefresh.isHidden = !(ctx?.stale ?? false)
        glossaryCard.isHidden = ctx == nil
        let canExplain = currentExplainText() != nil
        explainButton.isHidden = !canExplain
        explainButton.title = explainJob.isRunning ? "Отмена" : "Что он имел в виду"
        explainButton.image = NSImage(systemSymbolName: explainJob.isRunning ? "xmark" : "questionmark.bubble", accessibilityDescription: nil)
        if explainJob.isRunning { explainSpinner.startAnimation(nil) } else { explainSpinner.stopAnimation(nil) }
        explainRow.isHidden = !canExplain
        tvCard.isHidden = ctx == nil
        tvButton.title = tvJob.isRunning ? "Отмена" : (tvDone ? "Подобрать заново" : "Подобрать варианты")
        tvButton.image = NSImage(systemSymbolName: tvJob.isRunning ? "xmark" : "list.bullet.rectangle", accessibilityDescription: nil)
        if tvJob.isRunning { tvSpinner.startAnimation(nil) } else { tvSpinner.stopAnimation(nil) }
        scrollTopPlain.isActive = !canExplain
        scrollTopExplain.isActive = canExplain
        if let c = ctx, c.stale, backShown { backCaption.stringValue = "Перевод изменён — обратный перевод устарел" }
        refreshEmpty()
    }

    private func refreshEmpty() {
        // (the «Варианты перевода» card is always there with a translation: it does not count as a hint)
        let visible = [explainCard, warnCard, variantsCard, backCard, notesCard, altCard, editCard].contains { $0?.isHidden == false }
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
            emptyLabel.stringValue = "Спорных мест не найдено. Щёлкните по предложению в переводе — предложу варианты, выделите слово — подберу замену."
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

    /// Back-translated text with only the differences in MEANING marked (numbers, negations, names, glossary terms);
    /// synonyms are not highlighted.
    static func highlight(_ back: String, diff: BackDiff.Result) -> NSAttributedString {
        let out = NSMutableAttributedString(string: back, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
        for r in diff.marks where NSMaxRange(r) <= out.length {
            out.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.28), range: r)
        }
        return out
    }

    static func legend(_ diff: BackDiff.Result) -> String {
        var parts: [String] = []
        if !diff.marks.isEmpty { parts.append("Подсвечено то, чего нет в оригинале: число, имя или отрицание.") }
        if !diff.missing.isEmpty { parts.append("Не дошло до обратного перевода: " + diff.missing.map { "«\($0)»" }.joined(separator: ", ") + ".") }
        return parts.joined(separator: " ")
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

        explainButton.target = self
        explainButton.action = #selector(explainClicked)
        explainButton.bezelStyle = .push
        explainButton.controlSize = .small
        explainButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explainButton.imagePosition = .imageLeading
        explainButton.toolTip = "Смысл сообщения, тон и пояснения терминов — один запрос к модели"
        explainSpinner.style = .spinning
        explainSpinner.controlSize = .small
        explainSpinner.isDisplayedWhenStopped = false
        explainRow = NSStackView(views: [explainButton, explainSpinner, UIFactory.spacer()])
        explainRow.orientation = .horizontal
        explainRow.spacing = 6
        explainRow.translatesAutoresizingMaskIntoConstraints = false
        explainRow.isHidden = true

        tvButton.target = self
        tvButton.action = #selector(suggestTranslationVariants)
        tvButton.bezelStyle = .push
        tvButton.controlSize = .small
        tvButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tvButton.imagePosition = .imageLeading
        tvButton.toolTip = "2–3 варианта всего перевода с пояснением, чем они отличаются — один запрос к модели"
        tvSpinner.style = .spinning
        tvSpinner.controlSize = .small
        tvSpinner.isDisplayedWhenStopped = false
        let tvRow = NSStackView(views: [tvButton, tvSpinner, UIFactory.spacer()])
        tvRow.orientation = .horizontal
        tvRow.spacing = 6

        // Card bodies
        for s in [warnBody, notesBody, altBody, variantsBody, explainBody, tvBody, tvResults] {
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
        backLegend.widthAnchor.constraint(equalTo: backBody.widthAnchor).isActive = true
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
        editCard = HintCard(id: "editor", title: "Правка", symbol: "wand.and.stars", body: editBody)
        variantsCard = HintCard(id: "variants", title: "Варианты предложения", symbol: "text.quote", body: variantsBody)
        tvBody.setViews([tvRow, tvResults], in: .leading)
        tvBody.orientation = .vertical
        tvBody.alignment = .leading
        tvBody.spacing = 8
        tvResults.widthAnchor.constraint(equalTo: tvBody.widthAnchor).isActive = true
        tvCard = HintCard(id: "tvariants", title: "Варианты перевода", symbol: "list.bullet.rectangle", body: tvBody)
        explainCard = HintCard(id: "explain", title: "Что он имел в виду", symbol: "questionmark.bubble", body: explainBody, tint: .systemBlue)
        variantsCancel = UIFactory.symbolButton("xmark.circle", tooltip: "Отменить запрос", target: self, action: #selector(cancelVariants))
        variantsCard.accessory.addArrangedSubview(variantsCancel)
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
        let cards = [explainCard!, warnCard!, variantsCard!, tvCard!, notesCard!, backCard!, altCard!, editCard!, glossaryCard!]
        for v in [emptyLabel] + cards { stack.addArrangedSubview(v) }
        for v in [emptyLabel] + cards { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: v === emptyLabel ? -8 : 0).isActive = true }
        emptyLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        for c in [explainCard!, warnCard!, variantsCard!, tvCard!, notesCard!, backCard!, altCard!, editCard!] { c.isHidden = true }

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
        for v in [header, explainRow!, scroll, feedback] { addSubview(v) }
        scrollTopPlain = scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10)
        scrollTopExplain = scroll.topAnchor.constraint(equalTo: explainRow.bottomAnchor, constant: 8)
        scrollTopExplain.isActive = false
        scrollTopPlain.isActive = true
        NSLayoutConstraint.activate([
            scrollBottom,
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            header.heightAnchor.constraint(equalToConstant: 28),
            explainRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            explainRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            explainRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            feedback.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            feedback.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            feedback.bottomAnchor.constraint(equalTo: bottomAnchor),
            feedback.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
}
