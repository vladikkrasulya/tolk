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
    private var statusLine: StatusLineView!
    private var context: ReplyContext?
    private var translation = ""
    /// Earlier lines of this chat (ThreadMemory, same app) — context for pronouns and terms, never translated.
    /// Fixed while the window is open, so live typing does not change the request.
    private var threadContext: String?
    private var debounce: DispatchWorkItem?
    private var monitors: [Any] = []
    private var presentGeneration = 0
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
    private var spinner: NSProgressIndicator!
    private var toneControl: NSSegmentedControl!
    private var copyButton: NSButton!
    private var insertButton: NSButton!
    private var tone: Tone = .auto

    // Live typing: sentence cache + the current request's plan.
    private let live = LiveTranslation()
    private var step: LiveTranslation.Step?
    private var keptPrefix = ""
    private var tail = ""
    private var detected: (source: Language, target: Language)?
    // Editor pass
    private let refiner = RefineRunner()
    private var refineButton: NSButton!
    private var beforeRefine: String?
    private var configObserver: NSObjectProtocol?

    init(engine: TranslationEngine) {
        self.engine = engine
        self.runner = TranslationRunner(engine: engine)
        super.init()
        runner.onUpdate = { [weak self] in self?.handle($0) }
        runner.onStats = { [weak self] in self?.statusLine?.finished($0) }
        configObserver = NotificationCenter.default.addObserver(forName: TolkConfig.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.live.reset() }
        }
    }

    deinit { if let o = configObserver { NotificationCenter.default.removeObserver(o) } }

    func replaceEngine(_ new: TranslationEngine) {
        runner.cancel()
        live.reset()
        engine = new
        runner = TranslationRunner(engine: new)
        runner.onUpdate = { [weak self] in self?.handle($0) }
        runner.onStats = { [weak self] in self?.statusLine?.finished($0) }
    }

    var window: NSWindow? { panel }

    // MARK: - Show / hide

    func show(_ ctx: ReplyContext) {
        presentGeneration += 1 // a fade-out of the previous close must not hide this window
        build()
        context = ctx
        // The partner's message itself is `replyTo`; `turns(for:)` leaves it out and gives the lines before it.
        threadContext = ThreadMemory.shared.context(for: ctx.partnerText, app: ctx.app?.bundleIdentifier)
        let appName = ctx.app?.localizedName ?? "чат"
        titleLabel.stringValue = "Ответ · \(appName) · \(ctx.partnerLanguage.flag) \(UIText.capitalized(ctx.partnerLanguage))"
        setOriginalVisible(false)
        tone = toneForApp?(ctx.app?.bundleIdentifier) ?? .auto
        toneControl.selectedSegment = Tone.allCases.firstIndex(of: tone) ?? 0

        inputView.string = drafts[ctx.partnerText] ?? ""
        translation = ""
        live.reset(); step = nil; resetRefine()
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
        refiner.cancel()
        debounce?.cancel()
        removeMonitors()
        spinner?.stopAnimation(nil)
        statusLine?.reset() // no "model is loading" counter ticking behind a hidden window
        if let ctx = context {
            drafts[ctx.partnerText] = inputView.string.isEmpty ? nil : inputView.string
            if drafts.count > 20 { drafts = drafts.filter { $0.key == ctx.partnerText } } // keep memory bounded
        }
        guard let panel, panel.isVisible else { return }
        presentGeneration += 1
        let generation = presentGeneration
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.1; panel.animator().alphaValue = 0 },
                                            completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.presentGeneration == generation else { return }
                panel.orderOut(nil); panel.alphaValue = 1
            }
        })
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
        let wasRunning = runner.isRunning
        runner.cancel()
        resetRefine()
        guard !text.isEmpty else {
            live.reset(); step = nil
            translation = ""; setOutput("", placeholder: true); spinner.stopAnimation(nil); updateButtons(); return
        }
        let key = LiveTranslation.key(source: nil, target: ctx.partnerLanguage, tone: tone, mode: .translate,
                                      config: TolkConfig.load(), replyTo: ctx.partnerText)
        let st = live.prepare(text: text, source: nil, target: ctx.partnerLanguage, tone: tone,
                              replyTo: ctx.partnerText, key: key)
        Diagnostics.log(st.logLine)
        step = st
        keptPrefix = st.kind == .partial ? st.kept : ""
        tail = ""
        guard var request = st.request else {
            // Nothing meaningful changed: the shown translation must equal the kept one.
            if wasRunning { statusLine?.reset() }
            spinner.stopAnimation(nil)
            pendingFirstChunk = false
            translation = st.kept
            setOutput(st.kept, placeholder: st.kept.isEmpty)
            updateButtons()
            return
        }
        spinner.startAnimation(nil)
        pendingFirstChunk = true
        if st.kind == .partial {
            // The kept part stays on screen, undimmed; the tail streams in after it.
            translation = st.kept
            setOutput(st.kept, placeholder: false)
        } else if !translation.isEmpty {
            // Keep the previous translation, dimmed, until the new one starts.
            outputLabel.textColor = .tertiaryLabelColor
        }
        statusLine?.waiting(provider: "…")
        request.threadContext = threadContext
        runner.start(request)
    }

    /// The reply the user takes (copy / paste) becomes a line of the chat for the next message.
    private func rememberReply() {
        guard let ctx = context, !translation.isEmpty else { return }
        ThreadMemory.shared.record(source: inputView.string, translation: translation,
                                   from: detected?.source ?? .russian, to: ctx.partnerLanguage,
                                   app: ctx.app?.bundleIdentifier)
    }

    private var pendingFirstChunk = false

    private func handle(_ u: TranslationRunner.Update) {
        switch u {
        case let .started(provider, source, target):
            statusLine?.waiting(provider: provider)
            live.started(source: source, target: target)
            detected = (source, target)
        case let .fellBack(_, reason):
            statusLine?.fellBack(reason: reason)
            // Only the streamed tail goes; the kept part stays.
            tail = ""
            translation = keptPrefix
            pendingFirstChunk = true
            if !keptPrefix.isEmpty { setOutput(keptPrefix, placeholder: false) }
        case let .delta(chunk):
            statusLine?.chunk()
            if pendingFirstChunk { pendingFirstChunk = false; tail = "" }
            tail += chunk
            translation = keptPrefix + tail
            setOutput(translation, placeholder: false)
        case .finished:
            spinner.stopAnimation(nil)
            if let st = step, !tail.isEmpty { live.commit(st, tail: tail) }
        case let .failed(message):
            statusLine?.failed(message)
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
        refineButton.isEnabled = ready && !runner.isRunning && !refiner.isRunning
        copyButton.isEnabled = ready
        insertButton.isEnabled = ready && context?.app != nil
    }

    // MARK: - Actions

    @objc private func toneChanged(_ sender: NSSegmentedControl) {
        tone = Tone.allCases[max(0, sender.selectedSegment)]
        live.reset()
        scheduleTranslation(delay: 0)
    }

    // MARK: - Editor pass

    private func resetRefine() {
        refiner.cancel()
        beforeRefine = nil
        refineButton?.title = "Отредактировать"
    }

    @objc private func refineClicked() {
        if let old = beforeRefine {   // «Вернуть»
            beforeRefine = nil
            translation = old
            setOutput(old, placeholder: false)
            refineButton.title = "Отредактировать"
            live.reset()
            updateButtons()
            return
        }
        guard let ctx = context, !translation.isEmpty, !pendingFirstChunk, !runner.isRunning else { return }
        let source = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = translation
        let from = detected?.source ?? .russian
        var refined = ""
        spinner.startAnimation(nil)
        refineButton.isEnabled = false
        live.reset()
        refiner.start(engine: engine, source: source, translation: old, from: from, to: ctx.partnerLanguage, tone: tone,
                      onDelta: { [weak self] chunk in
            guard let self else { return }
            refined += chunk
            self.translation = refined
            self.setOutput(refined, placeholder: false)
        }, onDone: { [weak self] in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            let t = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == old.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.translation = old; self.setOutput(old, placeholder: false)
            } else {
                self.beforeRefine = old
                self.refineButton.title = "Вернуть"
            }
            self.updateButtons()
        }, onFail: { [weak self] message in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.translation = old; self.setOutput(old, placeholder: false)
            self.statusLine?.failed(message)
            self.updateButtons()
        })
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
        rememberReply()
        Clipboard.copy(translation)
        copyButton.title = "Скопировано"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.title = "Копировать" }
    }

    /// Back to the chat app and ⌘V there. Never presses Enter — sending is the user's call.
    @objc private func insertReply() {
        guard !translation.isEmpty, let app = context?.app else { return }
        let text = translation
        rememberReply()
        Clipboard.copy(text)
        if let ctx = context { drafts[ctx.partnerText] = nil }
        inputView.string = ""
        close()
        app.activate()
        // Paste only once the chat app really is frontmost (activation can take longer than a fixed delay).
        let deadline = Date().addingTimeInterval(1.5)
        func pasteWhenFront() {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: pasteWhenFront); return
            }
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down) // V
                e?.flags = .maskCommand
                e?.setIntegerValueField(.eventSourceUserData, value: DoubleCopyMonitor.syntheticMarker)
                e?.post(tap: .cghidEventTap)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: pasteWhenFront)
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
        let target = clampToScreen(f)
        if panel.isVisible, !runner.isRunning, !refiner.isRunning {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            // While tokens stream in, a new animation per token (the blocking AppKit `animate: true`) makes the window judder.
            panel.setFrame(target, display: true)
        }
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
        let close = UIFactory.symbolButton("xmark", tooltip: EscText.closeKeepingDraftTip, target: self, action: #selector(closeClicked))
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

        // Footer
        toneControl = UIFactory.toneControl(target: self, action: #selector(toneChanged(_:)))
        toneControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyButton = NSButton(title: "Копировать", target: self, action: #selector(copyReply))
        insertButton = NSButton(title: "Вставить в чат  ⌘↩", target: self, action: #selector(insertReply))
        insertButton.keyEquivalent = "\r"
        insertButton.keyEquivalentModifierMask = .command
        insertButton.toolTip = "Вернуться в чат и вставить ответ (отправите сами)"
        refineButton = NSButton(title: "Отредактировать", target: self, action: #selector(refineClicked))
        refineButton.toolTip = "Второй проход: убрать кальки, сохранить смысл"
        for b in [copyButton!, insertButton!, refineButton!] {
            b.bezelStyle = .push
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        refineButton.isEnabled = false
        refineButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [toneControl, UIFactory.spacer(), refineButton, copyButton, insertButton])
        footer.orientation = .horizontal
        footer.spacing = 6

        statusLine = StatusLineView()
        let root = NSStackView(views: [header, partner, inputBox, outputRow, statusLine, footer])
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
