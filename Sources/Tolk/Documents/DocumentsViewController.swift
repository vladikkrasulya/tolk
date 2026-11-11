// «Документы» page: open a whole document (PDF, Word, RTF, ODT, HTML, TXT, MD),
// translate it paragraph by paragraph with pause / resume, export to Word / RTF / TXT / Markdown.
import AppKit
import TolkCore
import UniformTypeIdentifiers

// MARK: - Small views

/// Root view: accepts dropped document files.
private final class DocsPageView: NSView {
    weak var controller: DocumentsViewController?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard controller?.droppedURL(sender.draggingPasteboard) != nil else { return [] }
        controller?.setDropTargeted(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.droppedURL(sender.draggingPasteboard) != nil ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.setDropTargeted(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.setDropTargeted(false)
        guard let url = controller?.droppedURL(sender.draggingPasteboard) else { return false }
        controller?.open(url: url)
        return true
    }
}

/// Scroll view that reports user scrolling (wheel / trackpad / scroller drag), not programmatic scrolls.
/// Draws a rounded hairline frame that follows light / dark mode.
private final class FollowScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.deltaY != 0 || event.scrollingDeltaY != 0 { onUserScroll?() }
        super.scrollWheel(with: event)
    }
}

/// Translucent background that follows light / dark mode (drop cover).
private final class TintedView: NSView {
    var color: NSColor = .windowBackgroundColor.withAlphaComponent(0.85)
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}

/// Row view: a hairline under each paragraph; the paragraph being translated gets a soft accent background.
private final class ParagraphRowView: NSTableRowView {
    var isCurrent = false { didSet { if oldValue != isCurrent { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 12, y: bounds.maxY - 1, width: bounds.width - 24, height: 1).fill()
        guard isCurrent else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// One side of a paragraph row: selectable wrapping text.
private final class ParagraphCellView: NSTableCellView {
    static let insets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
    let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.isSelectable = true
        label.allowsEditingTextAttributes = true // keeps fonts when the text is selected
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        let i = Self.insets
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i.left),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i.right),
            label.topAnchor.constraint(equalTo: topAnchor, constant: i.top),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Controller

@MainActor
final class DocumentsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// The coordinator may swap the engine after settings change (`TolkConfig.didChange`).
    var engine: TranslationEngine {
        didSet {
            let wasRunning = translator.isRunning
            translator.engine = engine
            if wasRunning {
                pause()
                showNotice("Настройки перевода изменились — нажмите «Продолжить».", color: .secondaryLabelColor)
            }
        }
    }

    /// Characters per second assumed for the estimate before the real speed is measured.
    static let assumedSpeed: Double = 350
    /// Seconds per request on top of the speed (connection, prompt, first token) — measured ~1.5–3 s on the home server.
    static let perRequest: Double = 1.5
    static let bigPages = 300
    static let bigChars = 500_000

    private enum RunState { case idle, running, paused }

    private let translator: DocumentTranslator
    private var document: ExtractedDocument?
    private var extractToken = UUID()
    private var extractTask: Task<Void, Never>?
    private var runState = RunState.idle
    private var autoFollow = true
    private var tickTimer: Timer?
    private var saved = true
    private var heightCache: [Int: CGFloat] = [:]
    private var heightWidth: CGFloat = 0
    private var currentRow: Int?

    // Views
    private var emptyView: NSView!
    private var dropZone: DropZoneView!
    private var loadingView: NSView!
    private var loadingLabel: NSTextField!
    private var loadingSpinner: NSProgressIndicator!
    private var contentView: NSView!
    private var dropCover: NSView!
    private var originalHeader: NSTextField!
    private var translationHeader: NSTextField!
    private var fileIcon: NSImageView!
    private var fileLabel: NSTextField!
    private var statsLabel: NSTextField!
    private var targetPopup: NSPopUpButton!
    private var toneControl: NSSegmentedControl!
    private var translateButton: NSButton!
    private var pauseButton: NSButton!
    private var cancelButton: NSButton!
    private var saveButton: NSButton!
    private var noticeLabel: NSTextField!
    private var progressRow: NSStackView!
    private var progressBar: NSProgressIndicator!
    private var progressLabel: NSTextField!
    private var providerBadge: BadgeView!
    private var tableView: NSTableView!
    private var scrollView: FollowScrollView!
    private var followButton: NSButton!

    private static let targetKey = "tolk.docs.target"
    private static let toneKey = "tolk.docs.tone"
    private static let formatKey = "tolk.docs.exportFormat"
    private static let bilingualKey = "tolk.docs.bilingual"

    init(engine: TranslationEngine) {
        self.engine = engine
        translator = DocumentTranslator(engine: engine)
        super.init(nibName: nil, bundle: nil)
        title = "Документы"
        translator.onEvent = { [weak self] in self?.handle($0) }
        #if DEBUG
        DocumentsDemo.runIfRequested(engine: engine)
        #endif
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Main window closed: stop reading and a running translation (it would hold an Ollama slot).
    func cancelWork() {
        extractTask?.cancel()
        if runState == .running { pause() }
    }

    // MARK: - Public API (also used by the demo)

    var isBusy: Bool { extractTask != nil || translator.isRunning }
    var extracted: ExtractedDocument? { document }
    var translationPairs: [DocumentExporter.Pair] {
        translator.paragraphs.indices.compactMap { i in translator.translations[i].map { (translator.paragraphs[i], $0) } }
    }

    func open(url: URL) {
        _ = view
        guard DocumentExtractor.canOpen(url) else {
            showAlert(DocumentError.unsupported(url.lastPathComponent).localizedDescription)
            return
        }
        guard confirmDiscard() else { return }
        extractTask?.cancel()
        translator.load([])
        document = nil
        setRunState(.idle)
        tableView.reloadData()
        show(.loading)
        loadingLabel.stringValue = "Читаю «\(url.lastPathComponent)»…"
        loadingSpinner.startAnimation(nil)
        let label = loadingLabel!
        let token = UUID()
        extractToken = token // an older, cancelled read that finishes late must not touch the state of this one
        extractTask = Task { @MainActor [weak self] in
            do {
                let doc = try await DocumentExtractor.extract(url) { page, total, ocr in
                    Task { @MainActor in
                        guard !label.isHiddenOrHasHiddenAncestor else { return }
                        label.stringValue = ocr
                            ? "Распознаю текст: страница \(page) из \(total)…"
                            : "Читаю страницу \(page) из \(total)…"
                    }
                }
                guard let self, self.extractToken == token else { return }
                self.extractTask = nil
                self.loadingSpinner.stopAnimation(nil)
                if Task.isCancelled { self.show(.empty); return }
                self.loaded(doc)
            } catch {
                guard let self, self.extractToken == token else { return }
                self.extractTask = nil
                self.loadingSpinner.stopAnimation(nil)
                self.show(.empty)
                if error is CancellationError || Task.isCancelled { return }
                self.showAlert(error.localizedDescription)
            }
        }
    }

    /// Starts (or continues) the translation with the chosen language and tone.
    @objc func startTranslation(_ sender: Any? = nil) {
        guard let doc = document, !doc.paragraphs.isEmpty else { return }
        hideNotice()
        if translator.isComplete { translator.reset(); tableView.reloadData(); heightCache = [:]; noteAllHeights() }
        runTranslator()
    }

    /// Starts the translator; a changed language / tone while translations exist starts over with the new ones.
    private func runTranslator() {
        let target = selectedTarget
        let tone = selectedTone
        if translator.hasAnyTranslation, translator.target != target || translator.tone != tone {
            translator.reset()
            heightCache = [:]
            tableView.reloadData()
        }
        autoFollow = true
        saved = false
        setRunState(.running)
        translator.start(target: target, tone: tone)
        updateHeaderTitle()
        updateProgress()
    }

    // MARK: - View

    private enum Mode { case empty, loading, content }

    override func loadView() {
        let root = DocsPageView()
        root.controller = self
        root.registerForDraggedTypes([.fileURL])
        view = root
        buildEmptyView()
        buildLoadingView()
        buildContentView()
        for v in [emptyView!, loadingView!, contentView!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.topAnchor.constraint(equalTo: root.topAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        show(.empty)
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        root.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
    }

    private func show(_ mode: Mode) {
        emptyView.isHidden = mode != .empty
        loadingView.isHidden = mode != .loading
        contentView.isHidden = mode != .content
    }

    private func buildEmptyView() {
        let container = NSView()
        let zone = DropZoneView()
        zone.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(zone)
        dropZone = zone

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 54, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        let title = UIFactory.label("Перетащите документ сюда", size: 22, weight: .semibold, color: .labelColor)
        title.alignment = .center
        let subtitle = UIFactory.wrappingLabel(
            "PDF, Word (DOCX, DOC), RTF, ODT, HTML, TXT или Markdown.\nДокумент переводится по абзацам — можно поставить на паузу и сохранить уже готовое.",
            size: 13, color: .secondaryLabelColor)
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 480

        let open = toolButton("Открыть файл…", symbol: "folder", #selector(openFile(_:)))
        open.controlSize = .large
        open.keyEquivalent = "\r"

        let hint = UIFactory.wrappingLabel("Сканы в PDF распознаются прямо на этом Mac. Перевод сохраняется в Word, RTF, TXT или Markdown.",
                                           size: 12, color: .tertiaryLabelColor)
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 480

        let stack = NSStackView(views: [icon, title, subtitle, open, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: icon)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(16, after: open)
        stack.translatesAutoresizingMaskIntoConstraints = false
        zone.addSubview(stack)

        NSLayoutConstraint.activate([
            zone.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            zone.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            zone.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            zone.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: zone.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: zone.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: zone.leadingAnchor, constant: 20),
        ])
        emptyView = container
    }

    private func buildLoadingView() {
        let container = NSView()
        loadingSpinner = NSProgressIndicator()
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isDisplayedWhenStopped = false
        loadingLabel = UIFactory.label("", size: 14, color: .secondaryLabelColor)
        loadingLabel.alignment = .center
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelLoading(_:)))
        cancel.bezelStyle = .rounded
        let stack = NSStackView(views: [loadingSpinner, loadingLabel, cancel])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            loadingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        loadingView = container
    }

    private func buildContentView() {
        let container = NSView()

        // Row 1: file
        fileIcon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) ?? NSImage())
        fileIcon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        fileIcon.contentTintColor = .controlAccentColor
        fileLabel = UIFactory.label("", size: 15, weight: .semibold, color: .labelColor)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statsLabel = UIFactory.label("", size: 12, color: .secondaryLabelColor)
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titles = NSStackView(views: [fileLabel, statsLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let openOther = toolButton("Открыть…", symbol: "folder", #selector(openFile(_:)), tip: "Открыть другой документ")
        let close = UIFactory.symbolButton("xmark.circle.fill", tooltip: "Закрыть документ", target: self, action: #selector(closeDocument(_:)))
        let fileRow = NSStackView(views: [fileIcon, titles, UIFactory.spacer(), openOther, close])
        fileRow.spacing = 10
        fileRow.alignment = .centerY

        // Row 2: options + actions
        let targetTitle = UIFactory.label("Перевести на", size: 12, color: .secondaryLabelColor)
        targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        targetPopup.controlSize = .regular
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged(_:))
        targetPopup.toolTip = "На какой язык переводить документ"
        let toneTitle = UIFactory.label("Тон", size: 12, color: .secondaryLabelColor)
        toneControl = UIFactory.toneControl(target: self, action: #selector(toneChanged(_:)))
        toneControl.controlSize = .regular
        toneControl.font = .systemFont(ofSize: NSFont.systemFontSize)
        let savedTone = UserDefaults.standard.string(forKey: Self.toneKey).flatMap(Tone.init(rawValue:)) ?? .formal
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: savedTone) ?? 2

        translateButton = toolButton("Перевести", symbol: "play.fill", #selector(primaryAction(_:)))
        translateButton.keyEquivalent = "\r"
        pauseButton = toolButton("Пауза", symbol: "pause.fill", #selector(pauseAction(_:)), tip: "Приостановить перевод; готовые абзацы сохранятся")
        cancelButton = toolButton("Отмена", symbol: "stop.fill", #selector(cancelAction(_:)), tip: "Остановить перевод; готовые абзацы сохранятся")
        saveButton = toolButton("Сохранить как…", symbol: "square.and.arrow.down", #selector(saveAs(_:)),
                                tip: "Сохранить перевод в Word, RTF, TXT или Markdown")
        let optionsRow = NSStackView(views: [targetTitle, targetPopup, toneTitle, toneControl, UIFactory.spacer(),
                                             saveButton, cancelButton, pauseButton, translateButton])
        optionsRow.spacing = 8
        optionsRow.setCustomSpacing(18, after: targetPopup)
        optionsRow.setCustomSpacing(14, after: saveButton)
        // The row must never push the window wider (it used to grow past the screen edge once «Сохранить как…» appeared):
        // the language popup shrinks first, then the two captions drop out.
        optionsRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        optionsRow.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 200), for: targetTitle)
        optionsRow.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 300), for: toneTitle)
        targetPopup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        for b in [saveButton, cancelButton, pauseButton, translateButton] as [NSView] {
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // Notice + progress
        noticeLabel = UIFactory.wrappingLabel("", size: 12, color: .systemOrange)
        noticeLabel.isHidden = true
        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        progressLabel = UIFactory.label("", size: 12, color: .secondaryLabelColor)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)
        providerBadge = UIFactory.badge()
        providerBadge.text = ""
        progressRow = NSStackView(views: [progressBar, progressLabel, providerBadge])
        progressRow.spacing = 10

        // Side-by-side table
        tableView = NSTableView()
        tableView.style = .fullWidth
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.intercellSpacing = NSSize(width: 12, height: 0)
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = .textBackgroundColor
        for (id, title) in [("orig", "Оригинал"), ("trans", "Перевод")] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.minWidth = 160
            col.resizingMask = .autoresizingMask
            col.headerCell.font = .systemFont(ofSize: 12, weight: .semibold)
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate = self

        scrollView = FollowScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = TolkStyle.cardRadius
        scrollView.layer?.borderWidth = 0.5
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollView.updateColors()
        scrollView.onUserScroll = { [weak self] in self?.userScrolled() }
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted(_:)),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)

        followButton = toolButton("К текущему абзацу", symbol: "arrow.down.circle", #selector(followAgain(_:)),
                                  tip: "Снова следить за переводом")
        followButton.isHidden = true
        followButton.translatesAutoresizingMaskIntoConstraints = false

        originalHeader = UIFactory.label("Оригинал", size: 12, weight: .semibold, color: .secondaryLabelColor)
        translationHeader = UIFactory.label("Перевод", size: 12, weight: .semibold, color: .secondaryLabelColor)
        let headerRow = NSStackView(views: [originalHeader, translationHeader])
        headerRow.distribution = .fillEqually
        headerRow.spacing = 12
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        let stack = NSStackView(views: [fileRow, optionsRow, noticeLabel, progressRow, headerRow, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: fileRow)
        stack.setCustomSpacing(12, after: progressRow)
        stack.setCustomSpacing(6, after: headerRow)
        for v in [fileRow, optionsRow, noticeLabel, progressRow, headerRow, scrollView] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        container.addSubview(followButton)

        let cover = TintedView()
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 16
        let coverFrame = DropZoneView()
        coverFrame.isTargeted = true
        coverFrame.frame = cover.bounds
        coverFrame.autoresizingMask = [.width, .height]
        cover.addSubview(coverFrame)
        dropCover = cover
        let coverLabel = UIFactory.label("Отпустите, чтобы открыть документ", size: 17, weight: .semibold, color: .controlAccentColor)
        coverLabel.translatesAutoresizingMaskIntoConstraints = false
        dropCover.addSubview(coverLabel)
        dropCover.isHidden = true
        dropCover.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dropCover)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            followButton.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            followButton.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -14),
            dropCover.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            dropCover.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            dropCover.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            dropCover.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            coverLabel.centerXAnchor.constraint(equalTo: dropCover.centerXAnchor),
            coverLabel.centerYAnchor.constraint(equalTo: dropCover.centerYAnchor),
        ])
        contentView = container

        NotificationCenter.default.addObserver(self, selector: #selector(windowEndedLiveResize(_:)),
                                               name: NSWindow.didEndLiveResizeNotification, object: nil)
    }

    private func toolButton(_ title: String, symbol: String, _ action: Selector, tip: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.toolTip = tip
        return b
    }

    // MARK: - Loading a document

    private func loaded(_ doc: ExtractedDocument) {
        document = doc
        translator.load(doc.paragraphs)
        saved = true
        heightCache = [:]
        currentRow = nil
        fileLabel.stringValue = doc.name
        fileIcon.image = NSImage(systemSymbolName: doc.kind == .pdf ? "doc.richtext" : "doc.text", accessibilityDescription: nil)
        rebuildTargetPopup()
        updateStats()
        hideNotice()
        if doc.approximatePages > Self.bigPages || doc.characterCount > Self.bigChars {
            showNotice("Большой документ (≈ \(Self.number(doc.approximatePages)) стр.): перевод займёт \(Self.duration(estimate(doc))) или дольше. "
                       + "Перевод можно ставить на паузу, а уже готовые абзацы — сохранить в любой момент.")
        } else if doc.ocrPages > 0 {
            showNotice("\(doc.ocrPages == doc.pageCount ? "Все страницы" : "\(doc.ocrPages) \(Self.plural(doc.ocrPages, "страница", "страницы", "страниц"))") "
                       + "без текстового слоя — текст распознан (OCR), возможны неточности.", color: .secondaryLabelColor)
        }
        setRunState(.idle)
        show(.content)
        tableView.reloadData()
        tableView.scrollRowToVisible(0)
        updateHeaderTitle()
        updateProgress()
    }

    /// ~350 characters/s plus a fixed cost per request (each paragraph is one request).
    private func estimate(_ doc: ExtractedDocument) -> TimeInterval {
        let requests = doc.paragraphs.reduce(0) { $0 + ($1.translatable ? 1 : 0) }
        return Double(doc.translatableCharacters) / Self.assumedSpeed + Double(requests) * Self.perRequest
    }

    private func updateStats() {
        guard let doc = document else { statsLabel.stringValue = ""; return }
        var parts: [String] = []
        if let pages = doc.pageCount {
            var s = "\(Self.number(pages)) \(Self.plural(pages, "страница", "страницы", "страниц"))"
            if doc.ocrPages > 0 { s += " (OCR: \(doc.ocrPages))" }
            parts.append(s)
        }
        let n = doc.paragraphs.count
        parts.append("\(Self.number(n)) \(Self.plural(n, "абзац", "абзаца", "абзацев"))")
        let c = doc.characterCount
        parts.append("\(Self.number(c)) \(Self.plural(c, "знак", "знака", "знаков"))")
        if let lang = doc.dominantLanguage { parts.append(UIText.capitalized(lang)) }
        if translator.isComplete {
            // Done: the estimate is history, say how long it really took.
            parts.append("переведено за \(Self.duration(max(1, translator.elapsed)))")
            statsLabel.toolTip = nil
        } else {
            parts.append("перевод ≈ \(Self.duration(estimate(doc))) (примерно, ~\(Int(Self.assumedSpeed)) знаков/с)")
            statsLabel.toolTip = "Оценка времени приблизительная: домашняя модель переводит около \(Int(Self.assumedSpeed)) знаков в секунду."
        }
        statsLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: - Target language & tone

    private var engineConfig: TolkConfig { (engine as? DefaultTranslationEngine)?.config ?? TolkConfig.load() }

    /// The engine's default direction for this document's language.
    private var autoTarget: Language {
        let config = engineConfig
        let source = document?.dominantLanguage ?? config.secondaryLanguage
        return LanguageDetector.defaultTarget(for: source, config: config)
    }

    private var selectedTarget: Language {
        if let raw = targetPopup.selectedItem?.representedObject as? String, let l = Language(rawValue: raw) { return l }
        return autoTarget
    }

    private var selectedTone: Tone {
        let i = toneControl.selectedSegment
        return i >= 0 && i < Tone.allCases.count ? Tone.allCases[i] : .formal
    }

    private func rebuildTargetPopup() {
        let saved = UserDefaults.standard.string(forKey: Self.targetKey)
        targetPopup.removeAllItems()
        let auto = autoTarget
        targetPopup.addItem(withTitle: "\(auto.flag)  \(UIText.capitalized(auto)) (по умолчанию)")
        targetPopup.lastItem?.representedObject = nil
        targetPopup.lastItem?.toolTip = "Направление из настроек для языка документа"
        targetPopup.menu?.addItem(.separator())
        for l in Language.main + Language.others {
            targetPopup.addItem(withTitle: "\(l.flag)  \(UIText.capitalized(l))")
            targetPopup.lastItem?.representedObject = l.rawValue
            if l == .english { targetPopup.menu?.addItem(.separator()) }
        }
        if let saved, let item = targetPopup.itemArray.first(where: { ($0.representedObject as? String) == saved }) {
            targetPopup.select(item)
        } else {
            targetPopup.selectItem(at: 0)
        }
    }

    @objc private func targetChanged(_ sender: Any?) {
        UserDefaults.standard.set(targetPopup.selectedItem?.representedObject as? String, forKey: Self.targetKey)
        settingsChanged()
    }

    @objc private func toneChanged(_ sender: Any?) {
        UserDefaults.standard.set(selectedTone.rawValue, forKey: Self.toneKey)
        settingsChanged()
    }

    /// Another language / tone while a translation exists: the next start translates from the beginning.
    private func settingsChanged() {
        updateHeaderTitle()
        guard translator.hasAnyTranslation else { updateButtons(); return }
        if runState == .running { pause() }
        if translator.target != selectedTarget || translator.tone != selectedTone {
            showNotice("Язык или тон изменились — «Перевести заново» начнёт с первого абзаца. Уже готовый перевод пока виден.",
                       color: .secondaryLabelColor)
        } else {
            hideNotice()
        }
        updateButtons()
    }

    private func updateHeaderTitle() {
        let lang = translator.target ?? selectedTarget
        let source = document?.dominantLanguage.map { " — \($0.russianName)" } ?? ""
        originalHeader.stringValue = "Оригинал" + source
        translationHeader.stringValue = "Перевод — \(lang.russianName)"
    }

    // MARK: - Run state

    private func setRunState(_ s: RunState) {
        runState = s
        if s == .running {
            if tickTimer == nil {
                let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateProgress() }
                }
                t.tolerance = 0.3
                RunLoop.main.add(t, forMode: .common)
                tickTimer = t
            }
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
        if s != .running { followButton.isHidden = true }
        updateButtons()
    }

    private func updateButtons() {
        let hasDoc = document != nil
        let any = translator.hasAnyTranslation
        let complete = translator.isComplete
        let changed = any && (translator.target != selectedTarget || translator.tone != selectedTone)
        switch runState {
        case .running, .paused:
            let running = runState == .running
            translateButton.isHidden = true
            pauseButton.isHidden = false
            pauseButton.title = running ? "Пауза" : "Продолжить"
            pauseButton.image = NSImage(systemSymbolName: running ? "pause.fill" : "play.fill", accessibilityDescription: nil)
            cancelButton.isHidden = false
        case .idle:
            translateButton.isHidden = !hasDoc
            pauseButton.isHidden = true
            cancelButton.isHidden = true
            translateButton.title = complete || changed ? "Перевести заново" : (any ? "Продолжить перевод" : "Перевести")
            translateButton.image = NSImage(systemSymbolName: complete || changed ? "arrow.clockwise" : "play.fill",
                                            accessibilityDescription: nil)
        }
        saveButton.isEnabled = any
        targetPopup.isEnabled = hasDoc
        toneControl.isEnabled = hasDoc
    }

    @objc private func primaryAction(_ sender: Any?) {
        if runState == .paused { resume(); return }
        startTranslation()
    }

    @objc private func pauseAction(_ sender: Any?) {
        runState == .running ? pause() : resume()
    }

    @objc private func cancelAction(_ sender: Any?) { stopTranslator(to: .idle) }

    private func pause() { stopTranslator(to: .paused) }

    private func stopTranslator(to state: RunState) {
        let row = translator.current
        translator.stop()
        setRunState(state)
        markCurrent(nil)
        if let row { reloadRow(row) }
        updateProgress()
    }

    private func resume() {
        hideNotice()
        runTranslator()
    }

    // MARK: - Translator events

    private func handle(_ event: DocumentTranslator.Event) {
        switch event {
        case let .provider(p):
            providerBadge.text = UIText.providerName(p)
            providerBadge.tint = UIText.isFallbackProvider(p) ? .systemOrange : .secondaryLabelColor
        case let .fellBack(from, reason):
            showNotice(UIText.fallbackSwitching(from: from), color: .systemOrange)
            noticeLabel.toolTip = reason
        case let .began(i):
            markCurrent(i)
            reloadRow(i)
            follow(i)
            updateProgress()
        case let .partial(i, _):
            reloadRow(i)
            if autoFollow { scrollRowBottomToVisible(i) }
        case let .done(i):
            if currentRow == i { markCurrent(nil) }
            reloadRow(i)
            updateProgress()
            if !translator.isRunning { updateButtons() }
        case .finished:
            markCurrent(nil)
            setRunState(.idle)
            updateProgress()
            updateStats()
            hideNotice()
        case let .failed(message):
            markCurrent(nil)
            setRunState(.paused)
            updateProgress()
            showNotice(message + " Готовые абзацы сохранены — нажмите «Продолжить», чтобы повторить.", color: .systemRed)
        }
    }

    private func updateProgress() {
        guard document != nil else { progressRow.isHidden = true; return }
        let total = translator.paragraphs.count
        let done = translator.doneCount
        progressRow.isHidden = !(runState != .idle || translator.hasAnyTranslation)
        progressBar.doubleValue = total > 0 ? Double(done) / Double(total) : 0
        let elapsed = Self.clock(translator.elapsed)
        switch runState {
        case .running:
            let n = min(total, (translator.current ?? done) + 1)
            let left = translator.remainingEstimate(speed: Self.assumedSpeed, perRequest: Self.perRequest)
            progressLabel.stringValue = "Абзац \(Self.number(n)) из \(Self.number(total)) · прошло \(elapsed) · осталось ≈ \(Self.clock(left))"
        case .paused:
            progressLabel.stringValue = "Пауза · переведено \(Self.number(done)) из \(Self.number(total)) · прошло \(elapsed)"
        case .idle:
            progressLabel.stringValue = done == total
                ? "Готово · \(Self.number(total)) \(Self.plural(total, "абзац", "абзаца", "абзацев")) за \(elapsed)"
                : "Остановлено · переведено \(Self.number(done)) из \(Self.number(total))"
        }
    }

    // MARK: - Following the progress

    private func markCurrent(_ row: Int?) {
        if let old = currentRow, old < tableView.numberOfRows,
           let rv = tableView.rowView(atRow: old, makeIfNecessary: false) as? ParagraphRowView { rv.isCurrent = false }
        currentRow = row
        if let row, row < tableView.numberOfRows,
           let rv = tableView.rowView(atRow: row, makeIfNecessary: false) as? ParagraphRowView { rv.isCurrent = true }
    }

    private func follow(_ row: Int) {
        guard autoFollow else { followButton.isHidden = runState != .running; return }
        // Keep the current paragraph in the upper third with some context above.
        let rect = tableView.rect(ofRow: row)
        let visible = scrollView.contentView.bounds
        if rect.minY < visible.minY || rect.maxY > visible.maxY - visible.height * 0.25 {
            let y = max(0, min(rect.minY - visible.height * 0.3, tableView.bounds.height - visible.height))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func scrollRowBottomToVisible(_ row: Int) {
        let rect = tableView.rect(ofRow: row)
        let visible = scrollView.contentView.bounds
        guard rect.maxY > visible.maxY else { return }
        let y = min(rect.maxY - visible.height + 12, rect.minY - 8)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func userScrolled() {
        guard runState == .running, autoFollow else { return }
        autoFollow = false
        followButton.isHidden = false
    }

    @objc private func liveScrollStarted(_ n: Notification) { userScrolled() }

    @objc private func followAgain(_ sender: Any?) {
        autoFollow = true
        followButton.isHidden = true
        if let row = translator.current ?? currentRow { follow(row) }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { translator.paragraphs.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = ParagraphRowView()
        rv.isCurrent = row == currentRow
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ParagraphCellView) ?? {
            let c = ParagraphCellView()
            c.identifier = id
            return c
        }()
        cell.label.attributedStringValue = text(for: row, translation: id.rawValue == "trans")
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let widths = tableView.tableColumns.map(\.width)
        let key = widths.reduce(0, +)
        if key != heightWidth { heightWidth = key; heightCache = [:] }
        if let h = heightCache[row] { return h }
        let i = ParagraphCellView.insets
        var h: CGFloat = 0
        for (c, w) in widths.enumerated() {
            let s = text(for: row, translation: c == 1)
            let inner = max(40, w - i.left - i.right - 4)
            let r = s.boundingRect(with: NSSize(width: inner, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
            h = max(h, ceil(r.height))
        }
        let result = max(24, h + i.top + i.bottom + 2)
        heightCache[row] = result
        return result
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        heightCache = [:]
        if view.window?.inLiveResize == true {
            let visible = tableView.rows(in: tableView.visibleRect)
            noteHeights(IndexSet(integersIn: visible.location..<NSMaxRange(visible)))
        } else {
            scheduleAllHeights()
        }
    }

    @objc private func windowEndedLiveResize(_ n: Notification) {
        guard (n.object as? NSWindow) === view.window, !contentView.isHidden else { return }
        heightCache = [:]
        noteAllHeights()
    }

    private var allHeightsScheduled = false
    private func scheduleAllHeights() {
        guard !allHeightsScheduled else { return }
        allHeightsScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.allHeightsScheduled = false
            self?.noteAllHeights()
        }
    }

    private func noteAllHeights() {
        noteHeights(IndexSet(integersIn: 0..<tableView.numberOfRows))
    }

    private func noteHeights(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: rows)
        }
    }

    private func reloadRow(_ row: Int) {
        guard row < tableView.numberOfRows else { return }
        heightCache[row] = nil
        if let cell = tableView.view(atColumn: 1, row: row, makeIfNecessary: false) as? ParagraphCellView {
            cell.label.attributedStringValue = text(for: row, translation: true)
        }
        noteHeights(IndexSet(integer: row))
    }

    // MARK: - Cell text

    private func font(for style: ParagraphStyle) -> NSFont {
        switch style.headingLevel {
        case 1: .systemFont(ofSize: 18, weight: .bold)
        case 2: .systemFont(ofSize: 16, weight: .semibold)
        case 3: .systemFont(ofSize: 14, weight: .semibold)
        default:
            style.bold ? .systemFont(ofSize: 13.5, weight: .semibold)
                : (style.italic ? NSFontManager.shared.convert(.systemFont(ofSize: 13.5), toHaveTrait: .italicFontMask)
                                : .systemFont(ofSize: 13.5))
        }
    }

    private static let cellParagraph: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 2
        ps.lineBreakMode = .byWordWrapping
        return ps
    }()

    private func text(for row: Int, translation: Bool) -> NSAttributedString {
        guard row < translator.paragraphs.count else { return NSAttributedString() }
        let p = translator.paragraphs[row]
        var attrs: [NSAttributedString.Key: Any] = [.font: font(for: p.style), .paragraphStyle: Self.cellParagraph,
                                                    .foregroundColor: NSColor.labelColor]
        if !translation {
            if !p.translatable { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
            return NSAttributedString(string: p.fullText, attributes: attrs)
        }
        if let t = translator.translations[row] {
            if translator.kept.contains(row) { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
            return NSAttributedString(string: p.prefix + t, attributes: attrs)
        }
        if row == translator.current {
            let s = NSMutableAttributedString(string: p.prefix + translator.partial, attributes: attrs)
            attrs[.foregroundColor] = NSColor.controlAccentColor
            s.append(NSAttributedString(string: translator.partial.isEmpty ? "Перевожу…" : " ▍", attributes: attrs))
            return s
        }
        return NSAttributedString()
    }

    // MARK: - Open / close / drop

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentExtractor.openPanelTypes
        panel.message = "Выберите документ для перевода"
        panel.prompt = "Открыть"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.open(url: url)
        }
        if let w = view.window { panel.beginSheetModal(for: w, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    @objc private func cancelLoading(_ sender: Any?) {
        extractTask?.cancel()
        extractTask = nil
        loadingSpinner.stopAnimation(nil)
        show(document == nil ? .empty : .content)
    }

    @objc private func closeDocument(_ sender: Any?) {
        guard confirmDiscard() else { return }
        translator.load([])
        document = nil
        setRunState(.idle)
        markCurrent(nil)
        tableView.reloadData()
        hideNotice()
        show(.empty)
    }

    /// Unsaved translation: ask before throwing it away.
    private func confirmDiscard() -> Bool {
        guard translator.hasAnyTranslation, !saved else { return true }
        let alert = NSAlert()
        alert.messageText = "Закрыть перевод без сохранения?"
        alert.informativeText = "Переведено \(translator.doneCount) из \(translator.paragraphs.count) абзацев. Несохранённый перевод пропадёт."
        alert.addButton(withTitle: "Закрыть")
        alert.addButton(withTitle: "Отмена")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        translator.stop()
        return true
    }

    fileprivate func droppedURL(_ pb: NSPasteboard) -> URL? {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first(where: DocumentExtractor.canOpen)
    }

    fileprivate func setDropTargeted(_ on: Bool) {
        dropZone.isTargeted = on
        dropCover.isHidden = !on || contentView.isHidden
    }

    // MARK: - Export

    @objc private func saveAs(_ sender: Any?) {
        guard let doc = document, translator.hasAnyTranslation else { return }
        let panel = NSSavePanel()
        let defaults = UserDefaults.standard
        var format = DocumentExportFormat(rawValue: defaults.integer(forKey: Self.formatKey)) ?? .docx
        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for f in DocumentExportFormat.allCases { formatPopup.addItem(withTitle: f.title) }
        formatPopup.selectItem(at: format.rawValue)
        let bilingual = NSButton(checkboxWithTitle: "Двуязычный: после каждого абзаца оригинала — его перевод", target: nil, action: nil)
        bilingual.state = defaults.bool(forKey: Self.bilingualKey) ? .on : .off
        var rows: [[NSView]] = [[UIFactory.label("Формат:", size: 13, color: .labelColor), formatPopup], [NSView(), bilingual]]
        let done = translator.doneCount, total = translator.paragraphs.count
        if done < total {
            let note = UIFactory.label("Переведено \(done) из \(total) абзацев — в файл попадут только готовые.", size: 12, color: .secondaryLabelColor)
            rows.append([NSView(), note])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: done < total ? 96 : 70))
        grid.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
        ])
        panel.accessoryView = accessory
        let base = (doc.name as NSString).deletingPathExtension
        let lang = (translator.target ?? selectedTarget).label
        panel.nameFieldStringValue = "\(base) — \(lang).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Сохранить перевод"
        panel.prompt = "Сохранить"
        let formatTarget = ClosureTarget { [weak panel] in
            guard let panel, let f = DocumentExportFormat(rawValue: formatPopup.indexOfSelectedItem) else { return }
            format = f
            panel.allowedContentTypes = [f.contentType]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(name).\(f.fileExtension)"
        }
        formatPopup.target = formatTarget
        formatPopup.action = #selector(ClosureTarget.fire)

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            withExtendedLifetime(formatTarget) {}
            guard r == .OK, let url = panel.url, let self else { return }
            let isBilingual = bilingual.state == .on
            defaults.set(format.rawValue, forKey: Self.formatKey)
            defaults.set(isBilingual, forKey: Self.bilingualKey)
            self.export(to: url, format: format, bilingual: isBilingual)
        }
        if let w = view.window { panel.beginSheetModal(for: w, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Writes the file in the background; reports errors in an alert.
    func export(to url: URL, format: DocumentExportFormat, bilingual: Bool, completion: ((Error?) -> Void)? = nil) {
        let pairs = translationPairs
        let keepStyle = document?.kind == .rich
        saveButton.isEnabled = false
        Task { @MainActor [weak self] in
            let result: Error? = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    let data = try DocumentExporter.data(pairs, format: format, bilingual: bilingual, keepSourceStyle: keepStyle)
                    try data.write(to: url, options: .atomic)
                    return nil
                } catch { return error }
            }.value
            guard let self else { completion?(result); return }
            self.saveButton.isEnabled = self.translator.hasAnyTranslation
            if let result {
                self.showAlert("Не удалось сохранить файл: \(result.localizedDescription)")
            } else {
                self.saved = self.translator.isComplete
                self.showNotice("Сохранено: \(url.lastPathComponent)", color: .secondaryLabelColor)
            }
            completion?(result)
        }
    }

    // MARK: - Notices

    private func showNotice(_ text: String, color: NSColor = .systemOrange) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = color
        noticeLabel.isHidden = false
    }

    private func hideNotice() { noticeLabel.isHidden = true; noticeLabel.stringValue = "" }

    private func showAlert(_ text: String) {
        #if DEBUG
        if SmokeTest.requested { print("smoke: alert suppressed: \(text)"); return } // the smoke run must never put a dialog on screen
        #endif
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        if let w = view.window, w.isVisible { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    // MARK: - Words & numbers

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    static func number(_ n: Int) -> String { numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }

    /// "40 с", "3 мин", "12 мин", "2 ч 15 мин".
    static func duration(_ t: TimeInterval) -> String {
        let s = max(1, Int(t.rounded()))
        if s < 60 { return "\(s) с" }
        if s < 600 { let m = s / 60, r = s % 60; return r >= 10 ? "\(m) мин \(r / 10 * 10) с" : "\(m) мин" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded())) мин" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    /// "1:05", "1:02:10".
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Debug rendering

    #if DEBUG
    /// Demo: presses «Пауза» / «Продолжить».
    func debugTogglePause() { pauseAction(nil) }
    var debugProgressText: String { progressLabel.stringValue }

    /// Renders the page (current state) to PNG; works without screen-recording permission.
    func renderForReview(to path: String) {
        guard let v = view.window?.contentView ?? Optional(view) else { return }
        v.layoutSubtreeIfNeeded()
        tableView.reloadData()
        v.displayIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds),
              let out = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        // The window background is not part of the view: composite the page over it.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        v.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            v.bounds.fill()
        }
        rep.draw(in: v.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}

/// Target/action adapter for a closure (save panel accessory controls).
private final class ClosureTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
