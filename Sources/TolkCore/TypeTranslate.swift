// «Перевод при наборе»: the user writes in their own language in a chat field, Tolk shows the translation into the
// partner's language under the field, Tab replaces the field's text with it. Pure rules (no AppKit): who the partner
// is and in which language, translate / stay silent, the debounce planner, the check before a replacement and the
// key classification. Checked by `tolk-cli --self-test`; the app side lives in `Sources/Tolk/TypeTranslate/`.
import Foundation

public enum TypeTranslate {
    // MARK: Partner

    /// The last message of the other side found in the visible text of the window.
    public struct Partner: Equatable, Sendable {
        public var message: String
        public var language: Language
        public init(message: String, language: Language) { self.message = message; self.language = language }
    }

    /// Lines shorter than this many letters are chrome (names, times, "Reply"), not messages.
    static let minMessageLetters = 8
    static let maxMessageChars = 500

    /// `screen` = visible conversation text (`ScreenContext`), one line per row, oldest first. `draft` = what the
    /// user has typed (its own lines are skipped). The partner's message is the last substantial line (with the
    /// lines right above it in the same language) whose language differs from the draft's: the user's own earlier
    /// messages are in the draft's language. Nothing found → nil.
    public static func partner(screen: String, draft: String) -> Partner? {
        let draftLang = LanguageDetector.detect(draft)
        let draftKey = normalize(draft)
        let lines = screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        func letters(_ s: String) -> Int { messageLetters(s) }
        func isDraftLine(_ s: String) -> Bool {
            let k = normalize(s)
            return !draftKey.isEmpty && !k.isEmpty && (draftKey.contains(k) || k.contains(draftKey))
        }
        var i = lines.count - 1
        while i >= 0 {
            let l = lines[i]
            if letters(l) >= minMessageLetters, !isDraftLine(l), LanguageDetector.detect(l) != draftLang { break }
            i -= 1
        }
        guard i >= 0 else { return nil }
        let lang = LanguageDetector.detect(lines[i])
        var picked = [lines[i]]
        var j = i - 1
        var total = lines[i].count
        while j >= 0, picked.count < 3 {
            let l = lines[j]
            guard letters(l) >= minMessageLetters, !isDraftLine(l), LanguageDetector.detect(l) == lang,
                  total + l.count < maxMessageChars else { break }
            picked.insert(l, at: 0); total += l.count; j -= 1
        }
        return Partner(message: String(picked.joined(separator: "\n").prefix(maxMessageChars)), language: lang)
    }

    /// True when the screen has substantial text and all of it is in the draft's language (the partner writes the
    /// same language: nothing to translate). False when there is no substantial text at all (language unknown).
    public static func screenIsAllSameLanguage(screen: String, draft: String) -> Bool {
        let draftLang = LanguageDetector.detect(draft)
        var any = false
        for l in screen.split(whereSeparator: \.isNewline) where messageLetters(String(l)) >= minMessageLetters {
            any = true
            if LanguageDetector.detect(String(l)) != draftLang { return false }
        }
        return any
    }

    /// Letters of a line that can be a message, 0 for chrome: a short "Name 10:41" header, or one or two bare words
    /// (a name, a button). A message has at least 3 words or 20 letters.
    static func messageLetters(_ line: String) -> Int {
        let n = line.filter(\.isLetter).count
        if line.count <= 40, line.range(of: #"\d{1,2}[:.]\d{2}"#, options: .regularExpression) != nil { return 0 }
        let words = line.split(whereSeparator: { $0.isWhitespace }).count
        return words >= 3 || n >= 20 ? n : 0
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Decision

    public enum Silence: String, Equatable, Sendable {
        case disabled, empty, tooShort, tooLong, sameLanguage, noPartnerForeign
    }

    public enum Verdict: Equatable, Sendable {
        case translate(source: Language, target: Language)
        case silent(Silence)
    }

    public static let maxTextChars = 1500
    public static let minLetters = 3

    /// Translate the whole field text from the user's language into the partner's? The partner's language is the
    /// last foreign message on screen; without any screen text it is `secondaryLanguage` (or `primaryLanguage` when
    /// the user already writes the secondary one). Text already in the partner's language → silent.
    /// `auto` (no explicit switch for the app) → only when the partner's message is in another language.
    public static func decide(text: String, partner: Partner?, screenKnown: Bool, primary: Language, secondary: Language,
                              explicitlyOn: Bool, auto: Bool) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .silent(.empty) }
        guard trimmed.filter(\.isLetter).count >= minLetters else { return .silent(.tooShort) }
        guard trimmed.count <= maxTextChars else { return .silent(.tooLong) }
        let source = LanguageDetector.detect(trimmed)
        let target: Language
        if let partner {
            target = partner.language
        } else if screenKnown {
            return .silent(.sameLanguage) // the visible conversation is in the user's own language
        } else {
            target = source == secondary ? primary : secondary
        }
        if source == target { return .silent(.sameLanguage) }
        if !explicitlyOn {
            guard auto, partner != nil else { return .silent(.disabled) }
        }
        return .translate(source: source, target: target)
    }

    /// The engine request: reply to the partner's message, the tone of the app, earlier lines of the thread.
    public static func request(text: String, source: Language, target: Language, partner: Partner?, tone: Tone,
                               threadContext: String?) -> TranslationRequest {
        var r = TranslationRequest(text: text, source: source, target: target, tone: tone, replyTo: partner?.message)
        r.threadContext = threadContext
        return r
    }

    // MARK: Per-app state

    /// Explicit state of an app: true / false, nil = never decided.
    public static func toggled(_ apps: [String: Bool], bundleID: String) -> [String: Bool] {
        var out = apps
        out[bundleID] = !(apps[bundleID] ?? false)
        return out
    }

    public static func anyEnabled(_ apps: [String: Bool]) -> Bool { apps.values.contains(true) }

    // MARK: Debounce

    /// Pure debounce: every change restarts the wait; only the newest generation may fire, once.
    public struct DebouncePlanner: Equatable, Sendable {
        public let delay: TimeInterval
        public private(set) var generation = 0
        private var lastChange: TimeInterval?
        public init(delay: TimeInterval = 0.5) { self.delay = delay }

        /// A change at `now`; returns the generation the caller schedules a wake-up for.
        public mutating func change(at now: TimeInterval) -> Int {
            generation += 1; lastChange = now; return generation
        }
        /// Drops whatever is scheduled.
        public mutating func cancel() { generation += 1; lastChange = nil }
        public func isCurrent(_ g: Int) -> Bool { g == generation && lastChange != nil }
        /// Seconds until the current generation is due (0 = due now); nil when nothing is scheduled.
        public func remaining(at now: TimeInterval) -> TimeInterval? {
            lastChange.map { max(0, delay - (now - $0)) }
        }
        /// The wake-up of generation `g` at `now`: true = run the request now (and nothing more is scheduled).
        public mutating func fire(_ g: Int, at now: TimeInterval) -> Bool {
            guard isCurrent(g), let last = lastChange, now - last >= delay - 0.001 else { return false }
            lastChange = nil
            return true
        }
    }

    // MARK: Check before replacing

    /// What the translation was made for (the whole text of the field).
    public struct FieldSnapshot: Equatable, Sendable {
        public var pid: Int32
        public var bundleID: String?
        public var text: String
        public init(pid: Int32, bundleID: String?, text: String) { self.pid = pid; self.bundleID = bundleID; self.text = text }
    }

    public enum ReplaceDecision: Equatable, Sendable {
        case replace
        case skip(String)
    }

    /// May the shown translation replace the field now? Same process, same element, exactly the same text.
    /// `now == nil` (read failed or ran out of time) → skip.
    public static func decideReplace(shown: FieldSnapshot, now: FieldSnapshot?, sameElement: Bool) -> ReplaceDecision {
        guard let now else { return .skip("no-read") }
        if now.pid != shown.pid { return .skip("pid") }
        if now.bundleID != shown.bundleID { return .skip("bundle") }
        if !sameElement { return .skip("element") }
        if now.text != shown.text { return .skip("text") }
        return .replace
    }

    /// The whole text of the field is selected: the range starts at 0 and covers `length` UTF-16 units.
    public static func selectionCoversAll(location: Int, length: Int, textUTF16: Int) -> Bool {
        location == 0 && length == textUTF16 && textUTF16 > 0
    }

    // MARK: Keys

    public enum KeyAction: Equatable, Sendable {
        case accept        // Tab: replace
        case dismiss       // Esc: keep my text
        case textChanged   // the field's text changes: start over
        case sent          // Return: the message leaves, nothing to show
        case ignore
    }

    /// Return/Enter are never swallowed — the caller passes every key on except `.accept` / `.dismiss` while the line is visible.
    public static func classify(keyCode: Int, command: Bool, control: Bool, option: Bool, printable: Bool, panelVisible: Bool) -> KeyAction {
        let noMods = !command && !control && !option
        if noMods, keyCode == 48 { return panelVisible ? .accept : .ignore }
        if noMods, keyCode == 53 { return panelVisible ? .dismiss : .ignore }
        if keyCode == 36 || keyCode == 76 { return .sent }
        if keyCode == 51 || keyCode == 117 { return .textChanged }      // backspace, forward delete
        if command {
            return [9, 7, 6, 16].contains(keyCode) ? .textChanged : .ignore // ⌘V ⌘X ⌘Z ⌘Y
        }
        if printable, !control { return .textChanged }
        return .ignore
    }

    // MARK: Texts (shown in the line)

    public static let hint = "Tab — вставить, Esc — оставить"
    public static let selectFailed = "Поле не даёт выделить текст — перевод не вставлен"
    public static let changedMeanwhile = "Текст в поле изменился — перевод не вставлен"

    /// «→ EN».
    public static func label(for target: Language) -> String { "→ " + target.rawValue.uppercased() }

    /// «Перевод при наборе: включён для Slack».
    public static func toggleNotice(appName: String, on: Bool) -> String {
        "Перевод при наборе: " + (on ? "включён" : "выключен") + " для " + appName
    }
    public static let unavailableHere = "Перевод при наборе здесь недоступен"
}

extension SelfTest {
    static func typeTranslate(_ check: Check) {
        typealias T = TypeTranslate
        // Partner detection
        let screen = """
        Anna Müller 10:41
        Hi! Could you send me the updated invoice before Friday?
        Вы 10:43
        Конечно, отправлю сегодня вечером.
        """
        let p = T.partner(screen: screen, draft: "Хорошо, договорились")
        check(p?.language == .english, "type-translate: partner language is the foreign one", "\(String(describing: p))")
        check(p?.message.contains("updated invoice") == true, "type-translate: partner message is the foreign line")
        check(p?.message.contains("Конечно") != true, "type-translate: own earlier message is not the partner's")
        check(T.partner(screen: "Anna Müller\n10:41\nReply", draft: "Привет, как дела?") == nil, "type-translate: chrome lines are not messages")
        check(T.partner(screen: "", draft: "Привет, как дела?") == nil, "type-translate: no screen text, no partner")
        let withDraft = "Hello there, nice to meet you today\nПривет, рад познакомиться с вами"
        check(T.partner(screen: withDraft, draft: "Привет, рад познакомиться с вами")?.message == "Hello there, nice to meet you today",
              "type-translate: the draft's own line on screen is skipped")
        let two = "Let me know when you can join the call.\nWe also need the budget numbers soon."
        check(T.partner(screen: two, draft: "Хорошо, сделаю")?.message.contains("join the call") == true, "type-translate: consecutive lines of one message are joined")
        check(T.screenIsAllSameLanguage(screen: "Привет, как твои дела сегодня?\nВсё хорошо, спасибо большое", draft: "Отлично, увидимся завтра"),
              "type-translate: a Russian screen is the same language as a Russian draft")
        check(!T.screenIsAllSameLanguage(screen: screen, draft: "Хорошо, договорились"), "type-translate: mixed screen is not all the same language")
        check(!T.screenIsAllSameLanguage(screen: "", draft: "Привет, мир"), "type-translate: empty screen is unknown, not the same")

        // Decision
        let en = T.Partner(message: "Could you send the invoice?", language: .english)
        let ru = "Хорошо, отправлю счёт сегодня вечером"
        func d(_ text: String, _ partner: T.Partner?, known: Bool = true, on: Bool = true, auto: Bool = false) -> T.Verdict {
            T.decide(text: text, partner: partner, screenKnown: known, primary: .russian, secondary: .english, explicitlyOn: on, auto: auto)
        }
        check(d(ru, en) == .translate(source: .russian, target: .english), "type-translate: RU draft, EN partner -> RU→EN")
        check(d("Gut, ich schicke die Rechnung heute Abend", en) == .translate(source: .german, target: .english),
              "type-translate: other source language is translated")
        check(d("Okay, I will send the invoice tonight", en) == .silent(.sameLanguage), "type-translate: text already in the partner's language is silent")
        check(d(ru, nil, known: true) == .silent(.sameLanguage), "type-translate: all-Russian screen is silent")
        check(d(ru, nil, known: false) == .translate(source: .russian, target: .english), "type-translate: unknown screen -> secondaryLanguage")
        check(d("Okay, I will send it tonight", nil, known: false) == .translate(source: .english, target: .russian), "type-translate: unknown screen, text in secondary -> primary")
        check(d("  ", en) == .silent(.empty), "type-translate: blank text is silent")
        check(d("ок", en) == .silent(.tooShort), "type-translate: tiny text is silent")
        check(d(String(repeating: "слово ", count: 400), en) == .silent(.tooLong), "type-translate: huge text is silent")
        check(d(ru, en, on: false, auto: false) == .silent(.disabled), "type-translate: off app stays off")
        check(d(ru, en, on: false, auto: true) == .translate(source: .russian, target: .english), "type-translate: auto + foreign partner turns on")
        check(d(ru, nil, known: false, on: false, auto: true) == .silent(.disabled), "type-translate: auto without a foreign partner stays off")
        let req = T.request(text: ru, source: .russian, target: .english, partner: en, tone: .chat, threadContext: "ctx")
        check(req.replyTo == en.message && req.threadContext == "ctx" && req.tone == .chat && req.target == .english && req.source == .russian,
              "type-translate: request carries reply, tone, thread context")

        // Per-app state
        var apps: [String: Bool] = [:]
        apps = T.toggled(apps, bundleID: "a.b")
        check(apps["a.b"] == true && T.anyEnabled(apps), "type-translate: first toggle turns on")
        apps = T.toggled(apps, bundleID: "a.b")
        check(apps["a.b"] == false && !T.anyEnabled(apps), "type-translate: second toggle turns off, keeps the entry")

        // Debounce
        var pl = T.DebouncePlanner(delay: 0.5)
        let g1 = pl.change(at: 10.0)
        let g2 = pl.change(at: 10.3)
        check(!pl.isCurrent(g1) && pl.isCurrent(g2), "type-translate: a new change makes the old wake-up stale")
        check(!pl.fire(g1, at: 10.6), "type-translate: stale generation never fires")
        check(!pl.fire(g2, at: 10.7), "type-translate: not due before the pause is over")
        check(abs((pl.remaining(at: 10.7) ?? -1) - 0.1) < 0.001, "type-translate: remaining time is reported")
        check(pl.fire(g2, at: 10.8), "type-translate: fires after 500 ms of quiet")
        check(!pl.fire(g2, at: 11.5) && pl.remaining(at: 11.5) == nil, "type-translate: fires once")
        let g3 = pl.change(at: 20); pl.cancel()
        check(!pl.fire(g3, at: 21), "type-translate: cancel drops the wake-up")

        // Replace check
        let shown = T.FieldSnapshot(pid: 5, bundleID: "a.b", text: ru)
        check(T.decideReplace(shown: shown, now: shown, sameElement: true) == .replace, "type-translate: same field replaces")
        check(T.decideReplace(shown: shown, now: nil, sameElement: true) == .skip("no-read"), "type-translate: failed read skips")
        check(T.decideReplace(shown: shown, now: .init(pid: 6, bundleID: "a.b", text: ru), sameElement: true) == .skip("pid"), "type-translate: other process skips")
        check(T.decideReplace(shown: shown, now: .init(pid: 5, bundleID: "c.d", text: ru), sameElement: true) == .skip("bundle"), "type-translate: other bundle skips")
        check(T.decideReplace(shown: shown, now: shown, sameElement: false) == .skip("element"), "type-translate: other element skips")
        check(T.decideReplace(shown: shown, now: .init(pid: 5, bundleID: "a.b", text: ru + "!"), sameElement: true) == .skip("text"), "type-translate: any text change skips")
        check(T.selectionCoversAll(location: 0, length: 12, textUTF16: 12), "type-translate: full selection accepted")
        check(!T.selectionCoversAll(location: 0, length: 11, textUTF16: 12) && !T.selectionCoversAll(location: 1, length: 11, textUTF16: 12), "type-translate: partial selection refused")
        check(!T.selectionCoversAll(location: 0, length: 0, textUTF16: 0), "type-translate: empty field is not a selection")

        // Keys
        func k(_ code: Int, cmd: Bool = false, ctrl: Bool = false, opt: Bool = false, printable: Bool = false, visible: Bool = true) -> T.KeyAction {
            T.classify(keyCode: code, command: cmd, control: ctrl, option: opt, printable: printable, panelVisible: visible)
        }
        check(k(48) == .accept && k(48, visible: false) == .ignore, "type-translate: Tab accepts only while the line is visible")
        check(k(53) == .dismiss && k(53, visible: false) == .ignore, "type-translate: Esc dismisses only while the line is visible")
        check(k(48, opt: true) == .ignore, "type-translate: ⌥Tab is not ours")
        check(k(36) == .sent && k(76) == .sent && k(36, visible: false) == .sent, "type-translate: Return is never swallowed (only reported)")
        check(k(0, printable: true) == .textChanged && k(51) == .textChanged && k(117) == .textChanged, "type-translate: typing and deleting change the text")
        check(k(9, cmd: true) == .textChanged && k(0, cmd: true) == .ignore, "type-translate: ⌘V changes the text, ⌘A does not")
        check(k(0, ctrl: true, printable: true) == .ignore && k(123) == .ignore, "type-translate: ⌃-keys and arrows are ignored")
        check(T.label(for: .english) == "→ EN" && T.label(for: .german) == "→ DE", "type-translate: language label")
        check(T.toggleNotice(appName: "Slack", on: true).contains("включён") && T.toggleNotice(appName: "Slack", on: false).contains("выключен"), "type-translate: toggle notice")
    }
}
