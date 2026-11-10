import AppKit
import TolkCore
import UniformTypeIdentifiers

/// Root view of the page: accepts drops (files, Photos file promises, image data) and ⌘V with an image.
private final class ImagePageView: NSView {
    weak var controller: ImageTranslateViewController?
    override var acceptsFirstResponder: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard controller?.canAccept(sender.draggingPasteboard) == true else { return [] }
        controller?.setDropTargeted(true)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.canAccept(sender.draggingPasteboard) == true ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.setDropTargeted(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.setDropTargeted(false)
        return controller?.acceptDrop(sender.draggingPasteboard) ?? false
    }

    @objc func paste(_ sender: Any?) { controller?.pasteFromClipboard(nil) }
}

/// Recognized text: plain text only; ⌘V with an image on the pasteboard loads the image instead.
private final class SourceTextView: NSTextView {
    var onPasteImage: (() -> Void)?
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) == nil, ImageLoader.pasteboardHasImage(pb) { onPasteImage?(); return }
        super.paste(sender)
    }
}

/// "Фото и скриншоты" page: drop / open / paste / capture an image -> OCR (Vision, offline) -> translation.
@MainActor
final class ImageTranslateViewController: NSViewController, NSTextViewDelegate {
    /// The coordinator may swap the engine after settings change (`TolkConfig.didChange`).
    var engine: TranslationEngine {
        didSet {
            translator.cancel()
            translator = ChunkedTranslator(engine: engine)
            translator.onUpdate = { [weak self] in self?.handleTranslation($0) }
            translateSpinner?.stopAnimation(nil)
        }
    }
    /// Shown in the empty state ("из любой программы: ⌥⇧S"). The coordinator sets the real hotkey.
    var screenHotKeyDisplay = "⌥⇧S" { didSet { if isViewLoaded { updateHotKeyHint() } } }

    private var translator: ChunkedTranslator
    /// Shared with the app's ⌥⇧S hotkey (set by AppDelegate), so two selection overlays can never run at once.
    var screenCapture = ScreenCaptureController()

    // State
    private var pages: [ImagePage] = []
    private var results: [OCRResult] = []
    private var currentPage = 0
    /// Range of every paragraph in `sourceView` (per page), valid while the text is unedited.
    private var paragraphRanges: [[NSRange]] = []
    private var textEdited = false
    private var ocrTask: Task<Void, Never>?
    private var copyResetWork: [ObjectIdentifier: DispatchWorkItem] = [:]

    // Views
    private var emptyView: NSView!
    private var dropZone: DropZoneView!
    private var hotKeyHint: NSTextField!
    private var contentView: NSView!
    private var dropCover: NSView!
    private var fileLabel: NSTextField!
    private var preview: ImagePreviewView!
    private var pageBar: NSStackView!
    private var pageLabel: NSTextField!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var sourceView: SourceTextView!
    private var ocrSpinner: NSProgressIndicator!
    private var ocrStatus: NSTextField!
    private var translationView: NSTextView!
    private var translationPlaceholder: NSTextField!
    private var providerBadge: BadgeView!
    private var progressLabel: NSTextField!
    private var translateSpinner: NSProgressIndicator!
    private var targetPopup: NSPopUpButton!
    private var retranslateButton: NSButton!
    private var copyTextButton: NSButton!
    private var copyTranslationButton: NSButton!
    private var noticeLabel: NSTextField!
    private var split: NSSplitView!
    private var splitPositioned = false

    private static let targetKey = "tolk.image.target"
    private static let textFont = NSFont.systemFont(ofSize: 15)

    init(engine: TranslationEngine) {
        self.engine = engine
        translator = ChunkedTranslator(engine: engine)
        super.init(nibName: nil, bundle: nil)
        translator.onUpdate = { [weak self] in self?.handleTranslation($0) }
        ImageOCR.warmUp()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    /// Opens files (images / PDF). Several files become several pages.
    func open(urls: [URL]) {
        loadViewIfNeeded()
        var loaded: [ImagePage] = []
        var errors: [String] = []
        for url in urls {
            do { loaded += try ImageLoader.pages(from: url) } catch { errors.append(error.localizedDescription) }
        }
        if !loaded.isEmpty { load(pages: loaded) }
        if !errors.isEmpty { showNotice(errors.joined(separator: "\n")) }
    }

    func load(image: CGImage, name: String) { load(pages: [ImagePage(image: image, name: name)]) }

    /// Shows the pages, recognizes them one by one, then translates the whole text.
    func load(pages newPages: [ImagePage]) {
        guard !newPages.isEmpty else { return }
        _ = view
        ocrTask?.cancel()
        translator.cancel()
        translateSpinner.stopAnimation(nil) // the cancelled translation never reports back: no endless spinner on a text-less image
        pages = newPages
        results = Array(repeating: .empty, count: newPages.count)
        paragraphRanges = []
        currentPage = 0
        textEdited = false
        showContent(true)
        let name = newPages.count == 1 ? newPages[0].name
            : "\(newPages[0].name.components(separatedBy: ",").first ?? newPages[0].name) · \(Self.pagesWord(newPages.count))"
        fileLabel.stringValue = name
        sourceView.string = ""
        setTranslation("")
        providerBadge.text = ""
        progressLabel.stringValue = ""
        hideNotice()
        updatePage()
        updateButtons()

        ocrSpinner.startAnimation(nil)
        ocrStatus.isHidden = false
        ocrStatus.stringValue = "Распознаю текст…"
        ocrTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for i in newPages.indices {
                if Task.isCancelled { return }
                if newPages.count > 1 { self.ocrStatus.stringValue = "Распознаю страницу \(i + 1) из \(newPages.count)…" }
                let t0 = Date()
                let r = (try? await ImageOCR.recognize(newPages[i].image)) ?? .empty
                if Task.isCancelled { Diagnostics.log("image page: ocr cancelled"); return }
                Diagnostics.log("image page: ocr page=\(i + 1)/\(newPages.count) chars=\(r.text.count) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
                self.results[i] = r
                if i == self.currentPage { self.updatePage() }
            }
            self.ocrTask = nil
            self.ocrFinished()
        }
    }

    // MARK: - View

    override func loadView() {
        let root = ImagePageView()
        root.controller = self
        root.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                      NSPasteboard.PasteboardType("public.heic"), .pdf]
                                     + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        view = root
        buildEmptyView()
        buildContentView()
        for v in [emptyView!, contentView!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.topAnchor.constraint(equalTo: root.topAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        showContent(false)
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 640).isActive = true
        root.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
    }

    private func buildEmptyView() {
        let container = NSView()
        let zone = DropZoneView()
        zone.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(zone)
        dropZone = zone

        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 54, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        let title = UIFactory.label("Перетащите фото или скриншот сюда", size: 22, weight: .semibold, color: .labelColor)
        title.alignment = .center
        let subtitle = UIFactory.wrappingLabel(
            "HEIC, JPEG, PNG или PDF — можно сразу несколько страниц.\nТекст распознаётся прямо на этом Mac, затем переводится.",
            size: 13, color: .secondaryLabelColor)
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 460

        let open = bigButton("Открыть файл…", symbol: "folder", #selector(openFile(_:)))
        open.keyEquivalent = "\r"
        let paste = bigButton("Вставить из буфера", symbol: "doc.on.clipboard", #selector(pasteFromClipboard(_:)))
        let capture = bigButton("Снять область экрана", symbol: "viewfinder", #selector(captureArea(_:)))
        let buttons = NSStackView(views: [open, paste, capture])
        buttons.spacing = 10

        hotKeyHint = UIFactory.label("", size: 12, color: .tertiaryLabelColor)
        hotKeyHint.alignment = .center
        updateHotKeyHint()

        let stack = NSStackView(views: [icon, title, subtitle, buttons, hotKeyHint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: icon)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(16, after: buttons)
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

    private func buildContentView() {
        let container = NSView()

        // Toolbar
        let open = toolButton("Открыть…", symbol: "folder", #selector(openFile(_:)), tip: "Открыть фото, скриншот или PDF")
        let paste = toolButton("Вставить", symbol: "doc.on.clipboard", #selector(pasteFromClipboard(_:)), tip: "Вставить картинку из буфера (⌘V)")
        let capture = toolButton("Снять область", symbol: "viewfinder", #selector(captureArea(_:)), tip: "Выделить область экрана с текстом")
        fileLabel = UIFactory.label("", size: 12, color: .secondaryLabelColor)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let clear = UIFactory.symbolButton("xmark.circle.fill", tooltip: "Закрыть изображение", target: self, action: #selector(clearAll(_:)))
        let toolbar = NSStackView(views: [open, paste, capture, UIFactory.spacer(), fileLabel, clear])
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)

        // Left: preview + page bar
        let left = NSView()
        left.wantsLayer = true
        left.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
        left.layer?.cornerRadius = 10
        preview = ImagePreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.onClickBox = { [weak self] i in self?.selectParagraph(i) }
        left.addSubview(preview)
        prevButton = UIFactory.symbolButton("chevron.left", tooltip: "Предыдущая страница", target: self, action: #selector(prevPage(_:)))
        nextButton = UIFactory.symbolButton("chevron.right", tooltip: "Следующая страница", target: self, action: #selector(nextPage(_:)))
        pageLabel = UIFactory.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
        pageBar = NSStackView(views: [prevButton, pageLabel, nextButton])
        pageBar.spacing = 6
        pageBar.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(pageBar)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            preview.topAnchor.constraint(equalTo: left.topAnchor),
            preview.bottomAnchor.constraint(equalTo: pageBar.topAnchor, constant: -2),
            pageBar.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            pageBar.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -8),
        ])

        // Right: recognized text + translation
        let sourceTitle = UIFactory.label("Распознанный текст", size: 13, weight: .semibold, color: .labelColor)
        ocrSpinner = spinner()
        ocrStatus = UIFactory.label("", size: 12)
        copyTextButton = toolButton("Копировать текст", symbol: "doc.on.doc", #selector(copyText(_:)), tip: "Скопировать распознанный текст")
        copyTextButton.controlSize = .small
        let sourceHeader = NSStackView(views: [sourceTitle, ocrSpinner, ocrStatus, UIFactory.spacer(), copyTextButton])
        sourceHeader.spacing = 6

        let (sourceScroll, sv) = makeTextArea(editable: true)
        sourceView = sv as? SourceTextView
        sourceView.onPasteImage = { [weak self] in self?.pasteFromClipboard(nil) }

        let translationTitle = UIFactory.label("Перевод", size: 13, weight: .semibold, color: .labelColor)
        providerBadge = UIFactory.badge()
        providerBadge.text = ""
        translateSpinner = spinner()
        progressLabel = UIFactory.label("", size: 12)
        targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        targetPopup.controlSize = .small
        targetPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        targetPopup.addItem(withTitle: "Язык перевода: авто")
        targetPopup.menu?.addItem(.separator())
        for l in Language.allCases {
            targetPopup.addItem(withTitle: "\(l.flag)  \(UIText.intoLanguage(l))")
            targetPopup.lastItem?.representedObject = l.rawValue
        }
        if let saved = UserDefaults.standard.string(forKey: Self.targetKey),
           let item = targetPopup.itemArray.first(where: { ($0.representedObject as? String) == saved }) {
            targetPopup.select(item)
        }
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged(_:))
        targetPopup.toolTip = "На какой язык переводить"
        retranslateButton = toolButton("Перевести", symbol: "arrow.clockwise", #selector(retranslate(_:)), tip: "Перевести текст ещё раз (после правок)")
        retranslateButton.controlSize = .small
        copyTranslationButton = toolButton("Копировать перевод", symbol: "doc.on.doc", #selector(copyTranslation(_:)), tip: "Скопировать перевод")
        copyTranslationButton.controlSize = .small
        let translationHeader = NSStackView(views: [translationTitle, providerBadge, translateSpinner, progressLabel,
                                                    UIFactory.spacer(), targetPopup, retranslateButton, copyTranslationButton])
        translationHeader.spacing = 6

        let (translationScroll, tv) = makeTextArea(editable: false)
        translationView = tv
        translationPlaceholder = UIFactory.label("Перевод появится здесь", size: 15, color: .placeholderTextColor)
        translationPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        translationScroll.addSubview(translationPlaceholder)
        NSLayoutConstraint.activate([
            translationPlaceholder.leadingAnchor.constraint(equalTo: translationScroll.leadingAnchor, constant: 15),
            translationPlaceholder.topAnchor.constraint(equalTo: translationScroll.topAnchor, constant: 11),
        ])

        noticeLabel = UIFactory.wrappingLabel("", size: 12, color: .systemOrange)
        noticeLabel.isHidden = true

        let right = NSStackView(views: [sourceHeader, sourceScroll, translationHeader, translationScroll, noticeLabel])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6
        right.setCustomSpacing(16, after: sourceScroll)
        for v in [sourceHeader, sourceScroll, translationHeader, translationScroll, noticeLabel] as [NSView] {
            v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }
        sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        translationScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        translationScroll.heightAnchor.constraint(equalTo: sourceScroll.heightAnchor, multiplier: 1.25).isActive = true

        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        let rightWrap = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        rightWrap.addSubview(right)
        NSLayoutConstraint.activate([
            right.leadingAnchor.constraint(equalTo: rightWrap.leadingAnchor, constant: 14),
            right.trailingAnchor.constraint(equalTo: rightWrap.trailingAnchor),
            right.topAnchor.constraint(equalTo: rightWrap.topAnchor),
            right.bottomAnchor.constraint(equalTo: rightWrap.bottomAnchor),
        ])
        let leftWrap = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false
        leftWrap.addSubview(left)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leftWrap.leadingAnchor),
            left.trailingAnchor.constraint(equalTo: leftWrap.trailingAnchor, constant: -14),
            left.topAnchor.constraint(equalTo: leftWrap.topAnchor),
            left.bottomAnchor.constraint(equalTo: leftWrap.bottomAnchor),
        ])
        split.addArrangedSubview(leftWrap)
        split.addArrangedSubview(rightWrap)
        leftWrap.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        rightWrap.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        container.addSubview(split)

        // Translucent cover shown while a drag hovers over the loaded page.
        dropCover = DropZoneView()
        (dropCover as! DropZoneView).isTargeted = true
        let coverLabel = UIFactory.label("Отпустите, чтобы распознать", size: 17, weight: .semibold, color: .controlAccentColor)
        coverLabel.translatesAutoresizingMaskIntoConstraints = false
        dropCover.addSubview(coverLabel)
        dropCover.wantsLayer = true
        dropCover.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        dropCover.layer?.cornerRadius = 16
        dropCover.isHidden = true
        dropCover.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dropCover)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            dropCover.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            dropCover.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            dropCover.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            dropCover.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            coverLabel.centerXAnchor.constraint(equalTo: dropCover.centerXAnchor),
            coverLabel.centerYAnchor.constraint(equalTo: dropCover.centerYAnchor),
        ])
        contentView = container
    }

    private func makeTextArea(editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        let tv: NSTextView = editable ? SourceTextView() : NSTextView()
        tv.isEditable = editable
        tv.isSelectable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = Self.textFont
        tv.textColor = .labelColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.delegate = self
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 2
        tv.defaultParagraphStyle = ps
        tv.typingAttributes[.paragraphStyle] = ps
        scroll.documentView = tv
        return (scroll, tv)
    }

    private func bigButton(_ title: String, symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        return b
    }

    private func toolButton(_ title: String, symbol: String, _ action: Selector, tip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.toolTip = tip
        return b
    }

    private func spinner() -> NSProgressIndicator {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.isDisplayedWhenStopped = false
        return s
    }

    private func updateHotKeyHint() {
        hotKeyHint.stringValue = screenHotKeyDisplay.isEmpty ? ""
            : "Перевести текст с экрана из любой программы: \(screenHotKeyDisplay) и выделите область"
    }

    private func showContent(_ on: Bool) {
        emptyView.isHidden = on
        contentView.isHidden = !on
        if on { positionSplitIfNeeded() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionSplitIfNeeded()
    }

    /// First time the page is shown: picture gets ~45 % of the width.
    private func positionSplitIfNeeded() {
        guard !splitPositioned, !contentView.isHidden else { return }
        contentView.layoutSubtreeIfNeeded()
        guard split.bounds.width > 600 else { return }
        splitPositioned = true
        split.setPosition(round(split.bounds.width * 0.45), ofDividerAt: 0)
    }

    // MARK: - Drop & paste

    fileprivate func canAccept(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty { return urls.contains(where: ImageLoader.canOpen) }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            return true
        }
        return NSImage.canInit(with: pb)
    }

    fileprivate func setDropTargeted(_ on: Bool) {
        dropZone.isTargeted = on
        dropCover.isHidden = !on || contentView.isHidden
    }

    fileprivate func acceptDrop(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            open(urls: urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            return true
        }
        // Photos.app and some browsers give file promises.
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            receive(promises)
            return true
        }
        let (loaded, errors) = ImageLoader.pages(from: pb)
        if !loaded.isEmpty { load(pages: loaded); return true }
        if !errors.isEmpty { showNotice(errors.joined(separator: "\n")) }
        return false
    }

    private func receive(_ promises: [NSFilePromiseReceiver]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TolkDrops-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = OperationQueue()
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        showNotice("Получаю файлы…", color: .secondaryLabelColor)
        for p in promises {
            group.enter()
            p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                if error == nil { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.hideNotice()
            if urls.isEmpty { self.showNotice("Не удалось получить файл. Попробуйте «Открыть файл…»."); return }
            self.open(urls: urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
    }

    // MARK: - Actions

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageLoader.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Выберите фото, скриншот или PDF. Можно несколько файлов — они станут страницами."
        panel.prompt = "Распознать"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK else { return }
            self?.open(urls: panel.urls)
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(panel.runModal()) }
    }

    @objc func pasteFromClipboard(_ sender: Any?) {
        loadViewIfNeeded()
        let (loaded, errors) = ImageLoader.pages(from: .general)
        if !loaded.isEmpty { load(pages: loaded); return }
        if !errors.isEmpty { showNotice(errors.joined(separator: "\n")); return }
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty, !contentView.isHidden {
            sourceView.window?.makeFirstResponder(sourceView)
            sourceView.paste(nil)
            return
        }
        showNotice("В буфере обмена нет картинки. Скопируйте фото или сделайте снимок ⌘⌃⇧4.")
    }

    /// Main window closed: stop translating a long document so it doesn't hold an Ollama slot.
    func cancelWork() { translator.cancel() }

    @objc func captureArea(_ sender: Any?) {
        let window = view.window
        // The window is made invisible, NOT ordered out. Ordering out Tolk's only window makes macOS hand the
        // active state to the previous app, and on macOS 14+ Tolk cannot take it back (`NSApp.activate` is only a
        // request): the result then lands in a window behind another app — it looked as if Tolk "flew away"
        // after every capture. An invisible window keeps Tolk active and is not in the screenshot.
        let oldAlpha = window?.alphaValue ?? 1
        window?.alphaValue = 0
        window?.ignoresMouseEvents = true
        let restore: (Bool) -> Void = { activate in
            window?.ignoresMouseEvents = false
            window?.alphaValue = oldAlpha
            if activate {
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                window?.orderFront(nil)
            }
        }
        // Let the window disappear before the overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { restore(true); return }
            self.screenCapture.selectImage(route: .mainWindow) { [weak self] image, _, end in
                guard let self, let image else {
                    // Esc / right click: the user was in Tolk — window back and active.
                    // ⌘Tab to another app: window back too, but don't pull focus from where the user went.
                    restore(CaptureFocus.target(route: .mainWindow, end: end) == .tolk)
                    return
                }
                restore(true)
                self.load(image: image, name: "Снимок области экрана")
            }
        }
    }

    @objc private func clearAll(_ sender: Any?) {
        ocrTask?.cancel(); ocrTask = nil
        translator.cancel()
        ocrSpinner.stopAnimation(nil); translateSpinner.stopAnimation(nil)
        ocrStatus.stringValue = ""; progressLabel.stringValue = ""
        pages = []; results = []; paragraphRanges = []
        preview.image = nil; preview.boxes = []
        sourceView.string = ""
        setTranslation("")
        hideNotice()
        showContent(false)
    }

    @objc private func prevPage(_ sender: Any?) { if currentPage > 0 { currentPage -= 1; updatePage() } }
    @objc private func nextPage(_ sender: Any?) { if currentPage < pages.count - 1 { currentPage += 1; updatePage() } }

    @objc private func targetChanged(_ sender: Any?) {
        UserDefaults.standard.set(selectedTarget?.rawValue, forKey: Self.targetKey)
        startTranslation()
    }

    @objc private func retranslate(_ sender: Any?) { startTranslation() }

    @objc private func copyText(_ sender: NSButton) {
        let sel = sourceView.selectedRange()
        let s = sel.length > 0 ? (sourceView.string as NSString).substring(with: sel) : sourceView.string
        guard !s.isEmpty else { return }
        Clipboard.copy(s)
        flashCopied(sender, title: "Копировать текст")
    }

    @objc private func copyTranslation(_ sender: NSButton) {
        let s = translator.translation
        guard !s.isEmpty else { return }
        Clipboard.copy(s)
        flashCopied(sender, title: "Копировать перевод")
    }

    private func flashCopied(_ b: NSButton, title: String) {
        let key = ObjectIdentifier(b)
        copyResetWork[key]?.cancel()
        b.title = "Скопировано"
        b.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        let work = DispatchWorkItem { [weak b] in
            b?.title = title
            b?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
        copyResetWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    // MARK: - OCR

    private func updatePage() {
        guard !pages.isEmpty else { return }
        currentPage = min(currentPage, pages.count - 1)
        preview.image = pages[currentPage].image
        preview.boxes = results[currentPage].paragraphs.map(\.rect)
        preview.selected = nil
        pageBar.isHidden = pages.count < 2
        pageLabel.stringValue = "Страница \(currentPage + 1) из \(pages.count)"
        prevButton.isEnabled = currentPage > 0
        nextButton.isEnabled = currentPage < pages.count - 1
    }

    private func ocrFinished() {
        ocrSpinner.stopAnimation(nil)
        // Compose the text and remember where every paragraph is (for click-to-select).
        var text = ""
        paragraphRanges = []
        for r in results {
            var ranges: [NSRange] = []
            if !r.isEmpty, !text.isEmpty { text += "\n\n" }
            for (i, p) in r.paragraphs.enumerated() {
                let start = (text as NSString).length
                text += p.text
                ranges.append(NSRange(location: start, length: (p.text as NSString).length))
                if i < r.paragraphs.count - 1 { text += p.separatorAfter }
            }
            paragraphRanges.append(ranges)
        }
        sourceView.string = text
        sourceView.setSelectedRange(NSRange(location: 0, length: 0))
        sourceView.scrollToBeginningOfDocument(nil)
        preview.selected = nil
        textEdited = false
        let count = results.reduce(0) { $0 + $1.paragraphs.count }
        if text.isEmpty {
            translateSpinner.stopAnimation(nil); progressLabel.stringValue = ""
            ocrStatus.stringValue = ""
            showNotice("Текст не найден. Попробуйте снять страницу ближе, ровнее и при хорошем освещении.")
            updateButtons()
            return
        }
        ocrStatus.stringValue = "\(count) \(Self.plural(count, "абзац", "абзаца", "абзацев"))"
        updateButtons()
        view.window?.makeFirstResponder(view)
        startTranslation()
    }

    private func selectParagraph(_ index: Int) {
        guard !textEdited, currentPage < paragraphRanges.count, index < paragraphRanges[currentPage].count else { return }
        let range = paragraphRanges[currentPage][index]
        sourceView.setSelectedRange(range)
        sourceView.scrollRangeToVisible(range)
        sourceView.showFindIndicator(for: range)
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === sourceView else { return }
        if !textEdited {
            textEdited = true
            preview.onClickBox = nil
            preview.selected = nil
        }
        updateButtons()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard (notification.object as? NSTextView) === sourceView, !textEdited,
              sourceView.window?.firstResponder === sourceView,
              currentPage < paragraphRanges.count else { return }
        let loc = sourceView.selectedRange().location
        preview.selected = paragraphRanges[currentPage].firstIndex { NSLocationInRange(loc, $0) || loc == NSMaxRange($0) }
    }

    // MARK: - Translation

    private var selectedTarget: Language? {
        (targetPopup.selectedItem?.representedObject as? String).flatMap(Language.init(rawValue:))
    }

    private func startTranslation() {
        let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, ocrTask == nil else { return }
        hideNotice()
        setTranslation("")
        providerBadge.text = ""
        translateSpinner.startAnimation(nil)
        translator.start(text: text, target: selectedTarget)
        updateButtons()
    }

    private func handleTranslation(_ u: ChunkedTranslator.Update) {
        switch u {
        case let .started(provider, source, target):
            providerBadge.text = UIText.providerName(provider)
            providerBadge.tint = UIText.isFallbackProvider(provider) ? .systemOrange : .secondaryLabelColor
            providerBadge.toolTip = "\(UIText.capitalized(source)) → \(target.russianName)"
        case let .text(s):
            setTranslation(s)
        case let .progress(index, total):
            progressLabel.stringValue = total > 1 ? "часть \(index + 1) из \(total)" : ""
        case let .fellBack(from, _):
            showNotice(UIText.fallbackSwitching(from: from), color: .systemOrange)
        case .finished:
            translateSpinner.stopAnimation(nil)
            progressLabel.stringValue = ""
        case let .failed(message):
            translateSpinner.stopAnimation(nil)
            progressLabel.stringValue = ""
            showNotice(message)
        }
        updateButtons()
    }

    private func setTranslation(_ s: String) {
        let atEnd = translationView.visibleRect.maxY >= translationView.bounds.maxY - 30
        translationView.string = s
        translationPlaceholder.isHidden = !s.isEmpty
        if atEnd, translator.isRunning, translationView.bounds.height > (translationView.enclosingScrollView?.contentSize.height ?? 0) {
            translationView.scrollToEndOfDocument(nil)
        }
    }

    private func updateButtons() {
        let hasText = !(sourceView?.string.isEmpty ?? true)
        copyTextButton?.isEnabled = hasText
        copyTranslationButton?.isEnabled = !translator.translation.isEmpty
        retranslateButton?.isEnabled = hasText && ocrTask == nil
        retranslateButton?.title = translator.isRunning ? "Заново" : "Перевести"
        retranslateButton?.bezelColor = textEdited && !translator.isRunning ? .controlAccentColor : nil
        retranslateButton?.contentTintColor = textEdited && !translator.isRunning ? .white : nil
    }

    // MARK: - Notices

    private func showNotice(_ text: String, color: NSColor = .systemOrange) {
        noticeLabel.stringValue = text
        noticeLabel.textColor = color
        noticeLabel.isHidden = false
        if contentView.isHidden, !text.isEmpty, color == .systemOrange {
            // Errors before anything is loaded (bad file): show as a toast-like alert sheet.
            let alert = NSAlert()
            alert.messageText = text
            alert.addButton(withTitle: "OK")
            if let w = view.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
        }
    }

    private func hideNotice() { noticeLabel.isHidden = true; noticeLabel.stringValue = "" }

    // MARK: - Words

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    static func pagesWord(_ n: Int) -> String { "\(n) \(plural(n, "страница", "страницы", "страниц"))" }
}
