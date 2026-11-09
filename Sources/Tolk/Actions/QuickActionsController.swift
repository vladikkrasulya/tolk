// Owned by the "quick actions" session.
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
    /// Posted after a hotkey changes (`setHotKey`, `resetHotKeys`) — the settings page can refresh.
    static let hotKeysDidChange = Notification.Name("TolkQuickActionsHotKeysDidChange")

    let actions = QuickAction.all
    private(set) var engine: TranslationEngine
    private(set) var config: TolkConfig
    /// Max seconds for one action (grab + model + paste).
    var timeout: TimeInterval = 60

    private let hotKeys = HotKeyCenter()
    private var store = QuickActionHotKeyStore()
    private let hud = QuickActionHUD()
    private var tokens: [String: UInt32] = [:]
    private var escToken: UInt32?
    private var started = false

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
    @discardableResult func start() -> Bool {
        started = true
        return registerAll()
    }

    func stop() {
        cancel()
        hotKeys.unregisterAll()
        tokens.removeAll()
        escToken = nil
        started = false
    }

    /// Call after the config changes (the app rebuilds the engine).
    func update(engine: TranslationEngine, config: TolkConfig) {
        self.engine = engine
        self.config = config
    }

    // MARK: - Hotkey API (for the settings page)

    func hotKey(for action: QuickAction) -> HotKeyCombo? { store.hotKey(for: action) }

    /// nil = disable. Returns false (and keeps the old shortcut) if the combo is used by
    /// another quick action or cannot be registered (taken system-wide).
    @discardableResult func setHotKey(_ combo: HotKeyCombo?, for action: QuickAction) -> Bool {
        if let combo, actions.contains(where: { $0 != action && hotKey(for: $0) == combo }) { return false }
        let old = hotKey(for: action)
        store.set(combo, for: action)
        guard started else { notifyChange(); return true }
        if registerOne(action) { notifyChange(); return true }
        store.set(old, for: action)
        _ = registerOne(action)
        return false
    }

    func resetHotKeys() {
        store.reset()
        if started { _ = registerAll() }
        notifyChange()
    }

    /// Ids of actions whose shortcut is configured but not registered (conflict) — to warn in settings.
    var failedActions: [QuickAction] {
        actions.filter { hotKey(for: $0) != nil && tokens[$0.id] == nil }
    }

    private func notifyChange() { NotificationCenter.default.post(name: Self.hotKeysDidChange, object: self) }

    private func registerAll() -> Bool {
        actions.reduce(true) { ok, a in registerOne(a) && ok }
    }

    private func registerOne(_ action: QuickAction) -> Bool {
        if let t = tokens.removeValue(forKey: action.id) { hotKeys.unregister(t) }
        guard let combo = hotKey(for: action) else { return true } // disabled
        guard let t = hotKeys.register(combo, handler: { [weak self] in self?.perform(action) }) else { return false }
        tokens[action.id] = t
        return true
    }

    // MARK: - Running

    /// Runs an action on the current selection (hotkey, or a menu item).
    func perform(_ action: QuickAction) {
        guard !isBusy else { hud.showMessage(QuickActionText.busy, kind: .info, at: NSEvent.mouseLocation); return }
        let mouse = NSEvent.mouseLocation
        guard AXIsProcessTrusted() else { hud.showMessage(QuickActionText.noAccessibility, kind: .error, at: mouse); return }
        let app = NSWorkspace.shared.frontmostApplication
        let tone = config.tone(forApp: app?.bundleIdentifier)

        isBusy = true
        pasting = false
        timedOut = false
        registerEsc()
        hud.showProgress(QuickActionText.progress(verb: action.progressVerb, provider: nil, tone: tone), at: mouse)

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
            hud.showMessage(QuickActionText.noSelection, kind: .info); return
        }
        if Task.isCancelled { return cancelled() }

        // 3. Model.
        let result: CollectedText
        do {
            result = try await TextCollector.collect(engine.translate(action.request(text: selected, tone: tone))) { [weak self] event in
                guard let self else { return }
                switch event {
                case let .started(provider, _, _):
                    let text = UIText.isFallbackProvider(provider)
                        ? QuickActionText.fallback(verb: action.progressVerb, provider: provider, tone: tone)
                        : QuickActionText.progress(verb: action.progressVerb, provider: provider, tone: tone)
                    self.hud.update(text)
                default: break
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return cancelled() }
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
            hud.showMessage(QuickActionText.appChanged, kind: .error); return
        }

        // 4. Replace.
        pasting = true
        unregisterEsc()
        await paste(text)
        hud.showMessage(QuickActionText.done, kind: .success)
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
    private func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let before = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: .tolkTransient)
        pb.setData(Data(), forType: .tolkAutoGenerated)
        let ours = pb.changeCount
        KeySynth.paste()
        await sleepIgnoringCancel(0.5)
        if pb.changeCount == ours { before.restore(to: pb) }
    }

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
