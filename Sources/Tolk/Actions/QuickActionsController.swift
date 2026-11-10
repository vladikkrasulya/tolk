import AppKit
import Carbon.HIToolbox
import TolkCore

/// "Select text anywhere → hotkey → the text is replaced by its translation / polished version."
///
/// Flow of one action (`perform`):
///  1. remember the frontmost app (tone via `config.tone(forApp:)`), wait until ⌃⌥ are released;
///  2. snapshot the whole clipboard, synthetic ⌘C, wait for `changeCount`, read the text,
///     put the clipboard back right away (it stays the user's while the model works);
///  3. stream the engine (Google fallback only for translate), Esc / timeout cancel → nothing pasted;
///  4. if the same app is still frontmost: clipboard = result, synthetic ⌘V, restore the clipboard
///     after 0.5 s (unless something else wrote to it meanwhile). ⌘Z in the app undoes the replace.
@MainActor
final class QuickActionsController {
    let actions = QuickAction.all
    private(set) var engine: TranslationEngine
    private(set) var config: TolkConfig
    /// Max seconds for one action (grab + model + paste).
    var timeout: TimeInterval = 150 // a cold 26B model on CPU needs ~1 min just to load

    private let hotKeys = HotKeyCenter()
    private let store = QuickActionHotKeyStore()
    private let hud = QuickActionHUD()
    private var tokens: [String: UInt32] = [:]
    private var escToken: UInt32?

    private var run: Task<Void, Never>?
    private(set) var isBusy = false
    /// Once the paste began, Esc no longer cancels (the clipboard must be put back).
    private var pasting = false
    private var timedOut = false

    init(engine: TranslationEngine, config: TolkConfig) {
        self.engine = engine
        self.config = config
    }

    // MARK: - Lifecycle

    /// Registers all hotkeys. Returns false if any of them could not be registered
    /// (taken by another app); the others still work.
    @discardableResult func start() -> Bool { registerAll() }

    /// Call after the config changes (the app rebuilds the engine).
    func update(engine: TranslationEngine, config: TolkConfig) {
        self.engine = engine
        self.config = config
    }

    // MARK: - Hotkey API (for the settings page)

    func hotKey(for action: QuickAction) -> HotKeyCombo? { store.hotKey(for: action) }

    /// Ids of actions whose shortcut is configured but not registered (conflict) — to warn in settings.
    var failedActions: [QuickAction] {
        actions.filter { hotKey(for: $0) != nil && tokens[$0.id] == nil }
    }

    /// After the user changed a shortcut in settings.
    @discardableResult func reregister() -> Bool { registerAll() }

    private func registerAll() -> Bool {
        actions.reduce(true) { ok, a in registerOne(a) && ok }
    }

    private func registerOne(_ action: QuickAction) -> Bool {
        if let t = tokens.removeValue(forKey: action.id) { hotKeys.unregister(t) }
        QuickActionHotKeyStore.failedIDs.remove(action.id)
        guard let combo = hotKey(for: action) else { return true } // disabled
        guard let t = hotKeys.register(combo, handler: { [weak self] in self?.perform(action) }) else {
            QuickActionHotKeyStore.failedIDs.insert(action.id)
            return false
        }
        tokens[action.id] = t
        return true
    }

    // MARK: - Running

    /// Runs an action on the current selection (hotkey, or a menu item).
    /// Called right before an action grabs the selection (the app hides the translation popup here).
    var onWillPerform: (() -> Void)?

    func perform(_ action: QuickAction) {
        onWillPerform?()
        guard !isBusy else { hud.showMessage(QuickActionText.busy, kind: .info, at: NSEvent.mouseLocation); return }
        let mouse = NSEvent.mouseLocation
        guard AXIsProcessTrusted() else { hud.showMessage(QuickActionText.noAccessibility, kind: .error, at: mouse); return }
        let app = NSWorkspace.shared.frontmostApplication
        let tone = config.tone(forApp: app?.bundleIdentifier)

        isBusy = true
        pasting = false
        timedOut = false
        registerEsc()
        hud.showProgress(action.isLayoutFix ? QuickActionText.fixingLayout
                         : QuickActionText.progress(verb: action.progressVerb, provider: nil, tone: tone), at: mouse)

        let limit = timeout
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isBusy, !self.pasting else { return }
            self.timedOut = true
            self.run?.cancel()
        }
        run = Task { @MainActor [weak self] in
            await self?.execute(action, tone: tone, app: app)
            timer.cancel()
            self?.finish()
        }
    }

    /// Esc: stops the model, nothing is pasted, the clipboard is the user's.
    func cancel() {
        guard isBusy, !pasting else { return }
        run?.cancel()
    }

    private func finish() {
        unregisterEsc()
        run = nil
        isBusy = false
        pasting = false
    }

    private func execute(_ action: QuickAction, tone: Tone, app: NSRunningApplication?) async {
        // 1–2. Selection.
        await KeySynth.waitForModifiersReleased()
        if Task.isCancelled { return cancelled() }
        guard let selected = await grabSelection() else {
            if Task.isCancelled { return cancelled() }
            Diagnostics.log("quick \(action.id): no selection")
            hud.showMessage(QuickActionText.noSelection, kind: .info); return
        }
        Diagnostics.log("quick \(action.id): \(selected.count) chars selected in \(app?.bundleIdentifier ?? "?")")
        if Task.isCancelled { return cancelled() }

        // Wrong keyboard layout: no model, the answer is instant.
        if action.isLayoutFix { return await executeLayoutFix(selected, app: app, id: action.id) }

        // 3. Model. While the first word has not arrived, show how long the (maybe cold) model has been loading.
        let waitStart = Date()
        var gotText = false
        var hudBase = QuickActionText.progress(verb: action.progressVerb, provider: nil, tone: tone)
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !gotText else { return }
                let n = Int(Date().timeIntervalSince(waitStart))
                if n >= 4 { self?.hud.update(QuickActionText.loading(hudBase, seconds: n)) }
            }
        }
        defer { ticker.cancel() }
        let result: CollectedText
        do {
            result = try await TextCollector.collect(engine.translate(action.request(text: selected, tone: tone))) { [weak self] event in
                guard let self else { return }
                switch event {
                case let .started(provider, _, _):
                    let text = UIText.isFallbackProvider(provider)
                        ? QuickActionText.fallback(verb: action.progressVerb, provider: provider, tone: tone)
                        : QuickActionText.progress(verb: action.progressVerb, provider: provider, tone: tone)
                    hudBase = text
                    self.hud.update(text)
                case .delta: gotText = true
                default: break
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return cancelled() }
            Diagnostics.log("quick \(action.id): failed: \(error.localizedDescription)")
            if action.needsQwen, error is TolkError { hud.showMessage(QuickActionText.qwenDown, kind: .error); return }
            hud.showMessage(UIText.errorMessage(error), kind: .error); return
        }
        if Task.isCancelled { return cancelled() }

        let text = TextCollector.reapplyWhitespace(of: selected, to: result.text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hud.showMessage(QuickActionText.empty, kind: .error); return
        }
        // The user may have switched apps while waiting — never paste into the wrong window.
        if let app, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            // Do not lose a minute of model work: leave the result on the clipboard.
            leaveOnClipboard(text)
            hud.showMessage(QuickActionText.appChanged, kind: .error); return
        }
        // Read-only field (static text, locked text view): ⌘V would do nothing but we would say "Готово".
        if FocusProbe.focusedFieldIsReadOnly() {
            Diagnostics.log("quick \(action.id): focused field is read-only — result left on the clipboard")
            leaveOnClipboard(text)
            hud.showMessage(QuickActionText.readOnly, kind: .info); return
        }

        // 4. Replace.
        Diagnostics.log("quick \(action.id): \(result.provider) → \(text.count) chars, pasting")
        pasting = true
        unregisterEsc()
        await paste(text)
        hud.showMessage(QuickActionText.done, kind: .success)
    }

    private func executeLayoutFix(_ selected: String, app: NSRunningApplication?, id: String) async {
        let result = LayoutFix.fix(selected, oracle: SpellCheckOracle.shared)
        Diagnostics.log("quick \(id): \(result.changedWords) words fixed\(result.ukrainian ? " (uk)" : "")")
        guard result.changed else { hud.showMessage(QuickActionText.layoutAlreadyOK, kind: .info); return }
        if let app, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            leaveOnClipboard(result.text)
            hud.showMessage(QuickActionText.appChanged, kind: .error); return
        }
        if FocusProbe.focusedFieldIsReadOnly() {
            leaveOnClipboard(result.text)
            hud.showMessage(QuickActionText.readOnly, kind: .info); return
        }
        pasting = true
        unregisterEsc()
        await paste(result.text)
        hud.showMessage(QuickActionText.layoutFixed(words: result.changedWords), kind: .success)
    }

    private func leaveOnClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func cancelled() {
        if timedOut { hud.showMessage(QuickActionText.timeout(Int(timeout)), kind: .error) } else { hud.hide() }
    }

    /// Synthetic ⌘C. Restores the clipboard before returning (also when cancelled).
    /// nil = nothing selected (the app did not write to the clipboard) or no text in it.
    private func grabSelection() async -> String? {
        let pb = NSPasteboard.general
        let original = PasteboardSnapshot.capture(pb)
        let before = pb.changeCount
        KeySynth.copy()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        while pb.changeCount == before, ProcessInfo.processInfo.systemUptime < deadline {
            await sleepIgnoringCancel(0.02)
        }
        guard pb.changeCount != before else { return nil } // untouched — nothing to restore
        await sleepIgnoringCancel(0.03) // some apps write several types one after another
        let text = pb.string(forType: .string)
        original.restore(to: pb)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Clipboard = text, ⌘V, then put back whatever was there right before (if nobody wrote meanwhile).
    private func paste(_ text: String) async { await ClipboardPaste.paste(text) }

    // Esc as a temporary Carbon hotkey: works without focus and is swallowed (Slack won't close the composer).
    private func registerEsc() {
        guard escToken == nil else { return }
        escToken = hotKeys.register(HotKeyCombo(keyCode: UInt32(kVK_Escape), modifiers: 0)) { [weak self] in self?.cancel() }
    }

    private func unregisterEsc() {
        if let t = escToken { hotKeys.unregister(t) }
        escToken = nil
    }
}
