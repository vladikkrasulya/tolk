// Self-tests for the "tails" batch: final whole-text pass, time zones in windows, thread memory in Reply, unified texts.
import Foundation

extension SelfTest {
    static func tails(_ check: Check) {
        finalPassChecks(check)
        timezoneLineChecks(check)
        replyThreadChecks(check)
        serverTextChecks(check)
    }

    static func finalPassChecks(_ check: Check) {
        let two = "Привет. Как дела?"
        check(FinalPass.shouldRun(text: two, hadPartials: true), "final pass: 2 sentences + partials → run")
        check(!FinalPass.shouldRun(text: two, hadPartials: false), "final pass: no partials in this session → skip")
        check(!FinalPass.shouldRun(text: "Привет, как дела", hadPartials: true), "final pass: one sentence → skip")
        check(!FinalPass.shouldRun(text: "", hadPartials: true), "final pass: empty → skip")
        let long = String(repeating: "Это предложение. ", count: 40)
        check(long.count > FinalPass.maxChars && !FinalPass.shouldRun(text: long, hadPartials: true), "final pass: > 600 chars → skip")
        let edge = String(repeating: "Да. ", count: 150) // 600 chars exactly after trimming = 599
        check(FinalPass.shouldRun(text: edge, hadPartials: true) == (edge.trimmingCharacters(in: .whitespaces).count <= 600), "final pass: 600-char boundary")
        check(!FinalPass.differs(shown: "Hello. How are you?", final: "Hello.  How are you?\n"), "final pass: whitespace-only difference → no replace")
        check(FinalPass.differs(shown: "Hello. How are you?", final: "Hi. How are you doing?"), "final pass: real difference → replace")
        check(!FinalPass.differs(shown: "Hello.", final: "  "), "final pass: empty result never replaces")
        check(FinalPass.pause == 2.5, "final pass: pause 2.5 s")
        // Session: after the final pass the whole text is the base for the next partial plan.
        let s = IncrementalSession()
        let key = "k"
        let t1 = "Привет. Как дела?"
        let p1 = s.plan(for: t1, key: key)
        s.commit(p1, translation: "Hi. How are you?")
        let t2 = "Привет. Как дела? Что нового?"
        let p2 = s.plan(for: t2, key: key)
        check(p2.kind == .partial, "final pass: typing after a commit is partial")
        s.commit(p2, translation: "What's new?")
        s.reset()
        let pf = s.plan(for: t2, key: key)
        s.commit(pf, translation: "Hi. How are you? What's new?")
        let t3 = t2 + " Увидимся."
        let p3 = s.plan(for: t3, key: key)
        check(p3.kind == .partial && p3.keptTranslation.hasPrefix("Hi. How are you?"), "final pass: adopted translation is the base of the next plan", p3.keptTranslation)
    }
}

extension SelfTest {
    static func timezoneLineChecks(_ check: Check) {
        let now = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!
        let kyiv = TimeZone(identifier: "Europe/Kyiv")!
        let l1 = TimezoneLine.lines(in: "Let's meet at 10:00 EST tomorrow", now: now, localZone: kyiv)
        check(l1 == ["10:00 EST → 17:00 у вас"], "tz line: EST → local", "\(l1)")
        check(TimezoneLine.lines(in: "Call at 3pm CST", now: now, localZone: kyiv).isEmpty, "tz line: ambiguous zone is not shown")
        check(TimezoneLine.lines(in: "Привет, как дела", now: now, localZone: kyiv).isEmpty, "tz line: no digits → nothing")
        check(TimezoneLine.lines(in: "в 15:00 по Киеву", now: now, localZone: kyiv).isEmpty, "tz line: same as local → nothing")
        let two = TimezoneLine.lines(in: "10:00 EST or 10:00 EST, then 11:00 PST", now: now, localZone: kyiv)
        check(two.count == 2, "tz line: duplicates collapse", "\(two)")
        let many = TimezoneLine.lines(in: "9:00 EST, 10:00 EST, 11:00 EST, 12:00 EST", now: now, localZone: kyiv)
        check(many.count == 3, "tz line: at most 3 lines", "\(many)")
        let day = TimezoneLine.lines(in: "at 22:00 PST", now: now, localZone: kyiv)
        check(day.first?.contains("(завтра)") == true, "tz line: next-day marker kept", "\(day)")
    }
}

extension SelfTest {
    /// How the «Ответить» window uses ThreadMemory: context for the partner's message = the lines BEFORE it.
    static func replyThreadChecks(_ check: Check) {
        let mem = ThreadMemory()
        let app = "com.tinyspeck.slackmacgap"
        mem.record(source: "Can we raise the floor on them?", translation: "Можем поднять флор на них?", from: .english, to: .russian, app: app)
        mem.record(source: "What about them?", translation: "А что насчёт них?", from: .english, to: .russian, app: app) // the popup recorded the partner's message
        let ctx = mem.context(for: "What about them?", app: app)
        check(ctx?.contains("raise the floor") == true, "reply thread: earlier chat lines are the context", ctx ?? "nil")
        check(ctx?.contains("What about them?") == false, "reply thread: the partner's message itself is not its own context", ctx ?? "nil")
        check(mem.context(for: "What about them?", app: "com.apple.mail")?.isEmpty ?? true, "reply thread: another app has no context")
        check(mem.context(for: "What about them?", app: nil) == nil, "reply thread: no app → no context")
        // The reply the user pastes becomes a line for the next message.
        mem.record(source: "Давай завтра", translation: "Let's do it tomorrow", from: .russian, to: .english, app: app)
        let next = mem.context(for: "And on Friday?", app: app)
        check(next?.contains("Let's do it tomorrow") == true && next?.contains("raise the floor") == true, "reply thread: own reply joins the context", next ?? "nil")
        let long = String(repeating: "word ", count: 40)
        check(mem.context(for: long, app: app) == nil, "reply thread: a long partner message gets no context")
    }
}

extension SelfTest {
    static func serverTextChecks(_ check: Check) {
        check(ServerText.unavailable == "vkbox недоступен", "server text: one name for the state")
        check(ServerText.menuLine(available: true, model: "Gemma", fallback: "Google") == "● Переводит Gemma (vkbox)", "server text: menu, available")
        check(ServerText.menuLine(available: false, model: "Gemma", fallback: nil) == "○ vkbox недоступен", "server text: menu, no fallback")
        check(ServerText.menuLine(available: false, model: "Gemma", fallback: "Apple") == "○ vkbox недоступен — переводит Apple", "server text: menu, fallback")
        check(ServerText.switching() == "vkbox недоступен — переключаюсь на запасной перевод", "server text: switching")
        check(ServerText.switched(to: "Google") == "vkbox недоступен — перевод от Google", "server text: switched")
        for raw in ["vkbox не ответил", "Ollama недоступна", "модель не отвечает (таймаут)", "связь с vkbox оборвалась"] {
            check(ServerText.statusReason(raw).hasPrefix("vkbox"), "server text: status reason «\(raw)» speaks about vkbox", ServerText.statusReason(raw))
        }
        check(ServerText.statusReason("модель не отвечает (таймаут)") == "vkbox не успел ответить", "server text: timeout wording")
        check(ServerText.statusReason("vkbox недоступен (нет связи)") == "vkbox недоступен", "server text: reasons with the name collapse")
        check(ServerText.hudFallback(progress: "переводю… (Google)") == "vkbox недоступен — переводю… (Google)", "server text: HUD")
        check(ServerText.needsServer("причесать текст") == "vkbox недоступен — причесать текст без него нельзя", "server text: needs server")
        check(ServerText.homeOnly("Разбор смысла").hasPrefix("Разбор смысла делает домашняя модель"), "server text: home-only feature")
        check(EscText.closeHint == "Esc — закрыть" && EscText.cancelHint == "Esc — отмена", "esc text: two phrases")
        // Every state-phrase in the file set must come out of the one source: no stray variants of the old wording.
        for s in [ServerText.switching(), ServerText.unavailable, ServerText.menuChecking] {
            check(!s.contains("не ответил") && !s.contains("Модель на vkbox"), "server text: no legacy phrase in «\(s)»")
        }
    }
}
