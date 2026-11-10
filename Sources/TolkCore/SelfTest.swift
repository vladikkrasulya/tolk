// Engine self-test: `tolk-cli --self-test`. Command Line Tools ship neither XCTest nor Swift Testing that `swift test`
// can use, so the checks live here (internal APIs are visible) and run from the CLI; exit code 1 on any failure.
// No network, no model, no files.
import Foundation

public enum SelfTest {
    final class Check {
        var total = 0
        var failures: [String] = []
        func callAsFunction(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { let d = detail(); failures.append(name + (d.isEmpty ? "" : " — " + d)) }
        }
    }

    public static func run() -> (total: Int, failures: [String]) {
        let check = Check()
        glossary(check)
        prompts(check)
        detection(check)
        translationChecks(check)
        splitter(check)
        incremental(check)
        autocompleteSafety(check)
        autocompleteServer(check)
        refineGuard(check)
        bigWindow(check)
        return (check.total, check.failures)
    }

    // MARK: Editor-pass guard

    static func refineGuard(_ check: Check) {
        let ok = RefineGuard.accepts
        check(ok("Hello, how are you?", "Hello, how are you?"), "refine guard: unchanged text accepted")
        check(ok("Hello, can you send it?", "Hello, could you send it over?"), "refine guard: a normal rewording accepted")
        check(!ok("Can you call me?", "Call me."), "refine guard: question turned into a statement rejected")
        check(!ok("Привет! Ты не забыл купить хлеб?", "Привет! Не забудь купить хлеб."), "refine guard: RU question turned into an order rejected")
        check(!ok("Hello, can you send it?", "Good afternoon, can you send it?"), "refine guard: Hello -> Good afternoon rejected")
        check(!ok("Привіт, як справи?", "Вітаю, як справи?"), "refine guard: Привіт -> Вітаю rejected")
        check(!ok("Здравствуйте, это заказ.", "Добрый день, это заказ."), "refine guard: Здравствуйте -> Добрый день rejected")
        check(ok("Good morning, all set.", "Good morning, everything is set."), "refine guard: same two-word greeting accepted")
        check(!ok("Hi, thanks.", "Thanks."), "refine guard: dropped greeting rejected")
        check(ok("Thanks for the update.", "Thank you for the update."), "refine guard: no greeting, no question accepted")
        check(!ok("Thanks.", "  "), "refine guard: empty edit rejected")
        check(ok("Hi there. Can you come? (please)?", "Hi there. Could you come?"), "refine guard: question kept accepted")
    }

    // MARK: Glossary

    static func hits(_ term: String, _ text: String) -> Bool {
        guard let re = RulesStore.pattern(for: term) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func glossary(_ check: Check) {
        for (t, s) in [("cap", "daily cap is 100"), ("cap", "Caps are low"), ("cap", "it was capped yesterday"), ("cap", "capping works"),
                       ("feed", "feed the cat"), ("feed", "feeds and feeding"), ("zone", "zone's id"), ("zone", "zoned and zoning"),
                       ("bid", "bidding is on"), ("bid", "raise the bids"), ("party", "third parties"),
                       ("traffic source", "new traffic sources"), ("daily cap", "the daily caps"),
                       ("to scale", "we want to scale traffic"), ("to scale", "Time to scale."),
                       ("капа", "дай капу"), ("капа", "капы нет"), ("капа", "с капой"), ("капа", "Капа"),
                       ("постбек", "постбеки не приходят"), ("постбек", "постбеков нет"),
                       ("дневная капа", "дневную капу подняли"), ("трафик", "нет трафика")] {
            check(hits(t, s), "glossary: «\(t)» matches «\(s)»", "")
        }
        for (t, s) in [("cap", "the capital city"), ("cap", "capacity"), ("cap", "escape"), ("cap", "capture"),
                       ("feed", "feedback"), ("feed", "feeder"), ("zone", "ozone"), ("bid", "bidet"),
                       ("to scale", "to scale back on work"), ("to scale", "to scale away"), ("to scale", "scale"),
                       ("капа", "капитал"), ("капа", "капитана"), ("капа", "капсула"), ("постбек", "постбековый вариант")] {
            check(!hits(t, s), "glossary: «\(t)» does not match «\(s)»", "")
        }
        let parsed = RulesStore.parse("## Glossary\n- cap / daily cap → капа / дневная капа\n- feed → фид; zone → зона\n- to scale → масштабировать\n- creative → креатив\n")
        let text = "I'd like to offer you a creative idea: let's feed the cat, then drive to the capital and find a quiet zone to scale back on work."
        let range = NSRange(text.startIndex..., in: text)
        let matched = parsed.glossary.filter { $0.patterns.contains { $0.firstMatch(in: text, range: range) != nil } }.map(\.text)
        check(!matched.contains { $0.contains("cap /") }, "glossary: «cap» line does not fire on «capital»", "\(matched)")
        check(!matched.contains { $0.contains("to scale") }, "glossary: «to scale» line does not fire on «scale back»", "\(matched)")
    }

    // MARK: Prompts

    static func prompts(_ check: Check) {
        let banned = ["adtech", "kadam", "kaminari", "grafana", "adsecure", "partner", "payout", "publisher"]
        func clean(_ s: String, _ name: String) {
            let l = s.lowercased()
            check(!banned.contains { l.contains($0) }, "prompt without adtech: \(name)", banned.filter { l.contains($0) }.joined(separator: ","))
        }
        for (src, dst) in [(Language.russian, Language.english), (.english, .russian), (.english, .ukrainian), (.ukrainian, .english)] {
            for tone in Tone.allCases {
                let r = ResolvedRequest(text: "x", source: src, target: dst, tone: tone, replyTo: "How are you?")
                clean(Prompt.system(for: r, rules: ""), "translate \(src.rawValue)→\(dst.rawValue) \(tone.rawValue)")
            }
        }
        clean(Prompt.system(for: ResolvedRequest(text: "x", source: .english, target: .english, tone: .auto, mode: .polish), rules: ""), "polish")
        clean(NotesPrompt.system(from: .english, to: .russian, rules: ""), "notes")
        clean(RefinePrompt.system(from: .english, to: .russian, tone: .auto, rules: ""), "refine")

        let plain = Prompt.system(for: ResolvedRequest(text: "x", source: .russian, target: .english, tone: .auto), rules: "")
        check(!plain.contains("CONTINUATION"), "prompt: no context section without context")
        let ctx = TranslationContext(source: "Привет! Как дела?", translation: "Hi! How are you?")
        let withCtx = Prompt.system(for: ResolvedRequest(text: "У тебя сегодня?", source: .russian, target: .english, tone: .auto, context: ctx), rules: "")
        check(withCtx.contains("CONTINUATION") && withCtx.contains("Привет! Как дела?") && withCtx.contains("Hi! How are you?"),
              "prompt: context section has the beginning and its translation")
        check(withCtx.contains("ONLY") && withCtx.lowercased().contains("do not repeat"), "prompt: context says translate only the new text")
        check(withCtx.lowercased().contains("gender") && withCtx.lowercased().contains("formality"), "prompt: context asks for consistency")
        check(plain.lowercased().contains("native"), "prompt: anti-calque guidance")
        let ru = Prompt.system(for: ResolvedRequest(text: "x", source: .english, target: .russian, tone: .auto), rules: "")
        check(ru.contains("English-shaped"), "prompt: Russian target warns against English-shaped constructions")
        check(plain.contains("Slavic word order"), "prompt: English target warns against Slavic word order")

        // Glossary selection by the new text plus the context source.
        let store = RulesStore(path: "/nonexistent/rules.md", builtIn: "## Glossary\n- postback → постбек\n- cap → капа\n")
        check(store.promptBlock(for: "no terms here", target: .russian).isEmpty, "rules: no hits, no glossary")
        check(store.promptBlock(for: "no terms\npostback", target: .russian).contains("postback"), "rules: context source selects lines")
        check(store.usesBuiltIn, "rules: built-in used when the file is missing")
    }

    // MARK: Language detection

    static func detection(_ check: Check) {
        check(LanguageDetector.detect("Привет, как дела? Ты не забыл забрать посылку?") == .russian, "detect: Russian")
        check(LanguageDetector.detect("Привіт, як справи? Ти не забув забрати посилку? Вечерю розігрій сам.") == .ukrainian, "detect: Ukrainian")
        check(LanguageDetector.detect("Did you pick up the package today? Let me know if that works.") == .english, "detect: English")
        check(LanguageDetector.detect("Вечерю розігрій сам.") == .ukrainian, "detect: short Ukrainian")
        check(LanguageDetector.detect("Ужин разогрей сам, пожалуйста.") == .russian, "detect: short Russian")
        check(LanguageDetector.detect("Hi Anna, see https://example.com/a1 at 14:30") == .english, "detect: English with link and time")
    }

    // MARK: Translation check

    static func translationChecks(_ check: Check) {
        func w(_ s: String, _ t: String, _ from: Language = .english, _ to: Language = .russian) -> [String] {
            TranslationCheck.warnings(source: s, translation: t, from: from, to: to)
        }
        func has(_ ws: [String], _ part: String) -> Bool { ws.contains { $0.contains(part) } }

        check(has(w("The order costs 1500 USD today", "Заказ стоит сегодня"), "1500"), "check: lost number")
        check(has(w("The order costs 1500 USD today", "Заказ стоит 1600 USD сегодня"), "1500"), "check: changed number")
        check(has(w("Discount is 25% on all items", "Скидка на все товары"), "25"), "check: lost percentage")
        check(has(w("Details: https://example.com/page?id=5 thanks", "Подробности: смотрите на сайте, спасибо"), "ссылка"), "check: lost URL")
        check(has(w("Write to anna@example.com please", "Напишите Анне, пожалуйста"), "e-mail"), "check: lost e-mail")
        check(has(w("Ask @vlad_k about it", "Спросите об этом у Влада"), "@vlad_k"), "check: lost @handle")
        check(has(w("Tracking number AB-12345-US shipped", "Номер отправления отгружен"), "AB-12345-US"), "check: lost ID")
        check(has(w("Meet me at 14:30 at the station", "Встретимся на вокзале"), "14:30"), "check: lost time")
        check(has(w("Born on 12.05.2019 in Lviv", "Родился во Львове"), "2019"), "check: lost year")
        check(has(w("Привіт, як справи? Ти не забув забрати посилку? Вечерю розігрій сам.", "Привет, как дела? Ты не забыл забрать посылку? Ужин разогрей сам, пожалуйста.", .ukrainian, .ukrainian), "русский вместо украинского"),
              "check: Russian instead of Ukrainian")
        check(has(w("Привет, как дела? Ты не забыл забрать посылку из магазина?", "Привет, как дела? Ты не забыл забрать посылку из магазина?", .russian, .english), "кириллица"),
              "check: untranslated Cyrillic for English target")
        check(has(w("Hi, how are you doing today? Did you pick up the package?", "Hi, how are you doing today? Did you pick up the package?", .english, .russian), "латиница"),
              "check: untranslated English for Russian target")
        let long = "The weather is lovely today, so we decided to take a long walk along the river and then have lunch in the old town near the market."
        check(has(w("Погода сегодня прекрасная, поэтому мы решили долго гулять вдоль реки, а потом пообедать в старом городе рядом с рынком.", long, .russian, .german), "вместо"),
              "check: English instead of German (NaturalLanguage)")

        // No false alarms.
        let clean: [(String, String, Language, Language)] = [
            ("Hi, how are you?", "Привет, как дела?", .english, .russian),
            ("Ok", "Ок", .english, .russian),
            ("I have two kids and three cats", "У меня двое детей и три кота", .english, .russian),
            ("Pay 1,500 UAH by 14:30", "Заплати 1 500 грн до 14:30", .english, .russian),
            ("Заплати 1 500 грн до 14:30", "Pay UAH 1,500 by 2:30 PM", .russian, .english),
            ("Комиссия 0,02 %, итого 8 416,20 USD", "The fee is 0.02%, total USD 8,416.20", .russian, .english),
            ("Total: $1,234.50", "Итого: 1234,50 $", .english, .russian),
            ("Meet at 8 pm on 12.05.2024", "Встретимся 12 мая 2024 в 20:00", .english, .russian),
            ("Call +380 50 123 45 67 or visit www.example.com.", "Позвони по номеру +380 50 123 45 67 или зайди на example.com", .english, .russian),
            ("Order #4521 arrives on the 3rd", "Заказ #4521 приедет 3-го", .english, .russian),
            ("Ти не забув забрати посилку? Вечерю розігрій сам.", "Did you forget to pick up the package? Heat up dinner yourself.", .ukrainian, .english),
            ("It makes sense to meet earlier, let me know if that works.", "Имеет смысл встретиться пораньше, дай знать, подойдёт ли.", .english, .russian),
            ("Привіт! Дякую за листа.", "Привіт! Дякую за листа.", .ukrainian, .ukrainian),
            ("Visit https://example.com/page.", "Зайдите на https://example.com/page.", .english, .russian),
            ("Email: Anna@Example.com", "Почта: anna@example.com", .english, .russian),
            ("Up to $50k monthly, $1.2M total", "Ежемесячно до 50 000 USD, всего 1 200 000 USD", .english, .russian),
            ("До 50 000 USD, всего 1,5 млн", "Up to $50k, total $1.5M", .russian, .english),
            ("Если снизить флор до 15 центов, объём вырастет", "If we drop the floor to $0.15, volume will grow", .russian, .english),
            ("See you in 10 minutes", "Увидимся через десять минут", .english, .russian),
        ]
        for (s, t, f, to) in clean {
            let ws = w(s, t, f, to)
            check(ws.isEmpty, "check: no false alarm «\(s.prefix(30))»", ws.joined(separator: "; "))
        }
    }

    // MARK: Sentence splitter

    static func splitter(_ check: Check) {
        let samples = ["Hello world. How are you? Fine!", "Line one\nLine two\n\nLine three", "Dr. Smith went home. He slept.",
                       "  leading space. Next", "", "No punctuation", "Hi 👋. Ok", "т.д. и т.п. Конец", "Trailing newline.\n",
                       "One.  Two.   Three.", "a\n\n\nb", "Ціна 1.5 грн. Дякую!", "https://example.com/a.b. Next one."]
        for s in samples {
            let parts = SentenceSplitter.split(s)
            check(parts.joined() == s, "splitter: joined == text for «\(s.debugDescription)»", "\(parts)")
        }
        check(SentenceSplitter.split("Hello world. How are you? Fine!").count == 3, "splitter: three sentences")
        check(SentenceSplitter.split("Line one\nLine two\n\nLine three").count == 3, "splitter: newlines separate")
        check(SentenceSplitter.split("Dr. Smith went home. He slept.").count == 2, "splitter: abbreviation «Dr.» does not split",
              "\(SentenceSplitter.split("Dr. Smith went home. He slept."))")
        check(SentenceSplitter.split("Ціна 1.5 грн. Дякую!").count == 2, "splitter: decimal point does not split")
        check(SentenceSplitter.split("").isEmpty || SentenceSplitter.split("") == [""], "splitter: empty text")
    }

    // MARK: Incremental session

    static func incremental(_ check: Check) {
        let k = "ru>en|chat"
        func fresh() -> IncrementalSession {
            let s = IncrementalSession()
            let p = s.plan(for: "Hello world. How are you.", key: k)
            s.commit(p, translation: "Привет, мир. Как дела.")
            return s
        }
        // First plan is full.
        let s0 = IncrementalSession()
        let p0 = s0.plan(for: "Hello world. How are you.", key: k)
        check(p0.kind == .full && p0.changedSource == "Hello world. How are you." && p0.context == nil, "incremental: first plan is full")

        // Append to the last sentence → only it is sent, with the first as context.
        var s = fresh()
        var p = s.plan(for: "Hello world. How are you today.", key: k)
        check(p.kind == .partial && p.changedSource == "How are you today." && p.keptSource == "Hello world. ", "incremental: append to last sentence",
              "\(p.kind) «\(p.changedSource)» kept «\(p.keptSource)»")
        check(p.keptTranslation == "Привет, мир. " && p.context == TranslationContext(source: "Hello world. ", translation: "Привет, мир. "),
              "incremental: context of a partial plan", "«\(p.keptTranslation)»")

        // New sentence → only the new one.
        s = fresh()
        p = s.plan(for: "Hello world. How are you. Fine, thanks.", key: k)
        check(p.kind == .partial && p.changedSource == "Fine, thanks." && p.keptTranslation == "Привет, мир. Как дела. ", "incremental: new sentence only",
              "\(p.kind) «\(p.changedSource)» «\(p.keptTranslation)»")
        s.commit(p, translation: "Хорошо, спасибо.")
        p = s.plan(for: "Hello world. How are you. Fine, thanks. And you?", key: k)
        check(p.kind == .partial && p.changedSource == "And you?" && p.keptTranslation.hasSuffix("Хорошо, спасибо. "), "incremental: commit extends the cache",
              "«\(p.changedSource)» «\(p.keptTranslation)»")

        // Edit of the first sentence → full.
        s = fresh()
        p = s.plan(for: "Hi world. How are you.", key: k)
        check(p.kind == .full && p.changedSource == "Hi world. How are you.", "incremental: edit of the first sentence is full")

        // Whitespace / case / trailing full stop only → unchanged.
        s = fresh()
        p = s.plan(for: "hello   world. How are you", key: k)
        check(p.kind == .unchanged && p.keptTranslation == "Привет, мир. Как дела.", "incremental: whitespace/case/full stop is unchanged",
              "\(p.kind) «\(p.keptTranslation)»")
        s = fresh()
        p = s.plan(for: "Hello world. How are you.   \n", key: k)
        check(p.kind == .unchanged, "incremental: trailing whitespace is unchanged")

        // Deleted tail → unchanged with the shortened translation.
        s = fresh()
        p = s.plan(for: "Hello world.", key: k)
        check(p.kind == .unchanged && p.keptTranslation == "Привет, мир.", "incremental: deleted tail", "\(p.kind) «\(p.keptTranslation)»")
        p = s.plan(for: "Hello world. Something new.", key: k)
        check(p.kind == .partial && p.changedSource == "Something new." && p.keptTranslation == "Привет, мир. ", "incremental: typing again after a deleted tail",
              "\(p.kind) «\(p.changedSource)» «\(p.keptTranslation)»")

        // Key change → full.
        s = fresh()
        check(s.plan(for: "Hello world. How are you.", key: "ru>en|formal").kind == .full, "incremental: key change is full")

        // Reset → full.
        s = fresh(); s.reset()
        check(s.plan(for: "Hello world. How are you.", key: k).kind == .full, "incremental: reset is full")

        // Stale commit is ignored.
        s = IncrementalSession()
        let a = s.plan(for: "One. Two.", key: k)
        let b = s.plan(for: "One. Two. Three.", key: k)
        s.commit(a, translation: "Раз. Два.")
        check(s.plan(for: "One. Two.", key: k).kind == .full, "incremental: stale commit ignored")
        _ = b

        // Sentence count mismatch → the block stays whole.
        s = IncrementalSession()
        let m = s.plan(for: "First part. Second part.", key: k)
        s.commit(m, translation: "Одно целое предложение без точки")
        check(s.plan(for: "First part. Second part. Third.", key: k).kind == .partial, "incremental: block kept whole, appended sentence is partial")
        let mm = s.plan(for: "First part. Second changed.", key: k)
        check(mm.kind == .full, "incremental: edit inside a block retranslates it", "\(mm.kind)")
        s = IncrementalSession()
        let m2 = s.plan(for: "First part. Second part.", key: k)
        s.commit(m2, translation: "Одно целое предложение без точки")
        let mu = s.plan(for: "First part.  Second part", key: k)
        check(mu.kind == .unchanged && mu.keptTranslation == "Одно целое предложение без точки", "incremental: whole block unchanged")

        // Multi-line: the newline is the separator in the kept translation.
        s = IncrementalSession()
        let n = s.plan(for: "Привет.\nКак дела?", key: k)
        s.commit(n, translation: "Hello.\nHow are you?")
        let n2 = s.plan(for: "Привет.\nКак дела?\nПока.", key: k)
        check(n2.kind == .partial && n2.keptTranslation == "Hello.\nHow are you?\n" && n2.changedSource == "Пока.", "incremental: newline kept between sentences",
              "\(n2.kind) «\(n2.keptTranslation.debugDescription)» «\(n2.changedSource)»")
    }
}
