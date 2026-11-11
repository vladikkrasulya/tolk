// «Сформулировать»: the user's points (their language, rough notes or an instruction) -> a ready message in the
// recipient's language + a small honest back-translation to check that exactly that was said.
// Left card: partner's message (optional) · «Что нужно сказать» · tone, recipient language, button.
// Right card: the message · back-translation (small) · warnings · «Копировать».
import AppKit
import TolkCore

@MainActor
final class ComposePanel: NSView, NSTextViewDelegate {
    private let engine: TranslationEngine
    private let messageView = PlaceholderTextView()
    private let pointsView = PlaceholderTextView()
    private let resultView = PlaceholderTextView()
    private let backView = NSTextView()
    private let toneControl = NSSegmentedControl(labels: ComposeTone.allCases.map(\.russianTitle), trackingMode: .selectOne, target: nil, action: nil)
    private let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let runButton = NSButton(title: "Сформулировать", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let copyButton = NSButton(title: "Копировать", target: nil, action: nil)
    private let warningLabel = UIFactory.label("", size: 11.5, color: .systemOrange)
    private let backTitle = UIFactory.label("Обратный перевод — что сказано на самом деле", size: 11, weight: .semibold, color: .tertiaryLabelColor)
    private let langNote = UIFactory.label("", size: 11, color: .tertiaryLabelColor)
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var result: ComposeResult?

    var isBusy: Bool { task != nil }
    var tone: ComposeTone { ComposeTone.allCases[max(0, toneControl.selectedSegment)] }
    private var points: String { pointsView.string.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var message: String { messageView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(engine: TranslationEngine) {
        self.engine = engine
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private static func pane(_ tv: NSTextView, size: CGFloat, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
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
        tv.font = .systemFont(ofSize: size)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = tv
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func box(tinted: Bool) -> NSBox {
        let b = NSBox()
        b.boxType = .custom
        b.cornerRadius = 12
        b.borderWidth = 1
        b.borderColor = .separatorColor
        b.fillColor = tinted
            ? NSColor(name: nil) { appearance in
                var result = NSColor.textBackgroundColor
                appearance.performAsCurrentDrawingAppearance {
                    result = (NSColor.textBackgroundColor.blended(withFraction: 0.035, of: .labelColor) ?? .textBackgroundColor)
                        .usingColorSpace(.sRGB) ?? .textBackgroundColor
                }
                return result
            }
            : .textBackgroundColor
        b.contentViewMargins = .zero
        b.titlePosition = .noTitle
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func line() -> NSBox {
        let l = NSBox()
        l.boxType = .separator
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func build() {
        let left = box(tinted: false), right = box(tinted: true)
        addSubview(left); addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor), left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor), right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 12),
            right.widthAnchor.constraint(equalTo: left.widthAnchor),
        ])
        guard let lc = left.contentView, let rc = right.contentView else { return }

        // Left card
        let msgTitle = UIFactory.label("Сообщение собеседника (необязательно)", size: 11.5, weight: .semibold, color: .secondaryLabelColor)
        let ptsTitle = UIFactory.label("Что нужно сказать", size: 11.5, weight: .semibold, color: .secondaryLabelColor)
        for t in [msgTitle, ptsTitle] { t.translatesAutoresizingMaskIntoConstraints = false }
        messageView.placeholder = "Вставьте, если отвечаете: язык и «Вы/ты» возьмутся отсюда"
        messageView.placeholderFont = .systemFont(ofSize: 14)
        messageView.setAccessibilityLabel("Сообщение собеседника")
        pointsView.placeholder = "Тезисы или указание своими словами, например: «пусть отключит весь трафик, попробуем ещё раз с утра, без агрессии, но прямо»"
        pointsView.placeholderFont = .systemFont(ofSize: 15)
        pointsView.setAccessibilityLabel("Что нужно сказать")
        messageView.delegate = self
        pointsView.delegate = self
        let msgScroll = Self.pane(messageView, size: 14, editable: true)
        let ptsScroll = Self.pane(pointsView, size: 15, editable: true)

        toneControl.controlSize = .small
        toneControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        toneControl.selectedSegment = 0
        toneControl.toolTip = "Тон сообщения"
        toneControl.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        let cfg = TolkConfig.load()
        langPopup.addItems(withTitles: Language.allCases.map { "\($0.flag)  " + UIText.capitalized($0) })
        langPopup.controlSize = .small
        langPopup.font = .systemFont(ofSize: 12)
        select(language: cfg.secondaryLanguage)
        langPopup.toolTip = "Язык получателя. Если вставлено сообщение собеседника — берётся его язык"
        langPopup.setContentCompressionResistancePriority(.init(600), for: .horizontal)
        runButton.bezelStyle = .push
        runButton.controlSize = .regular
        runButton.keyEquivalent = ""
        runButton.target = self; runButton.action = #selector(runClicked)
        runButton.toolTip = "Сформулировать сообщение (⌘↩)"
        runButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let row1 = NSStackView(views: [toneControl, UIFactory.spacer()])
        let row2 = NSStackView(views: [langPopup, UIFactory.spacer(), spinner, runButton])
        for r in [row1, row2] { r.orientation = .horizontal; r.spacing = 8; r.setClippingResistancePriority(.init(1), for: .horizontal) }
        let controls = NSStackView(views: [row1, row2])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        row1.translatesAutoresizingMaskIntoConstraints = false
        row2.translatesAutoresizingMaskIntoConstraints = false
        row1.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        row2.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        // Narrow window: the controls stay inside the card — the tone switch squeezes its segments, the language popup shrinks.
        toneControl.segmentDistribution = .fillProportionally
        toneControl.widthAnchor.constraint(lessThanOrEqualTo: controls.widthAnchor).isActive = true
        row2.setClippingResistancePriority(.init(490), for: .horizontal)
        langPopup.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        langPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        controls.translatesAutoresizingMaskIntoConstraints = false
        let l1 = line(), l2 = line()
        for v in [msgTitle, msgScroll, l1, ptsTitle, ptsScroll, l2, controls] { lc.addSubview(v) }
        NSLayoutConstraint.activate([
            msgTitle.topAnchor.constraint(equalTo: lc.topAnchor, constant: 9),
            msgTitle.leadingAnchor.constraint(equalTo: lc.leadingAnchor, constant: 14),
            msgScroll.topAnchor.constraint(equalTo: msgTitle.bottomAnchor, constant: 2),
            msgScroll.leadingAnchor.constraint(equalTo: lc.leadingAnchor, constant: 1),
            msgScroll.trailingAnchor.constraint(equalTo: lc.trailingAnchor, constant: -1),
            msgScroll.heightAnchor.constraint(equalTo: lc.heightAnchor, multiplier: 0.26),
            l1.topAnchor.constraint(equalTo: msgScroll.bottomAnchor),
            l1.leadingAnchor.constraint(equalTo: lc.leadingAnchor, constant: 12),
            l1.trailingAnchor.constraint(equalTo: lc.trailingAnchor, constant: -12),
            ptsTitle.topAnchor.constraint(equalTo: l1.bottomAnchor, constant: 8),
            ptsTitle.leadingAnchor.constraint(equalTo: msgTitle.leadingAnchor),
            ptsScroll.topAnchor.constraint(equalTo: ptsTitle.bottomAnchor, constant: 2),
            ptsScroll.leadingAnchor.constraint(equalTo: lc.leadingAnchor, constant: 1),
            ptsScroll.trailingAnchor.constraint(equalTo: lc.trailingAnchor, constant: -1),
            l2.topAnchor.constraint(equalTo: ptsScroll.bottomAnchor),
            l2.leadingAnchor.constraint(equalTo: lc.leadingAnchor, constant: 12),
            l2.trailingAnchor.constraint(equalTo: lc.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: l2.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: lc.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: lc.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: lc.bottomAnchor, constant: -9),
        ])

        // Right card
        let resTitle = UIFactory.label("Готовое сообщение", size: 11.5, weight: .semibold, color: .secondaryLabelColor)
        resTitle.translatesAutoresizingMaskIntoConstraints = false
        langNote.translatesAutoresizingMaskIntoConstraints = false
        resultView.placeholder = "Здесь появится сообщение на языке получателя"
        resultView.placeholderFont = .systemFont(ofSize: 15)
        resultView.setAccessibilityLabel("Готовое сообщение")
        let resScroll = Self.pane(resultView, size: 15, editable: false)
        backTitle.translatesAutoresizingMaskIntoConstraints = false
        backTitle.isHidden = true
        let backScroll = Self.pane(backView, size: 12, editable: false)
        backView.textColor = .secondaryLabelColor
        backView.textContainerInset = NSSize(width: 12, height: 4)
        backScroll.isHidden = true
        warningLabel.lineBreakMode = .byTruncatingTail
        warningLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        copyButton.bezelStyle = .push
        copyButton.controlSize = .regular
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.isEnabled = false
        copyButton.target = self; copyButton.action = #selector(copyClicked)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bottom = NSStackView(views: [warningLabel, UIFactory.spacer(), copyButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        bottom.setClippingResistancePriority(.init(1), for: .horizontal)
        bottom.translatesAutoresizingMaskIntoConstraints = false
        let l3 = line(), l4 = line()
        for v in [resTitle, langNote, resScroll, l3, backTitle, backScroll, l4, bottom] { rc.addSubview(v) }
        let backHeight = backScroll.heightAnchor.constraint(equalTo: rc.heightAnchor, multiplier: 0.28)
        NSLayoutConstraint.activate([
            resTitle.topAnchor.constraint(equalTo: rc.topAnchor, constant: 9),
            resTitle.leadingAnchor.constraint(equalTo: rc.leadingAnchor, constant: 14),
            langNote.centerYAnchor.constraint(equalTo: resTitle.centerYAnchor),
            langNote.trailingAnchor.constraint(equalTo: rc.trailingAnchor, constant: -14),
            resScroll.topAnchor.constraint(equalTo: resTitle.bottomAnchor, constant: 2),
            resScroll.leadingAnchor.constraint(equalTo: rc.leadingAnchor, constant: 1),
            resScroll.trailingAnchor.constraint(equalTo: rc.trailingAnchor, constant: -1),
            l3.topAnchor.constraint(equalTo: resScroll.bottomAnchor),
            l3.leadingAnchor.constraint(equalTo: rc.leadingAnchor, constant: 12),
            l3.trailingAnchor.constraint(equalTo: rc.trailingAnchor, constant: -12),
            backTitle.topAnchor.constraint(equalTo: l3.bottomAnchor, constant: 6),
            backTitle.leadingAnchor.constraint(equalTo: rc.leadingAnchor, constant: 14),
            backScroll.topAnchor.constraint(equalTo: backTitle.bottomAnchor, constant: 0),
            backScroll.leadingAnchor.constraint(equalTo: rc.leadingAnchor, constant: 1),
            backScroll.trailingAnchor.constraint(equalTo: rc.trailingAnchor, constant: -1),
            backHeight,
            l4.topAnchor.constraint(equalTo: backScroll.bottomAnchor),
            l4.leadingAnchor.constraint(equalTo: rc.leadingAnchor, constant: 12),
            l4.trailingAnchor.constraint(equalTo: rc.trailingAnchor, constant: -12),
            bottom.topAnchor.constraint(equalTo: l4.bottomAnchor, constant: 8),
            bottom.leadingAnchor.constraint(equalTo: rc.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: rc.trailingAnchor, constant: -10),
            bottom.bottomAnchor.constraint(equalTo: rc.bottomAnchor, constant: -9),
        ])
        // Until there is a result the back-translation block is collapsed to nothing.
        backHeightConstraint = backHeight
        backHeight.isActive = false
        collapsedBack = backScroll.heightAnchor.constraint(equalToConstant: 0)
        collapsedBack.isActive = true
        backScrollView = backScroll
        update()
    }
    private var backHeightConstraint: NSLayoutConstraint!
    private var collapsedBack: NSLayoutConstraint!
    private var backScrollView: NSScrollView!

    // MARK: State

    private func select(language: Language) {
        if let i = Language.allCases.firstIndex(of: language) { langPopup.selectItem(at: i) }
    }

    private var recipient: Language { Language.allCases[max(0, langPopup.indexOfSelectedItem)] }

    func textDidChange(_ notification: Notification) { update() }

    private func update() {
        let msg = message
        if msg.isEmpty {
            langPopup.isEnabled = !isBusy
            langNote.stringValue = ""
        } else {
            let l = LanguageDetector.detect(msg)
            select(language: l)
            langPopup.isEnabled = false
            langNote.stringValue = "язык собеседника"
        }
        runButton.isEnabled = !points.isEmpty && !isBusy
    }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil
        spinner.stopAnimation(nil)
        update()
    }

    func focus() { window?.makeFirstResponder(pointsView) }

    // MARK: Run

    @objc private func runClicked() { run() }

    func run() {
        guard !points.isEmpty, task == nil else { return }
        generation += 1
        let gen = generation
        let p = points, t = tone, to = recipient, m: String? = message.isEmpty ? nil : message
        spinner.startAnimation(nil)
        runButton.isEnabled = false
        langPopup.isEnabled = false
        warningLabel.stringValue = ""
        copyButton.isEnabled = false
        resultView.placeholder = "Формулирую…"
        resultView.string = ""
        showBack(nil)
        let eng = engine
        task = Task { @MainActor [weak self] in
            let r: Result<ComposeResult, Error>
            do { r = .success(try await eng.compose(points: p, tone: t, to: to, partnerMessage: m)) } catch { r = .failure(error) }
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            self.task = nil
            self.spinner.stopAnimation(nil)
            self.finish(r)
            // The text is already on screen: the honest back-translation follows in the background.
            if case let .success(c) = r, c.backTranslation == nil {
                let back = await eng.composeBackTranslation(of: c, userLanguage: TolkConfig.load().primaryLanguage)
                guard self.generation == gen, self.result?.text == c.text else { return }
                self.showBack(back)
            }
        }
    }

    private func finish(_ r: Result<ComposeResult, Error>) {
        resultView.placeholder = "Здесь появится сообщение на языке получателя"
        switch r {
        case let .failure(e):
            result = nil
            warningLabel.textColor = .systemRed
            warningLabel.stringValue = UIText.errorMessage(e)
            warningLabel.toolTip = warningLabel.stringValue
        case let .success(c):
            result = c
            resultView.string = c.text
            copyButton.isEnabled = true
            showBack(c.backTranslation)
            if c.warnings.isEmpty {
                warningLabel.stringValue = ""
            } else {
                warningLabel.textColor = .systemOrange
                warningLabel.stringValue = "⚠ " + c.warnings.joined(separator: "; ")
                warningLabel.toolTip = "Проверьте сообщение перед отправкой: " + c.warnings.joined(separator: "; ")
            }
        }
        update()
    }

    private func showBack(_ text: String?) {
        let has = text?.isEmpty == false
        backTitle.isHidden = !has
        backScrollView.isHidden = !has
        backView.string = text ?? ""
        collapsedBack.isActive = !has
        backHeightConstraint.isActive = has
        needsLayout = true
    }

    @objc private func copyClicked() {
        guard let r = result else { return }
        Clipboard.copy(r.text)
    }

    // MARK: Debug (offline render)

    func debugFill(points: String, message: String = "", tone: ComposeTone = .neutral) {
        pointsView.string = points
        messageView.string = message
        toneControl.selectedSegment = ComposeTone.allCases.firstIndex(of: tone) ?? 0
        update()
    }
    var debugIdle: Bool { task == nil }
}
