// System-wide autocomplete: watches typing through an active event tap, asks the local model
// for a continuation after a short pause, shows it as ghost text at the caret and lets the
// user accept it with Tab (next word) or → (everything). Esc dismisses.
import AppKit
import ApplicationServices

@MainActor
final class AutocompleteController {
    /// Bundle ids of apps where autocomplete is off.
    var disabledApps: Set<String> = []
    /// Called with the model latency (ms) every time a suggestion is shown.
    var onSuggestionShown: ((_ ms: Int) -> Void)?
    /// Asked in order before the model; the first answer is shown instead of (or before) a model suggestion.
    var instantProviders: [InstantSuggestionProvider] = []
    /// Extra prompt material (instructions, glossary, clipboard, style examples, length).
    var promptExtras: ((FocusedField) -> PromptExtras)?
    /// Accepted suggestions and sent messages (Return in a field), for style learning.
    var onAccepted: ((AcceptedText) -> Void)?

    var isRunning: Bool { tap != nil }

    private let server: LocalModelServer
    /// Visible conversation around the field, collected in the background (never awaited for long).
    private let screenContext = ScreenContext()
    private var panel: GhostTextPanel?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<AutocompleteController>?
    private var appObserver: NSObjectProtocol?
    private let journal = SuggestionJournal.shared
    private var lastContextSource = ""
    /// Apps where typing synthetic key events did not change the field: insert through the pasteboard instead.
    private var pasteApps: Set<String> = []

    /// Remaining (not yet accepted) suggestion; non-nil while the ghost text is visible.
    private var suggestion: String?
    /// Set while the visible suggestion is an instant replacement (emoji, typo fix).
    private var instant: InstantSuggestion?
    /// Text before the caret when the current suggestion was shown (for `onAccepted`).
    private var shownTextBefore = ""
    private var shownBundleID: String?
    /// After Esc nothing is requested until the user types a character.
    private var suppressed = false
    private var generation = 0
    private var pending: Task<Void, Never>?

    private static let debounce: Duration = .milliseconds(150)
    private static let repositionDelay: Duration = .milliseconds(50)
    private static let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

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
            cancelPending()
            hide(reason: "click")
            return false
        case .keyDown:
            break
        default:
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == DoubleCopyMonitor.syntheticMarker { return false }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = event.flags.intersection(Self.modifiers) // arrows carry .maskSecondaryFn, ignore it
        // Screenshot shortcuts (⌘⇧3/4/5) must not disturb a visible suggestion or a running request.
        if mods == [.maskCommand, .maskShift], [20, 21, 23].contains(code) { return false }
        let typed = Self.typedText(event)

        // Return sends the message in chats: report it for style learning (before the app clears the field).
        if (code == 36 || code == 76), mods.isEmpty, let onAccepted, let f = FocusedField.read(), f.pid != Self.ownPID,
           !(f.bundleID.map(disabledApps.contains) ?? false) {
            let msg = (f.textBefore + f.restOfLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { onAccepted(AcceptedText(kind: .sent, bundleID: f.bundleID, textBefore: msg, accepted: "")) }
        }

        if instant != nil {
            if mods.isEmpty, code == Key.tab || code == Key.rightArrow { acceptInstant(); return true }
            if mods.isEmpty, code == Key.escape { cancelPending(); hide(reason: "esc"); suppressed = true; return true }
            hide(reason: typed != nil ? "typed" : "key")
        } else if suggestion != nil {
            if mods.isEmpty {
                switch code {
                case Key.tab:
                    acceptWord()
                    return true
                case Key.rightArrow:
                    acceptAll()
                    return true
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
                suppressed = false
                consumed(typed.count)
                return false
            }
            hide(reason: typed != nil ? "typed" : "key")
        }

        cancelPending()
        if let typed, mods.isDisjoint(with: [.maskCommand, .maskControl]) {
            suppressed = false
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != Self.ownPID,
               !(NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(disabledApps.contains) ?? false) {
                screenContext.prepare(pid: pid)   // first keystroke in a field: gather context ahead of the request
            }
            scheduleRequest(after: Self.debounce)
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
            Diagnostics.log("autocomplete: hidden reason=\(reason)")
            if dismissed { journal.dismissed(reason: reason, bundleID: shownBundleID) }
        }
        suggestion = nil
        instant = nil
        panel?.hide()
    }

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
    private func consumed(_ count: Int) {
        guard let s = suggestion else { return }
        let rest = String(s.dropFirst(count))
        cancelPending()
        if rest.isEmpty {
            hide(reason: "consumed", dismissed: false)
            scheduleRequest(after: Self.debounce)
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
                field = FocusedField.read()
                tries += 1
            } while old != nil && tries < 7 && field != nil && field?.textBefore == old
            guard let self, !Task.isCancelled, gen == self.generation, let s = self.suggestion else { return }
            if let f = field, f.pid != Self.ownPID {
                self.display(s, caret: f.caret, fontSize: f.fontSize, rightLimit: f.rightLimit)
            } else {
                self.hide(reason: "reposition-read-nil")
            }
        }
    }

    // MARK: - Accepting

    private func acceptWord() {
        guard let s = suggestion else { return }
        let chars = Array(s)
        var i = 0
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        while i < chars.count, !chars[i].isWhitespace { i += 1 }
        let word = String(chars[..<i])
        let rest = String(chars[i...])
        let beforeInsert = insertVerified(word, kind: "word")
        Diagnostics.log("autocomplete: accepted word len=\(word.count)")
        onAccepted?(AcceptedText(kind: .word, bundleID: shownBundleID, textBefore: shownTextBefore, accepted: word))
        shownTextBefore += word

        cancelPending()
        if rest.allSatisfy({ $0.isWhitespace }) {
            hide(reason: "accepted-word-end", dismissed: false)
            scheduleRequest(after: .milliseconds(60))
        } else {
            suggestion = rest
            scheduleReposition(waitingForChangeFrom: beforeInsert)
        }
    }

    private func acceptAll() {
        guard let s = suggestion else { return }
        insertVerified(s, kind: "all")
        Diagnostics.log("autocomplete: accepted all len=\(s.count)")
        onAccepted?(AcceptedText(kind: .all, bundleID: shownBundleID, textBefore: shownTextBefore, accepted: s))
        cancelPending()
        hide(reason: "accepted-all", dismissed: false)
        suppressed = false
    }

    /// Emoji / typo fix: delete what it replaces, type the replacement.
    private func acceptInstant() {
        guard let i = instant else { return }
        deleteBackward(i.replaceCount)
        insert(i.text)
        Diagnostics.log("autocomplete: accepted instant replace=\(i.replaceCount) len=\(i.text.count)")
        let pf = panel?.frame
        journal.accepted(kind: "instant", text: i.text, bundleID: shownBundleID,
                         caret: pf.map { NSRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) })
        cancelPending()
        hide(reason: "accepted-instant", dismissed: false)
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
    private func insertVerified(_ text: String, kind: String) -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        let field = FocusedField.read()
        let before = field?.textBefore
        let id = app?.bundleIdentifier ?? "?"
        let method = pasteApps.contains(id) ? "paste" : "unicode"
        let t0 = Date()
        insert(text)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        journal.accepted(kind: kind, text: text, bundleID: id, method: method, ms: ms, before: before, caret: field?.caret)
        guard let before, let app else { return before }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            let f = FocusedField.read()
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

    private func scheduleRequest(after delay: Duration) {
        guard !suppressed else { return }
        cancelPending()
        let gen = generation
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            await self.request(generation: gen)
        }
    }

    private func request(generation gen: Int) async {
        guard server.state == .ready, let field = FocusedField.read() else { return }
        if field.pid == Self.ownPID { return }
        if let id = field.bundleID, disabledApps.contains(id) { return }
        guard field.restOfLine.allSatisfy({ $0.isWhitespace }) else { return }

        // Instant suggestions (emoji, typo fix) need no model and win over it.
        for p in instantProviders {
            guard let s = p.suggestion(for: field) else { continue }
            if panel == nil { panel = GhostTextPanel() }
            suggestion = nil
            instant = s
            shownBundleID = field.bundleID
            panel?.show(s.display, caret: field.caret, fontSize: field.fontSize, rightLimit: field.rightLimit)
            journal.instant(bundleID: field.bundleID, before: field.textBefore, replaceCount: s.replaceCount, display: s.display, caret: field.caret, panel: panel)
            Diagnostics.log("autocomplete: instant replace=\(s.replaceCount) app=\(field.bundleID ?? "?")")
            if s.blocksModel { return }
            break
        }
        if instant != nil { return }

        let trimmed = field.textBefore.filter { !$0.isWhitespace }
        guard trimmed.count >= 4, let last = field.textBefore.last, !last.isNewline else { return }

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
        guard let now = FocusedField.read(), now.pid == field.pid, now.textBefore == field.textBefore,
              now.restOfLine.allSatisfy({ $0.isWhitespace }) else { return }
        guard let text = AutocompletePrompt.clean(result.text, textBefore: field.textBefore, maxWords: extras.maxWords),
              !text.isEmpty else {
            Diagnostics.log("autocomplete: empty suggestion ms=\(result.ms)")
            return
        }
        display(text, caret: now.caret, fontSize: now.fontSize, rightLimit: now.rightLimit)
        shownTextBefore = now.textBefore
        shownBundleID = now.bundleID
        let f = panel?.frame ?? .zero
        Diagnostics.log("autocomplete: shown len=\(text.count) ms=\(result.ms) ctx=\(context?.count ?? 0) app=\(now.bundleID ?? "?") fs=\(now.fontSize.map { String(Int($0 * 10)) } ?? "-")/10 ax=\(now.caretInfo) caret=(\(Int(now.caret.minX)),\(Int(now.caret.minY)) \(Int(now.caret.width))x\(Int(now.caret.height))) panel=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))")
        journal.shown(bundleID: now.bundleID, before: now.textBefore, text: text, ms: result.ms, ctxChars: context?.count ?? 0,
                      ctxSource: lastContextSource.isEmpty ? nil : lastContextSource, caret: now.caret, panel: panel)
        onSuggestionShown?(result.ms)
    }

    // MARK: - App switching

    private func activeAppChanged(_ app: NSRunningApplication?) {
        screenContext.reset()
        cancelPending()
        hide(reason: "appSwitch")
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
