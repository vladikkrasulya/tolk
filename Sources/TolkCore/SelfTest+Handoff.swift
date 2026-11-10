// Popup → big window handoff: the window repeats the popup's request, so the translation comes from the cache.
import Foundation

extension SelfTest {
    static func popupHandoff(_ check: Check) {
        let rules = RulesStore(path: "/nonexistent/rules.md", builtIn: "")
        let p = MockProvider()
        let e = DefaultTranslationEngine(config: TolkConfig(), rules: rules, primary: p, fallback: nil,
                                         cache: ResultCache(), notesCache: ResultCache())
        // Popup: tone switch on «Авто», the app (TextEdit) configured as «Чат» → request tone .chat.
        let h = PopupHandoff(text: "Hello world", source: nil, target: nil, requestTone: .chat, displayTone: .auto, threadContext: "A: hi")
        let first = drain(e, h.request())
        check(first.stats?.fromCache == false && p.calls == 1, "handoff: the popup's own request goes to the model")
        // The window builds its request from the same value (what TranslatePageViewController does with loadedTone/loadedThread).
        var page = TranslationRequest(text: h.text, source: h.source, target: h.target, tone: h.requestTone)
        if let t = h.threadContext, !t.isEmpty { page.threadContext = t }
        let second = drain(e, page)
        check(second.stats?.fromCache == true && p.calls == 1 && second.text == first.text, "handoff: window request = cache hit, no second model call")
        // What used to happen: window with its own saved tone («Чат» segment vs «Авто» request) → miss.
        var old = page; old.tone = .auto
        check(drain(e, old).stats?.fromCache == false, "handoff: a different tone is a different key (the old bug)")
        check(h.displayTone == .auto && h.requestTone == .chat, "handoff: window shows the popup's switch, requests with the resolved tone")
        let withLang = PopupHandoff(text: "Hello world", source: .english, target: .ukrainian, requestTone: .auto, displayTone: .auto, threadContext: nil)
        check(withLang.request().target == .ukrainian && withLang.request().source == .english && withLang.request().threadContext == nil,
              "handoff: languages carried over")
    }
}
