// «Перевод при наборе»: the user types in their own language in a chat field, after a pause the whole text of the
// field is translated into the language of the partner's last message and shown under the field; Tab replaces the
// field's text with it (⌘Z of the app undoes it), Esc keeps the user's text. Tolk never presses Return.
//
// Keys come from the autocomplete event tap (`AutocompleteController.typeTranslate`); the pure rules are in
// `TolkCore/TypeTranslate.swift`. Nothing from the text is logged (only lengths and bundle ids), the model on
// vkbox is the only translator (no Google fallback), and when it is unreachable the line simply does not appear.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TolkCore

@MainActor
final class TypeTranslateController {
    enum KeyResult {
        case proceed              // not ours: autocomplete handles the key as usual
        case skipAutocomplete     // the mode is on here: autocomplete stays out of this app, the key goes to the app
        case swallow              // handled (Tab / Esc while the line is shown)
    }

    private(set) var config: TolkConfig
    private(set) var engine: TranslationEngine
    /// Saves the new per-app map (the app writes the config).
    var onToggle: (([String: Bool]) -> Void)?

    static let hotKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
    static let pause: TimeInterval = 0.5

    private let panel = TypeTranslatePanel()
    private let screen = ScreenContext()
    private let hotKeys = HotKeyCenter()
    private var hotKeyToken: UInt32?
    private var planner = TypeTranslate.DebouncePlanner(delay: pause)
    private var task: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// The translation on screen and what it was made for.
    private struct Shown {
        let snapshot: TypeTranslate.FieldSnapshot
        let element: AXUIElement?
        let translation: String
        let source: Language
        let target: Language
        /// Lost links/numbers/times found by the check: the first Tab only arms the insert.
        var warning: String? = nil
        var armed = false
    }
    private var shown: Shown?
    /// After Esc nothing is requested until the text changes again.
    private var suppressed = false
    private static let ownPID = ProcessInfo.processInfo.processIdentifier
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(engine: TranslationEngine, config: TolkConfig) {
        self.engine = engine
        self.config = config
    }

    // MARK: - Lifecycle

    @discardableResult func start() -> Bool {
        guard hotKeyToken == nil else { return true }
        hotKeyToken = hotKeys.register(Self.hotKey) { [weak self] in self?.toggleForFrontApp() }
        return hotKeyToken != nil
    }

    func update(engine: TranslationEngine, config: TolkConfig) {
        self.engine = engine
        self.config = config
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, !isEnabled(bid) { reset(reason: "disabled") }
    }

    /// The tap must run for this mode (the user turned it on somewhere, or the automatic mode is on).
    var wantsKeys: Bool { TypeTranslate.anyEnabled(config.typeTranslateApps) || config.typeTranslateAuto }

    func appChanged() {
        reset(reason: "app")
        screen.reset()
    }

    func noteClick() { if shown != nil || task != nil { reset(reason: "click") } }

    private func isOff(_ bundleID: String?) -> Bool {
        AutocompleteSafety.isOffApp(bundleID, userList: Set(config.autocompleteOffApps))
    }

    private func isEnabled(_ bundleID: String) -> Bool {
        config.typeTranslateApps[bundleID] == true || (config.typeTranslateAuto && config.typeTranslateApps[bundleID] != false)
    }

    private func reset(reason: String) {
        planner.cancel()
        task?.cancel(); task = nil
        if shown != nil { Diagnostics.log("type-translate: hidden reason=\(reason)") }
        shown = nil
        if case .notice = panel.content { return }
        panel.hide()
    }

    // MARK: - Hotkey

    func toggleForFrontApp() {
        let app = NSWorkspace.shared.frontmostApplication
        guard let bid = app?.bundleIdentifier, app?.processIdentifier != Self.ownPID, !isOff(bid) else {
            notice(TypeTranslate.unavailableHere); return
        }
        let apps = TypeTranslate.toggled(config.typeTranslateApps, bundleID: bid)
        config.typeTranslateApps = apps
        onToggle?(apps)
        let on = apps[bid] == true
        if !on { reset(reason: "toggled-off") }
        Diagnostics.log("type-translate: \(on ? "on" : "off") app=\(bid)")
        notice(TypeTranslate.toggleNotice(appName: app?.localizedName ?? bid, on: on))
    }

    private func notice(_ text: String) {
        let m = NSEvent.mouseLocation
        noticeTask?.cancel()
        panel.show(.notice(text), fieldFrame: nil, caret: NSRect(x: m.x, y: m.y - 24, width: 1, height: 18))
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self else { return }
            if case .notice = self.panel.content { self.panel.hide() }
        }
    }

    // MARK: - Keys (event tap, main thread)

    func handleKey(_ event: CGEvent) -> KeyResult {
        let front = NSWorkspace.shared.frontmostApplication
        guard let bid = front?.bundleIdentifier, front?.processIdentifier != Self.ownPID else { return .proceed }
        if AutocompleteController.focusIsInOwnWindow() {   // typing in Tolk's own (non-activating) window
            if shown != nil || task != nil { reset(reason: "own-window") }
            return .proceed
        }
        if IsSecureEventInputEnabled() || isOff(bid) {
            if shown != nil || task != nil { reset(reason: "secure-or-off") }
            return .proceed
        }
        let explicit = config.typeTranslateApps[bid]
        guard explicit != false, explicit == true || config.typeTranslateAuto else { return .proceed }
        let owned = explicit == true

        let mods = event.flags
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let action = TypeTranslate.classify(
            keyCode: code, command: mods.contains(.maskCommand), control: mods.contains(.maskControl),
            option: mods.contains(.maskAlternate), printable: Self.isPrintable(event), panelVisible: shown != nil && panel.isVisible)
        switch action {
        case .accept:
            return accept() ? .swallow : (owned ? .skipAutocomplete : .proceed)
        case .dismiss:
            reset(reason: "esc")
            suppressed = true
            return .swallow
        case .textChanged:
            suppressed = false
            if let pid = front?.processIdentifier { screen.prepare(pid: pid) }
            if case .notice = panel.content { panel.hide() }
            shown = nil
            if panel.isVisible { panel.hide() }
            schedule(bundleID: bid)
        case .sent:
            reset(reason: "sent")
        case .ignore:
            break
        }
        return owned ? .skipAutocomplete : .proceed
    }

    private static func isPrintable(_ event: CGEvent) -> Bool {
        var length = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buf)
        guard length > 0 else { return false }
        for u in String(utf16CodeUnits: buf, count: min(length, 8)).unicodeScalars {
            if u.value < 0x20 || u.value == 0x7F || (0xF700...0xF8FF).contains(u.value) { return false }
        }
        return true
    }

    // MARK: - Request

    private func schedule(bundleID: String) {
        task?.cancel()
        let g = planner.change(at: Self.now)
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pause))
            guard let self, !Task.isCancelled, self.planner.fire(g, at: Self.now) else { return }
            await self.run(bundleID: bundleID, generation: g)
        }
    }

    private func run(bundleID: String, generation g: Int) async {
        guard !suppressed, !IsSecureEventInputEnabled(), !isOff(bundleID) else { return }
        let read = await TypeTranslateField.read()
        if read == nil, !Task.isCancelled, planner.generation == g {
            Diagnostics.log("type-translate: field not readable app=\(bundleID)")
        }
        guard let field = read, !Task.isCancelled, planner.generation == g,
              field.pid != Self.ownPID, !AutocompleteController.focusIsInOwnWindow(), field.bundleID == bundleID, !IsSecureEventInputEnabled() else { return }
        let explicit = config.typeTranslateApps[bundleID]
        guard explicit != false else { return }

        let ctx = await screen.context(forPID: field.pid, waitingUpTo: .milliseconds(80)) ?? ""
        guard !Task.isCancelled, planner.generation == g else { return }
        let partner = TypeTranslate.partner(screen: ctx, draft: field.text)
        let known = partner == nil && TypeTranslate.screenIsAllSameLanguage(screen: ctx, draft: field.text)
        let verdict = TypeTranslate.decide(
            text: field.text, partner: partner, screenKnown: known, primary: config.primaryLanguage, secondary: config.secondaryLanguage,
            explicitlyOn: explicit == true, auto: config.typeTranslateAuto)
        guard case let .translate(source, target) = verdict else {
            if case .silent(let why) = verdict { Diagnostics.log("type-translate: silent (\(why.rawValue)) len=\(field.text.count) app=\(bundleID)") }
            panel.hide(); return
        }

        let text = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = ThreadMemory.shared.context(for: text, app: bundleID)
        let request = TypeTranslate.request(text: text, source: source, target: target, partner: partner,
                                            tone: config.tone(forApp: bundleID), threadContext: thread)
        let t0 = Date()
        let result: CollectedText
        do {
            result = try await TextCollector.collect(engine.translate(request))
        } catch {
            if !(error is CancellationError), !Task.isCancelled {
                Diagnostics.log("type-translate: no translation (\(type(of: error))) len=\(text.count) app=\(bundleID)")
            }
            return
        }
        guard !Task.isCancelled, planner.generation == g, !UIText.isFallbackProvider(result.provider), !result.fellBack else { return }
        let translation = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty, translation != text else { return }

        // The text may have changed while the model worked: show only for exactly the same field and text.
        guard let now = await TypeTranslateField.read(), !Task.isCancelled, planner.generation == g, !suppressed else { return }
        var same = true
        if let a = field.element, let b = now.element { same = CFEqual(a, b) }
        guard TypeTranslate.decideReplace(shown: field.snapshot, now: now.snapshot, sameElement: same) == .replace else { return }

        let lost = TypeTranslate.blockingWarnings(
            TranslationCheck.warnings(source: text, translation: translation, from: source, to: target))
        let warning = lost.isEmpty ? nil : TypeTranslate.warningHint(lost)
        if !lost.isEmpty { Diagnostics.log("type-translate: check warnings=\(lost.count) app=\(bundleID)") }
        shown = Shown(snapshot: now.snapshot, element: now.element, translation: translation, source: source, target: target,
                      warning: warning)
        panel.show(.translation(text: translation, label: TypeTranslate.label(for: target), warning: warning),
                   fieldFrame: now.frame, caret: now.caret)
        Diagnostics.log("type-translate: shown \(source.rawValue)->\(target.rawValue) in=\(text.count) out=\(translation.count) ms=\(Int(Date().timeIntervalSince(t0) * 1000)) reply=\(partner != nil) app=\(bundleID)")
    }

    // MARK: - Tab

    /// Replaces the field's text with the translation. true = the key is swallowed; false = the field is not the one
    /// the translation was made for (the key goes to the app untouched and nothing is changed).
    private func accept() -> Bool {
        guard var s = shown, panel.isVisible, !IsSecureEventInputEnabled() else { return false }
        if s.warning != nil, !s.armed {
            // Something looks lost (link, number, time): make the user look once more before inserting.
            s.armed = true
            shown = s
            return true
        }
        let now = TypeTranslateField.readQuick()
        var same = true
        if let a = s.element, let b = now?.element { same = CFEqual(a, b) }
        let decision = TypeTranslate.decideReplace(shown: s.snapshot, now: now?.snapshot, sameElement: same)
        guard decision == .replace, let element = now?.element else {
            if case .skip(let why) = decision { Diagnostics.log("type-translate: not replaced, field check failed (\(why))") }
            reset(reason: "stale")
            return false
        }
        guard TypeTranslateField.selectAll(element, utf16Count: s.snapshot.text.utf16.count) else {
            Diagnostics.log("type-translate: select-all refused app=\(s.snapshot.bundleID ?? "?")")
            shown = nil
            show(error: TypeTranslate.selectFailed, field: now)
            return true
        }
        let translation = s.translation
        let bid = s.snapshot.bundleID
        planner.cancel()
        shown = nil
        panel.hide()
        Diagnostics.log("type-translate: replacing len=\(s.snapshot.text.count) -> \(translation.count) app=\(bid ?? "?")")
        Task { [weak self] in
            await ClipboardPaste.paste(translation)
            ThreadMemory.shared.record(source: s.snapshot.text, translation: translation, from: s.source, to: s.target, app: bid)
            self?.suppressed = true   // the paste changed the field; wait for the user's next keystroke
        }
        return true
    }

    private func show(error: String, field: TypeTranslateField?) {
        panel.show(.error(error), fieldFrame: field?.frame, caret: field?.caret)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            if case .error = self.panel.content { self.panel.hide() }
        }
    }
}
