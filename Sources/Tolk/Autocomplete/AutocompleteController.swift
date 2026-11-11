// System-wide autocomplete: watches typing through an active event tap, asks the local model
// for a continuation after a short pause, shows it as ghost text at the caret and lets the
// user accept it with Tab (next word) or → (everything). Esc dismisses.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TolkCore

@MainActor
final class AutocompleteController {
    /// Bundle ids of apps where autocomplete is off (the user's list; the built-in one is always added, see `offApps`).
    var disabledApps: Set<String> = []
    /// The user's list plus the built-in one (password managers, terminals, IDEs) that cannot be turned off.
    var offApps: Set<String> { disabledApps.union(AutocompleteSafety.builtinOffApps) }
    /// false = typing help only (typo fixes, emoji): the model is never asked, no screen context, no style learning,
    /// and the field is read only when the keys typed so far could have finished a word or an emoji code.
    var modelEnabled = true
    /// Asked in order before the model; the first answer is shown instead of (or before) a model suggestion.
    var instantProviders: [InstantSuggestionProvider] = []
    /// Extra prompt material (instructions, glossary, clipboard, style examples, length).
    var promptExtras: ((FocusedField) -> PromptExtras)?
    /// Accepted suggestions and sent messages (Return in a field), for style learning.
    var onAccepted: ((AcceptedText) -> Void)?

    var isRunning: Bool { tap != nil }
    /// «Перевод при наборе» sees every key first; in an app where it is on, autocomplete stays out.
    var typeTranslate: TypeTranslateController?

    private let server: LocalModelServer
    /// Visible conversation around the field, collected in the background (never awaited for long).
    private let screenContext = ScreenContext()
    private var panel: GhostTextPanel?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<AutocompleteController>?
    private var appObserver: NSObjectProtocol?
    private let journal = SuggestionJournal.shared
    /// Numbers only (see ACStats): counters per day, model file and app. Never any text.
    private let stats = ACStatsStore.shared
    private var statsModel: String { (server.modelPath as NSString).lastPathComponent }
    /// Called after every recorded event (the menu line «Сегодня: …»).
    var onStatsChanged: (() -> Void)?
    private var lastContextSource = ""
    /// Apps where typing synthetic key events did not change the field: insert through the pasteboard instead.
    private var pasteApps: Set<String> = []

    /// Remaining (not yet accepted) suggestion; non-nil while the ghost text is visible.
    private var suggestion: String?
    /// Set while the visible suggestion is an instant replacement (emoji, typo fix).
    private var instant: InstantSuggestion?
    /// Field the visible suggestion (model or instant) was built for: process, element and the text before the caret
    /// that the field must still have. Accepting re-reads the field quickly and compares; any difference = no insert.
    private var anchor: (snap: AutocompleteSafety.FieldSnapshot, element: AXUIElement?)?
    /// Time the key handler may spend re-reading the field before it lets the key through.
    private static let verifyBudget: TimeInterval = 0.025
    /// Characters typed since the last click / app switch / non-printing key (typing-help-only mode).
    private var recentTyped = ""
    /// Text before the caret when the current suggestion was shown (for `onAccepted`).
    private var shownTextBefore = ""
    private var shownBundleID: String?
    /// After Esc nothing is requested in this field: until a click, an app switch, Tab, Return or a ⌘/⌃ key
    /// (`AutocompleteTuning.endsPause`) — the user has probably moved on.
    private var suppressed = false
    /// When the previous printing key arrived (to pick the pause before the request).
    private var lastKeyAt: Date?
    /// A suggestion was accepted while the current message was being written (for «remember only such messages»).
    private var acceptedInMessage = false
    /// «Выбор слов»: off / medium / strong, and where the user's texts come from. Only used with style learning on.
    var wordBiasMode = "off"
    var wordBiasTexts: (() -> [String])?
    private let wordBias = WordBias()
    private var lastSkipLog = ""
    private var generation = 0
    private var pending: Task<Void, Never>?

    /// Pause before a request: 20 ms, 60 ms while the user types fast (measurements in `AutocompleteTuning`).
    private func debounce() -> Duration {
        .milliseconds(AutocompleteTuning.debounceMs(sinceLastKey: lastKeyAt.map { Date().timeIntervalSince($0) }))
    }
    private static let repositionDelay: Duration = .milliseconds(50)
    private static let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    private func isOff(_ bundleID: String?) -> Bool {
        AutocompleteSafety.isOffApp(bundleID, userList: disabledApps)
    }

    /// Keyboard focus is in a Tolk window (popup, reply, main window). Their panels do not activate the app, so the
    /// frontmost application is still the one underneath: the key window tells. Cheap (no AX call).
    static func focusIsInOwnWindow() -> Bool {
        AutocompleteSafety.focusIsInOwnWindow(keyWindowIsOurs: NSApp.keyWindow != nil, focusedPID: nil,
                                              frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, ownPID: ownPID)
    }

    /// Quick re-read of the field for a key handler: returns it only if it is still the field (process, element,
    /// text before the caret, end of line) the visible suggestion was built for. Otherwise (or when the read does
    /// not finish within the budget) the suggestion is dropped and nil is returned: the caller must pass the key on.
    private func verifiedField(requireLineEnd: Bool = true) -> FocusedField? {
        guard let a = anchor, !IsSecureEventInputEnabled(), !isOff(a.snap.bundleID) else {
            cancelPending(); hide(reason: "stale"); return nil
        }
        let now = FocusedField.readQuick(seconds: Self.verifyBudget)
        var sameElement = true
        if let ae = a.element, let ne = now?.element { sameElement = CFEqual(ae, ne) }
        let decision = AutocompleteSafety.decide(shown: a.snap, now: now?.snapshot, restOfLine: now?.restOfLine ?? "",
                                                 sameElement: sameElement, requireLineEnd: requireLineEnd)
        guard case .apply = decision, let now else {
            if case .skip(let why) = decision { Diagnostics.log("autocomplete: not inserted, field check failed (\(why))") }
            cancelPending(); hide(reason: "stale"); return nil
        }
        return now
    }

    /// Typing-help-only mode: is it worth reading the field after these keys? Only right after "word<separator>"
    /// (a possible typo) or ":code" (a possible emoji).
    static func instantWorthChecking(_ recent: String) -> Bool {
        Autocorrect.lastFinishedWord(in: recent) != nil || EmojiSuggestions.trailingCode(in: recent) != nil
    }

    private enum Key {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let rightArrow: Int64 = 124
    }

    init(server: LocalModelServer) {
        self.server = server
        screenContext.onUpdate = { [weak self] source, chars, ms in
            self?.lastContextSource = source.rawValue
            Diagnostics.log("autocomplete: context source=\(source.rawValue) chars=\(chars) ms=\(ms)")
        }
    }

    // MARK: - Lifecycle

    /// Returns false when Accessibility permission is missing or the tap cannot be created.
    @discardableResult func start() -> Bool {
        if tap != nil { return true }
        guard DoubleCopyMonitor.hasAccessibility(prompt: false) else { return false }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        let retained = Unmanaged.passRetained(self)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: autocompleteTapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        self.retainedSelf = retained

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activeAppChanged(app) }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            FocusedField.enableAccessibility(pid: front.processIdentifier)
        }
        Diagnostics.log("autocomplete: started")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        self.tap = nil
        runLoopSource = nil
        cancelPending()
        hide(reason: "stop")
        retainedSelf?.release()
        retainedSelf = nil
        Diagnostics.log("autocomplete: stopped")
    }

    // MARK: - Event tap (main thread)

    /// Returns true when the event must be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown, .rightMouseDown:
            if event.getIntegerValueField(.eventSourceUserData) == DoubleCopyMonitor.syntheticMarker { return false }
            typeTranslate?.noteClick()
            suppressed = false
            cancelPending()
            hide(reason: "click")
            recentTyped = ""
            return false
        case .keyDown:
            break
        default:
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == DoubleCopyMonitor.syntheticMarker { return false }

        // Typing in Tolk's own windows: no suggestions, no fixes, nothing shown.
        if Self.focusIsInOwnWindow() {
            skip("focus in Tolk's own window (key window: \(NSApp.keyWindow?.className ?? "none"))")
            if suggestion != nil || instant != nil { hide(reason: "own-window") }
            cancelPending()
            recentTyped = ""
            return false
        }

        if let tt = typeTranslate {
            switch tt.handleKey(event) {
            case .swallow: return true
            case .skipAutocomplete:
                skip("«Перевод при наборе» owns this app")
                if suggestion != nil || instant != nil { hide(reason: "type-translate") }
                cancelPending()
                recentTyped = ""
                return false
            case .proceed: break
            }
        }

        // Password being typed (secure input) or an app that is off: touch nothing, read nothing, show nothing.
        let front = NSWorkspace.shared.frontmostApplication
        if IsSecureEventInputEnabled() || isOff(front?.bundleIdentifier) {
            if suggestion != nil || instant != nil { hide(reason: "secure-or-off") }
            cancelPending()
            recentTyped = ""
            return false
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = event.flags.intersection(Self.modifiers) // arrows carry .maskSecondaryFn, ignore it
        // Screenshot shortcuts (⌘⇧3/4/5) must not disturb a visible suggestion or a running request.
        if mods == [.maskCommand, .maskShift], [20, 21, 23].contains(code) { return false }
        let typed = Self.typedText(event)
        if suppressed, AutocompleteTuning.endsPause(keyCode: code, command: mods.contains(.maskCommand), control: mods.contains(.maskControl)) {
            suppressed = false
        }

        // ⌥Tab = an ordinary Tab: the suggestion is not accepted, the app gets a plain Tab.
        if code == Key.tab, mods == [.maskAlternate], suggestion != nil || instant != nil {
            cancelPending()
            hide(reason: "plain-tab", dismissed: false)
            event.flags.remove(.maskAlternate)
            return false
        }

        // Return sends the message in chats: report it for style learning (before the app clears the field).
        if modelEnabled, (code == 36 || code == 76), mods.isEmpty, let onAccepted, let f = FocusedField.readQuick(), f.pid != Self.ownPID,
           !isOff(f.bundleID) {
            let msg = (f.textBefore + f.restOfLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { onAccepted(AcceptedText(kind: .sent, bundleID: f.bundleID, textBefore: msg, accepted: "", hadAccepted: acceptedInMessage)) }
        }
        if code == 36 || code == 76, mods.isEmpty { acceptedInMessage = false }

        if instant != nil {
            // A stale suggestion (focus or text changed under it) is dropped and the key goes to the app.
            if mods.isEmpty, code == Key.tab || code == Key.rightArrow { return acceptInstant() ? { recentTyped = ""; return true }() : false }
            if mods.isEmpty, code == Key.escape { cancelPending(); hide(reason: "esc"); suppressed = true; return true }
            hide(reason: typed != nil ? "typed" : "key code=\(code) mods=\(mods.rawValue)")
        } else if suggestion != nil {
            if mods.isEmpty {
                switch code {
                case Key.tab:
                    return acceptWord()      // false = the field changed: the key goes to the app untouched
                case Key.rightArrow:
                    return acceptAll()
                case Key.escape:
                    cancelPending()
                    hide(reason: "esc")
                    suppressed = true
                    return true
                default: break
                }
            }
            // The user types what the suggestion already says: keep it, just shorten it.
            if mods.isDisjoint(with: [.maskCommand, .maskControl]), let typed, let s = suggestion, s.hasPrefix(typed) {
                consumed(typed)
                return false
            }
            hide(reason: typed != nil ? "typed" : "key code=\(code) mods=\(mods.rawValue)")
        }

        cancelPending()
        let printing = typed != nil && mods.isDisjoint(with: [.maskCommand, .maskControl])
        if !modelEnabled {
            if printing, let typed {
                recentTyped = String((recentTyped + typed).suffix(40))
                if Self.instantWorthChecking(recentTyped) { scheduleRequest(after: debounce()) }
            } else if code == 51, mods.isEmpty, !recentTyped.isEmpty {
                recentTyped.removeLast()
            } else {
                recentTyped = ""
            }
            return false
        }
        if printing {
            lastKeyAt = Date()
            if let pid = front?.processIdentifier, pid != Self.ownPID {
                screenContext.prepare(pid: pid)   // first keystroke in a field: gather context ahead of the request
            }
            scheduleRequest(after: debounce())
        }
        return false
    }

    /// Text a key press would insert, or nil for non-printing keys (arrows, Tab, Return, Esc, Backspace, F-keys).
    private static func typedText(_ event: CGEvent) -> String? {
        var length = 0
        var buf = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buf)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: buf, count: min(length, 8))
        for u in s.unicodeScalars {
            if u.value < 0x20 || u.value == 0x7F || (0xF700...0xF8FF).contains(u.value) { return nil }
        }
        return s
    }

    // MARK: - Showing and hiding

    private func hide(reason: String = "other", dismissed: Bool = true) {
        if suggestion != nil || instant != nil {
            if suggestion != nil, reason == "typed" { stats.typedOn(model: statsModel, app: shownBundleID); onStatsChanged?() }
            if suggestion != nil, reason == "esc" { stats.escaped(model: statsModel, app: shownBundleID); onStatsChanged?() }
            Diagnostics.log("autocomplete: hidden reason=\(reason)")
            if dismissed { journal.dismissed(reason: reason, bundleID: shownBundleID) }
        }
        suggestion = nil
        instant = nil
        anchor = nil
        recheck?.cancel(); recheck = nil
        panel?.hide()
    }

    /// An instant replacement deletes text, so it must not stay on screen if the field no longer fits it: re-read
    /// shortly after showing and hide it BEFORE the user presses Tab (a Tab that would not insert must not look like
    /// one that will).
    private func scheduleInstantRecheck() {
        let shownInstant = instant?.text
        recheck?.cancel()
        recheck = Task { [weak self] in
            for delay in [120, 350] as [Int] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled, self.instant?.text == shownInstant, shownInstant != nil else { return }
                guard let f = await FocusedField.readAsync(), self.instant?.text == shownInstant, !Task.isCancelled else { continue }
                if !self.anchorStillMatches(f) || Self.focusIsInOwnWindow() {
                    self.hide(reason: "stale-preview")
                    return
                }
            }
        }
    }
    private var recheck: Task<Void, Never>?

    private func cancelPending() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    private func display(_ text: String, caret: NSRect, fontSize: CGFloat? = nil, rightLimit: CGFloat? = nil) {
        if panel == nil { panel = GhostTextPanel() }
        suggestion = text
        panel?.show(text, caret: caret, fontSize: fontSize, rightLimit: rightLimit)
        if panel?.isVisible != true { Diagnostics.log("autocomplete: panel not visible after show (no room or empty)"); suggestion = nil }
    }

    /// Part of the suggestion was typed by the user: shorten it and re-place the panel at the new caret.
    private func consumed(_ typed: String) {
        guard let s = suggestion else { return }
        let rest = String(s.dropFirst(typed.count))
        anchor?.snap.textBefore += typed   // the field is expected to contain what was typed
        cancelPending()
        if rest.isEmpty {
            hide(reason: "consumed", dismissed: false)
            scheduleRequest(after: debounce())
        } else {
            suggestion = rest
            scheduleReposition()
        }
    }

    /// Re-reads the caret shortly after the target app processed an edit and moves the ghost text there.
    /// With `waitingForChangeFrom` (after our own insertion) it retries for up to ~350 ms until the app has
    /// actually applied the edit, so the caret is not read from the old text.
    private func scheduleReposition(waitingForChangeFrom old: String? = nil) {
        let gen = generation
        pending = Task { [weak self] in
            var tries = 0
            var field: FocusedField?
            repeat {
                try? await Task.sleep(for: Self.repositionDelay)
                guard let self, !Task.isCancelled, gen == self.generation, self.suggestion != nil else { return }
                field = await FocusedField.readAsync()
                tries += 1
            } while old != nil && tries < 7 && field != nil && field?.textBefore == old
            guard let self, !Task.isCancelled, gen == self.generation, let s = self.suggestion else { return }
            if let f = field, f.pid != Self.ownPID, !IsSecureEventInputEnabled(), !self.isOff(f.bundleID),
               self.anchorStillMatches(f) {
                self.display(s, caret: f.caret, fontSize: f.fontSize, rightLimit: f.rightLimit)
            } else {
                self.hide(reason: "reposition-read-nil")
            }
        }
    }

    /// The field read after an edit is still the one the suggestion belongs to (ends of lines may differ).
    private func anchorStillMatches(_ f: FocusedField) -> Bool {
        guard let a = anchor else { return false }
        var same = true
        if let ae = a.element, let ne = f.element { same = CFEqual(ae, ne) }
        let d = AutocompleteSafety.decide(shown: a.snap, now: f.snapshot, restOfLine: f.restOfLine, sameElement: same, requireLineEnd: true)
        if case .skip(let why) = d { Diagnostics.log("autocomplete: reposition dropped (\(why))") }
        return d == .apply
    }

    // MARK: - Accepting

    private func acceptWord() -> Bool {
        guard let s = suggestion, let verified = verifiedField() else { return false }
        let chars = Array(s)
        var i = 0
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        while i < chars.count, !chars[i].isWhitespace { i += 1 }
        let word = String(chars[..<i])
        let rest = String(chars[i...])
        let beforeInsert = insertVerified(word, kind: "word", field: verified)
        Diagnostics.log("autocomplete: accepted word len=\(word.count)")
        stats.acceptedWord(model: statsModel, app: shownBundleID, word: word); onStatsChanged?()
        acceptedInMessage = true
        wordBias.noteAccepted(word)
        onAccepted?(AcceptedText(kind: .word, bundleID: shownBundleID, textBefore: shownTextBefore, accepted: word))
        shownTextBefore += word
        anchor?.snap.textBefore += word

        cancelPending()
        if rest.allSatisfy({ $0.isWhitespace }) {
            hide(reason: "accepted-word-end", dismissed: false)
            scheduleRequest(after: .milliseconds(60))
        } else {
            suggestion = rest
            scheduleReposition(waitingForChangeFrom: beforeInsert)
        }
        return true
    }

    private func acceptAll() -> Bool {
        guard let s = suggestion, let verified = verifiedField() else { return false }
        insertVerified(s, kind: "all", field: verified)
        Diagnostics.log("autocomplete: accepted all len=\(s.count)")
        stats.acceptedAll(model: statsModel, app: shownBundleID, text: s); onStatsChanged?()
        acceptedInMessage = true
        wordBias.noteAccepted(s)
        onAccepted?(AcceptedText(kind: .all, bundleID: shownBundleID, textBefore: shownTextBefore, accepted: s))
        cancelPending()
        hide(reason: "accepted-all", dismissed: false)
        return true
    }

    /// Emoji / typo fix: delete what it replaces, type the replacement. Deleting characters in the wrong place is
    /// not undoable for us, so the field is read again first: same app, same text before the caret, still at the
    /// end of the line. Otherwise nothing is touched and false is returned.
    private func acceptInstant() -> Bool {
        guard let i = instant else { return false }
        // Deleting in the wrong place cannot be undone: verify (process, element, text, end of line) right before.
        guard verifiedField() != nil else {
            Diagnostics.log("autocomplete: instant not applied, field changed")
            return false
        }
        deleteBackward(i.replaceCount)
        insert(i.text)
        Diagnostics.log("autocomplete: accepted instant replace=\(i.replaceCount) len=\(i.text.count)")
        stats.instantAccepted(model: statsModel, app: shownBundleID, chars: i.text.count); onStatsChanged?()
        let pf = panel?.frame
        journal.accepted(kind: "instant", text: i.text, bundleID: shownBundleID,
                         caret: pf.map { NSRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) })
        cancelPending()
        hide(reason: "accepted-instant", dismissed: false)
        return true
    }

    private func deleteBackward(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) else { continue }
                ev.flags = []
                ev.setIntegerValueField(.eventSourceUserData, value: DoubleCopyMonitor.syntheticMarker)
                ev.post(tap: .cghidEventTap)
            }
        }
    }

    /// Inserts `text`, then checks (200 ms later) that the field really changed. If it did not — Electron/Chromium
    /// apps sometimes ignore synthetic unicode key events — remembers the app and pastes through the clipboard.
    @discardableResult
    private func insertVerified(_ text: String, kind: String, field: FocusedField) -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        let before: String? = field.textBefore
        let id = app?.bundleIdentifier ?? "?"
        let method = pasteApps.contains(id) ? "paste" : "unicode"
        let t0 = Date()
        insert(text)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let pf = panel?.frame
        journal.accepted(kind: kind, text: text, bundleID: id, method: method, ms: ms, before: before,
                         caret: pf.map { NSRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) })
        guard let before, let app else { return before }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            let f = await FocusedField.readAsync()
            let same = f?.pid == app.processIdentifier
            let changed = same && f?.textBefore != before
            self.journal.insertChecked(bundleID: id, method: method, changed: changed, after: same ? f?.textBefore : nil)
            guard same, let f, f.textBefore == before else { return }
            if method == "paste" {
                Diagnostics.log("autocomplete: insert had no effect even via paste app=\(id)")
            } else {
                Diagnostics.log("autocomplete: insert had no effect, switching to paste app=\(id)")
                self.pasteApps.insert(id)
                self.paste(text)
            }
        }
        return before
    }

    private func insert(_ text: String) {
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, pasteApps.contains(id) { paste(text); return }
        typeUnicode(text)
    }

    /// Save the clipboard, put `text` there, press ⌘V, restore the clipboard (after 0.4 s, only if nobody else
    /// changed it meanwhile). The clipboard watcher is told about both of our own changes.
    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        pb.declareTypes([.string, .tolkTransient], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: .tolkTransient)
        let ours = pb.changeCount
        ClipboardWatcher.shared.noteOwnChange(ours)
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down) else { continue }
            ev.flags = .maskCommand
            ev.setIntegerValueField(.eventSourceUserData, value: DoubleCopyMonitor.syntheticMarker)
            ev.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard pb.changeCount == ours else { return }
            ClipboardWatcher.shared.noteOwnChange(saved.restore(to: pb))
        }
    }

    /// Types `text` into the focused app with synthetic key events (marked so Tolk's own taps skip them).
    private func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                ev.flags = []
                ev.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                ev.setIntegerValueField(.eventSourceUserData, value: DoubleCopyMonitor.syntheticMarker)
                ev.post(tap: .cghidEventTap)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for ch in text {
            let units = Array(String(ch).utf16)
            if chunk.count + units.count > 16 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
    }

    // MARK: - Requesting

    /// Why a request for a suggestion ended without one (these exits used to be silent, so «подсказок мало» could not be
    /// explained from the log). One line per reason at most every 2 s; no text of the user is written.
    private var lastSkipAt: [String: TimeInterval] = [:]
    private func skip(_ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastSkipAt[reason], now - last < 2 { return }
        lastSkipAt[reason] = now
        Diagnostics.log("autocomplete: no request — \(reason)")
    }


    private func scheduleRequest(after delay: Duration) {
        guard !suppressed else { skip("paused by Esc"); return }
        cancelPending()
        let gen = generation
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            await self.request(generation: gen)
        }
    }

    private func request(generation gen: Int) async {
        // Secure input is on while a password is being typed (any app, including web forms): read nothing.
        guard !IsSecureEventInputEnabled() else { skip("secure input"); return }
        guard !isOff(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        guard let field = await FocusedField.readAsync() else { skip("field not read"); return }
        guard !Task.isCancelled, gen == generation, !IsSecureEventInputEnabled() else { return }
        if field.pid == Self.ownPID { return }
        if isOff(field.bundleID) { return }
        guard AutocompleteSafety.isBlankTail(field.restOfLine) else {
            skip("text after the caret (\(field.restOfLine.count) chars) app=\(field.bundleID ?? "?")"); return
        }

        // Instant suggestions (emoji, typo fix) need no model and win over it.
        for p in instantProviders {
            guard let s = p.suggestion(for: field) else { continue }
            if panel == nil { panel = GhostTextPanel() }
            suggestion = nil
            instant = s
            anchor = (field.snapshot, field.element)
            shownBundleID = field.bundleID
            panel?.show(s.display, caret: field.caret, fontSize: field.fontSize, rightLimit: field.rightLimit)
            journal.instant(bundleID: field.bundleID, before: field.textBefore, replaceCount: s.replaceCount, display: s.display, caret: field.caret, panel: panel)
            Diagnostics.log("autocomplete: instant replace=\(s.replaceCount) app=\(field.bundleID ?? "?")")
            stats.instantShown(model: statsModel, app: field.bundleID); onStatsChanged?()
            scheduleInstantRecheck()
            if s.blocksModel { return }
            break
        }
        if instant != nil { return }
        guard modelEnabled else { return }
        guard server.state == .ready else { skip("model not ready (\(server.state))"); return }
        if let why = field.skipReason {
            let key = "\(field.bundleID ?? "?"):\(why)"
            if key != lastSkipLog { lastSkipLog = key; Diagnostics.log("autocomplete: small/search field skipped (\(why)) app=\(field.bundleID ?? "?") role=\(field.role) sub=\(field.subrole)") }
            return
        }
        wordBias.refreshIfNeeded(baseURL: server.baseURL, model: server.modelPath, mode: wordBiasMode, texts: wordBiasTexts)

        let trimmed = field.textBefore.filter { !$0.isWhitespace }
        guard trimmed.count >= 4, let last = field.textBefore.last, !last.isNewline else { skip("too little text or line start"); return }

        let appName = NSRunningApplication(processIdentifier: field.pid)?.localizedName
        let context = await screenContext.context(forPID: field.pid, waitingUpTo: .milliseconds(50))
        guard !Task.isCancelled, gen == generation else { return }
        let extras = promptExtras?(field) ?? PromptExtras()
        let prompt = AutocompletePrompt.prompt(textBefore: field.textBefore, appName: appName, context: context, extras: extras)
        let client = CompletionClient(baseURL: server.baseURL)
        let result: CompletionClient.Result
        do {
            result = try await client.complete(prompt: prompt, maxTokens: AutocompletePrompt.maxTokens)
        } catch {
            if error is CancellationError { return }
            if let e = error as? URLError {
                if e.code == .cancelled { return }
                Diagnostics.log("autocomplete: request failed URLError(\(e.code.rawValue))")
            } else if let e = error as? HTTPStatusError {
                Diagnostics.log("autocomplete: request failed http=\(e.status)")
            } else {
                Diagnostics.log("autocomplete: request failed \(type(of: error))")
            }
            return
        }
        guard !Task.isCancelled, gen == generation else { return }
        // The text may have changed while the model was thinking.
        guard !IsSecureEventInputEnabled(), var now = await FocusedField.readAsync() else { skip("field not read after the answer"); return }
        guard !Task.isCancelled, gen == generation else { return }
        guard now.pid == field.pid, now.textBefore == field.textBefore, AutocompleteSafety.isBlankTail(now.restOfLine), !isOff(now.bundleID) else {
            skip("field changed while the model answered (ms=\(result.ms), before \(field.textBefore.count) → \(now.textBefore.count) chars)"); return
        }
        if let a = field.element, let b = now.element, !CFEqual(a, b) { skip("focus moved while the model answered"); return }
        let sure = (result.firstProb ?? 0) >= AutocompletePrompt.sureProb
        var patient = false
        var text = AutocompletePrompt.clean(result.text, textBefore: field.textBefore, maxWords: extras.maxWords, sure: sure) ?? ""
        if text.isEmpty {
            let p1 = result.firstProb.map { String(format: "%.2f", $0) } ?? "-"
            let midWord = field.textBefore.last?.isLetter == true
            // Patient second look: the user stopped and keeps waiting → the less sure continuation is better than silence.
            var relaxed = ""
            if let bars = AutocompletePrompt.patient, !result.tokens.isEmpty {
                let kept = AutocompletePrompt.confidentPrefix(result.tokens, textBefore: field.textBefore, first: bars.first, next: bars.next)
                relaxed = AutocompletePrompt.clean(kept, textBefore: field.textBefore, maxWords: extras.maxWords, sure: sure) ?? ""
            }
            Diagnostics.log("autocomplete: empty suggestion ms=\(result.ms) raw=\(result.rawChars) kept=\(result.text.count) p1=\(p1) need=\(AutocompletePrompt.firstTokenProb) midword=\(midWord) patient=\(relaxed.count)")
            guard !relaxed.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(AutocompleteTuning.patientDelayMs))
            guard !Task.isCancelled, gen == generation, suggestion == nil, instant == nil, !IsSecureEventInputEnabled(),
                  let later = await FocusedField.readAsync(), !Task.isCancelled, gen == generation,
                  later.pid == field.pid, later.textBefore == field.textBefore, AutocompleteSafety.isBlankTail(later.restOfLine), !isOff(later.bundleID) else { return }
            if let a = field.element, let b = later.element, !CFEqual(a, b) { return }
            now = later
            text = relaxed
            patient = true
        }
        anchor = (now.snapshot, now.element)
        display(text, caret: now.caret, fontSize: now.fontSize, rightLimit: now.rightLimit)
        shownTextBefore = now.textBefore
        shownBundleID = now.bundleID
        let f = panel?.frame ?? .zero
        Diagnostics.log("autocomplete: shown\(patient ? " (patient)" : "") len=\(text.count) ms=\(result.ms) ctx=\(context?.count ?? 0) app=\(now.bundleID ?? "?") fs=\(now.fontSize.map { String(Int($0 * 10)) } ?? "-")/10 ax=\(now.caretInfo) caret=(\(Int(now.caret.minX)),\(Int(now.caret.minY)) \(Int(now.caret.width))x\(Int(now.caret.height))) panel=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))")
        stats.shown(model: statsModel, app: now.bundleID, text: text, ms: result.ms); onStatsChanged?()
        journal.shown(bundleID: now.bundleID, before: now.textBefore, text: text, ms: result.ms, ctxChars: context?.count ?? 0,
                      ctxSource: lastContextSource.isEmpty ? nil : lastContextSource, caret: now.caret, panel: panel)
    }

    // MARK: - App switching

    private func activeAppChanged(_ app: NSRunningApplication?) {
        screenContext.reset()
        typeTranslate?.appChanged()
        suppressed = false
        acceptedInMessage = false
        cancelPending()
        hide(reason: "appSwitch")
        recentTyped = ""
        if let app { FocusedField.enableAccessibility(pid: app.processIdentifier) }
    }
}

/// C callback for the event tap. Runs on the main run loop (the tap source is added there).
private func autocompleteTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<AutocompleteController>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { controller.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
