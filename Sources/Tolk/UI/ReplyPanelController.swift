// «Ответ»: reply to a partner's message without leaving one small window.
// Top: the partner's message (translation; original on demand). Below: the user writes in their language,
// the reply is translated live into the partner's language with the partner's message as context.
// «Вставить ⌘↩» returns to the chat app and pastes the reply (never sends it).
import AppKit
import TolkCore

/// What the popup hands over when the user presses «Ответить».
struct ReplyContext {
    var partnerText: String          // original message
    var partnerTranslation: String   // its translation (user's language)
    var partnerLanguage: Language    // reply goes into this language
    var app: NSRunningApplication?   // where to paste
    var anchor: NSPoint              // screen point to place the window near
}

@MainActor
final class ReplyPanelController: NSObject, NSTextViewDelegate {
    private(set) var engine: TranslationEngine
    var toneForApp: ((String?) -> Tone)?

    private let width: CGFloat = 470
    private let inset: CGFloat = 16

    private var panel: PopupPanel!
    private var runner: TranslationRunner
    private var context: ReplyContext?
    private var translation = ""
    private var debounce: DispatchWorkItem?
    private var monitors: [Any] = []
    private var drafts: [String: String] = [:]   // partner text -> unsent draft (survives an accidental close)

    // Views
    private var titleLabel: NSTextField!
    /// Partner's message, full length; scrolls when long (height capped so the window stays compact).
    private var partnerView: NSTextView!
    private var partnerScroll: NSScrollView!
    private var partnerHeight: NSLayoutConstraint!
    private var originalButton: NSButton!
    private var showOriginal = false
    private var inputView: ReplyInputView!
    private var inputHeight: NSLayoutConstraint!
    private var outputLabel: NSTextField!
    private var outputBox: NSView!
    private var spinner: NSProgressIndicator!
    private var toneControl: NSSegmentedControl!
    private var copyButton: NSButton!
    private var insertButton: NSButton!
    private var tone: Tone = .auto

    init(engine: TranslationEngine) {
        self.engine = engine
        self.runner = TranslationRunner(engine: engine)
        super.init()
        runner.onUpdate = { [weak self] in self?.handle($0) }
    }

    func replaceEngine(_ new: TranslationEngine) {
        runner.cancel()
        engine = new
        runner = TranslationRunner(engine: new)
        runner.onUpdate = { [weak self] in self?.handle($0) }
    }

    var window: NSWindow? { panel }
    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Show / hide

    func show(_ ctx: ReplyContext) {
        build()
        context = ctx
        let appName = ctx.app?.localizedName ?? "чат"
        titleLabel.stringValue = "Ответ · \(appName) · \(ctx.partnerLanguage.flag) \(UIText.capitalized(ctx.partnerLanguage))"
        setOriginalVisible(false)
        tone = toneForApp?(ctx.app?.bundleIdentifier) ?? .auto
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: tone) ?? 0

        inputView.string = drafts[ctx.partnerText] ?? ""
        translation = ""
        setOutput("", placeholder: true)
        if !inputView.string.isEmpty { scheduleTranslation(delay: 0) }

        place(near: ctx.anchor)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.14; panel.animator().alphaValue = 1 }
        panel.makeKey()
        panel.makeFirstResponder(inputView)
        installMonitors()
        Diagnostics.log("reply opened (\(appName), \(ctx.partnerLanguage.rawValue))")
    }

    func close() {
        runner.cancel()
        debounce?.cancel()
        removeMonitors()
        if let ctx = context { drafts[ctx.partnerText] = inputView.string }
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.1; panel.animator().alphaValue = 0 },
                                            completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil); panel.alphaValue = 1 } })
    }

    // MARK: - Translation

    func textDidChange(_ notification: Notification) {
        updateInputHeight()
        scheduleTranslation(delay: 0.45)
    }

    private func scheduleTranslation(delay: TimeInterval) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.translateNow() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func translateNow() {
        guard let ctx = context else { return }
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        runner.cancel()
        guard !text.isEmpty else { translation = ""; setOutput("", placeholder: true); updateButtons(); return }
        spinner.startAnimation(nil)
        // Keep the previous translation, dimmed, until the new one starts.
        if !translation.isEmpty { outputLabel.textColor = .tertiaryLabelColor }
        pendingFirstChunk = true
        runner.start(TranslationRequest(text: text, target: ctx.partnerLanguage, tone: tone, replyTo: ctx.partnerText))
    }

    private var pendingFirstChunk = false

    private func handle(_ u: TranslationRunner.Update) {
        switch u {
        case .started, .fellBack:
            break
        case let .delta(chunk):
            if pendingFirstChunk { translation = ""; pendingFirstChunk = false }
            translation += chunk
            setOutput(translation, placeholder: false)
        case .finished:
            spinner.stopAnimation(nil)
        case let .failed(message):
            spinner.stopAnimation(nil)
            setOutput(message, placeholder: false, color: .systemRed)
        }
        updateButtons()
    }

    private func setOutput(_ text: String, placeholder: Bool, color: NSColor = .labelColor) {
        if placeholder {
            outputLabel.stringValue = "Здесь появится перевод ответа"
            outputLabel.textColor = .tertiaryLabelColor
        } else {
            outputLabel.stringValue = text
            outputLabel.textColor = color
        }
        resize()
    }

    private func updateButtons() {
        let ready = !translation.isEmpty && !pendingFirstChunk
        copyButton.isEnabled = ready
        insertButton.isEnabled = ready && context?.app != nil
    }

    // MARK: - Actions

    @objc private func toneChanged(_ sender: NSSegmentedControl) {
        tone = Tone.allCases[max(0, sender.selectedSegment)]
        scheduleTranslation(delay: 0)
    }

    @objc private func toggleOriginal() { setOriginalVisible(!showOriginal) }

    /// Fills the partner area: the translation, and the original under it when asked.
    private func setOriginalVisible(_ visible: Bool) {
        showOriginal = visible
        originalButton.title = visible ? "Скрыть оригинал" : "Оригинал"
        guard let ctx = context, let storage = partnerView.textStorage else { return }
        let text = NSMutableAttributedString(
            string: ctx.partnerTranslation.trimmingCharacters(in: .whitespacesAndNewlines),
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        if visible {
            text.append(NSAttributedString(
                string: "\n\n" + ctx.partnerText.trimmingCharacters(in: .whitespacesAndNewlines),
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        storage.setAttributedString(text)
        updatePartnerHeight()
        partnerView.scrollToBeginningOfDocument(nil)
    }

    private func updatePartnerHeight() {
        panel.contentView?.layoutSubtreeIfNeeded() // the text width must be known before measuring
        guard let lm = partnerView.layoutManager, let tc = partnerView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height + partnerView.textContainerInset.height * 2)
        let screenCap = (NSScreen.main?.visibleFrame.height ?? 900) * 0.3
        let cap = min(240, screenCap)
        partnerHeight.constant = min(max(h, 20), cap)
        partnerScroll.hasVerticalScroller = h > cap
        resize()
    }

    @objc private func copyReply() {
        guard !translation.isEmpty else { return }
        Clipboard.copy(translation)
        copyButton.title = "Скопировано ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.title = "Копировать" }
    }

    /// Back to the chat app and ⌘V there. Never presses Enter — sending is the user's call.
    @objc private func insertReply() {
        guard !translation.isEmpty, let app = context?.app else { return }
        let text = translation
        Clipboard.copy(text)
        if let ctx = context { drafts[ctx.partnerText] = nil }
        inputView.string = ""
        close()
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down) // V
                e?.flags = .maskCommand
                e?.setIntegerValueField(.eventSourceUserData, value: DoubleCopyMonitor.syntheticMarker)
                e?.post(tap: .cghidEventTap)
            }
        }
        Diagnostics.log("reply inserted into \(app.localizedName ?? "?")")
    }

    @objc private func closeClicked() { close() }

    // MARK: - Keys (Esc closes, ⌘↩ inserts)

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            if e.keyCode == 53 { self.close(); return nil }
            if e.keyCode == 36, e.modifierFlags.contains(.command) { self.insertReply(); return nil }
            return e
        }) { monitors.append(m) }
    }

    private func removeMonitors() { monitors.forEach(NSEvent.removeMonitor); monitors.removeAll() }

    // MARK: - Layout

    private func updateInputHeight() {
        guard let lm = inputView.layoutManager, let tc = inputView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height + inputView.textContainerInset.height * 2)
        inputHeight.constant = min(max(h, 56), 150)
        resize()
    }

    private func resize() {
        guard let panel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let h = ceil(content.fittingSize.height)
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        f.origin.y = f.maxY - h // grow downwards, top edge stays
        f.size.height = h
        panel.setFrame(clampToScreen(f), display: true, animate: panel.isVisible)
    }

    private func place(near p: NSPoint) {
        guard let content = panel.contentView else { return }
        panel.setContentSize(NSSize(width: width, height: 200))
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: ceil(content.fittingSize.height))
        panel.setFrame(clampToScreen(NSRect(x: p.x - 24, y: p.y - 18 - size.height, width: size.width, height: size.height)),
                       display: true)
    }

    private func clampToScreen(_ r: NSRect) -> NSRect {
        let vf = (NSScreen.screens.first { NSMouseInRect(NSPoint(x: r.midX, y: r.maxY), $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? r
        var r = r
        r.origin.x = min(max(r.minX, vf.minX + 8), vf.maxX - r.width - 8)
        if r.minY < vf.minY + 8 { r.origin.y = vf.minY + 8 }
        if r.maxY > vf.maxY - 8 { r.origin.y = vf.maxY - 8 - r.height }
        return r
    }

    private func build() {
        guard panel == nil else { return }
        let p = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        panel = p

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        p.contentView = effect

        // Header
        titleLabel = UIFactory.label("Ответ", size: 12, weight: .semibold, color: .secondaryLabelColor)
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        let close = UIFactory.symbolButton("xmark", tooltip: "Закрыть (Esc) — черновик сохранится", target: self, action: #selector(closeClicked))
        let header = NSStackView(views: [icon, titleLabel, UIFactory.spacer(), close])
        header.orientation = .horizontal
        header.spacing = 6

        // Partner's message: translation; original on demand
        partnerScroll = NSTextView.scrollableTextView()
        partnerScroll.drawsBackground = false
        partnerScroll.borderType = .noBorder
        partnerScroll.hasVerticalScroller = false
        partnerScroll.autohidesScrollers = true
        partnerScroll.scrollerStyle = .overlay
        partnerView = partnerScroll.documentView as? NSTextView
        partnerView.isEditable = false
        partnerView.isSelectable = true
        partnerView.drawsBackground = false
        partnerView.textContainerInset = .zero
        partnerView.textContainer?.lineFragmentPadding = 0
        partnerHeight = partnerScroll.heightAnchor.constraint(equalToConstant: 40)
        partnerHeight.isActive = true
        originalButton = NSButton(title: "Оригинал", target: self, action: #selector(toggleOriginal))
        originalButton.isBordered = false
        originalButton.font = .systemFont(ofSize: 11)
        originalButton.contentTintColor = .linkColor
        let partnerStack = NSStackView(views: [partnerScroll, originalButton])
        partnerStack.orientation = .vertical
        partnerStack.alignment = .leading
        partnerStack.spacing = 4
        partnerStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)
        // NSBox colours are dynamic: they follow light/dark switches (layer cgColors would not).
        let partner = Self.roundedBox(partnerStack, fill: .quaternarySystemFill, border: nil)

        // Input
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = ReplyInputView()
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.placeholder = "Ответ на своём языке…"
        tv.delegate = self
        scroll.documentView = tv
        inputView = tv
        let inputBox = Self.roundedBox(scroll, fill: .textBackgroundColor, border: .separatorColor)
        inputHeight = inputBox.heightAnchor.constraint(equalToConstant: 56)
        inputHeight.isActive = true

        // Output
        outputLabel = UIFactory.wrappingLabel("", size: 14, color: .labelColor)
        outputLabel.isSelectable = true
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let arrow = UIFactory.label("→", size: 14, color: .tertiaryLabelColor)
        let outputRow = NSStackView(views: [arrow, outputLabel, spinner])
        outputRow.orientation = .horizontal
        outputRow.alignment = .top
        outputRow.spacing = 6
        outputBox = outputRow

        // Footer
        toneControl = UIFactory.toneControl(target: self, action: #selector(toneChanged(_:)))
        toneControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyButton = NSButton(title: "Копировать", target: self, action: #selector(copyReply))
        insertButton = NSButton(title: "Вставить в чат  ⌘↩", target: self, action: #selector(insertReply))
        insertButton.keyEquivalent = "\r"
        insertButton.keyEquivalentModifierMask = .command
        insertButton.toolTip = "Вернуться в чат и вставить ответ (отправите сами)"
        for b in [copyButton!, insertButton!] {
            b.bezelStyle = .push
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let footer = NSStackView(views: [toneControl, UIFactory.spacer(), copyButton, insertButton])
        footer.orientation = .horizontal
        footer.spacing = 6

        let root = NSStackView(views: [header, partner, inputBox, outputRow, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: inset, bottom: 12, right: inset)
        root.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            effect.widthAnchor.constraint(equalToConstant: width),
        ])
        for v in [header, partner, inputBox, outputRow, footer] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -inset * 2).isActive = true
        }
        partnerScroll.widthAnchor.constraint(equalToConstant: width - inset * 2 - 24).isActive = true
        outputLabel.preferredMaxLayoutWidth = width - inset * 2 - 40
        updateButtons()
    }

    /// Rounded container with dynamic (theme-following) fill and border.
    private static func roundedBox(_ content: NSView, fill: NSColor, border: NSColor?) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.fillColor = fill
        box.borderColor = border ?? .clear
        box.borderWidth = border == nil ? 0 : 1
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 2),
                content.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -2),
                content.topAnchor.constraint(equalTo: cv.topAnchor, constant: 1),
                content.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -1),
            ])
        }
        return box
    }

    #if DEBUG
    /// Dev: render the window to PNG (no screen-recording permission needed).
    func renderForReview(_ ctx: ReplyContext, reply: String, translated: String, to path: String) {
        show(ctx)
        inputView.string = reply
        updateInputHeight()
        runner.cancel(); debounce?.cancel()
        translation = translated
        pendingFirstChunk = false
        setOutput(translated, placeholder: false)
        updateButtons()
        panel.contentView?.layoutSubtreeIfNeeded()
        resize()
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}

/// Text view with a placeholder.
final class ReplyInputView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let o = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: o, withAttributes: [.font: font ?? .systemFont(ofSize: 14),
                                                               .foregroundColor: NSColor.placeholderTextColor])
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditShortcuts.handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
