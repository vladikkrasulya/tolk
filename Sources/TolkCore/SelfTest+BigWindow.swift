// Self-test of the big-window engine: sentence pairs, parsing of saved model answers, rewrite guard. No model, no network.
import Foundation

extension SelfTest {
    static func bigWindow(_ check: Check) {
        // MARK: sentence pairs
        func pairTexts(_ s: String, _ t: String) -> [(String, String, Bool)] {
            SentencePairing.pairs(source: s, translation: t).map { p in
                (String(s[p.sourceRange(in: s)!]), String(t[p.translationRange(in: t)!]), p.isConfident)
            }
        }
        var p = pairTexts("Привет, Макс. Кампания стартует 15 марта, т. е. через неделю. Бюджет 1.5 млн.",
                          "Hi Max. The campaign starts on March 15, i.e. in a week. The budget is 1.5M.")
        check(p.count == 3 && p.allSatisfy { $0.2 }, "pairs RU→EN: 3 confident pairs (т. е., i.e., 1.5)", "\(p)")
        check(p.first?.1 == "Hi Max." && p[1].0.hasPrefix("Кампания") && p[1].0.hasSuffix("неделю."), "pairs RU→EN: ranges cut the right text", "\(p)")
        p = pairTexts("Check the report, e.g. the CTR. It dropped. Please fix it.", "Проверь отчёт, например CTR. Он упал. Пожалуйста, исправь это.")
        check(p.count == 3 && p[0].0.hasSuffix("the CTR."), "pairs EN→RU: «e.g.» does not split", "\(p)")
        p = pairTexts("Ціна 1.5 грн. Дякую! Побачимось?", "The price is 1.5 UAH. Thanks! See you?")
        check(p.count == 3 && p[0].0 == "Ціна 1.5 грн." && p[0].2, "pairs UK→EN: decimal and «!»/«?»", "\(p)")
        p = pairTexts("1. Send the report.\n2. Call the client.\n3. Update the docs.", "1. Отправить отчёт.\n2. Позвонить клиенту.\n3. Обновить доки.")
        check(p.count == 3 && p[1].0 == "2. Call the client.", "pairs: list items pair as one unit with their number", "\(p)")
        p = pairTexts("Hello!\n\nFirst line. Second one.\nThird.", "Привет!\n\nПервая строка. Вторая.\nТретья.")
        check(p.count == 4 && p.allSatisfy { $0.2 }, "pairs: paragraphs and line breaks", "\(p)")
        // Different counts: grouped by length, flagged as unsure.
        p = pairTexts("Привет. Это тест. А это ещё один.", "Hi. This is a test and one more.")
        check(p.count == 2 && p.contains { !$0.2 }, "pairs: 3 vs 2 sentences -> 2 groups, one unsure", "\(p)")
        check(p.first?.0 == "Привет." && p.first?.1 == "Hi.", "pairs: the short greeting still pairs with the short greeting", "\(p)")
        p = pairTexts("One. Two.", "Single long sentence here.")
        check(p.count == 1 && !p[0].2, "pairs: 2 vs 1 -> one unsure group", "\(p)")
        check(SentencePairing.pairs(source: "", translation: "x").isEmpty && SentencePairing.pairs(source: "x", translation: "  ").isEmpty, "pairs: blank text -> no pairs")
        let one = SentencePairing.pairs(source: "Hello", translation: "Привет")
        check(one.count == 1 && one[0].isConfident, "pairs: no punctuation, one pair")
        // Emoji / surrogate pairs: NSRange stays valid.
        let e = SentencePairing.pairs(source: "Hi 👋. Ok.", translation: "Привет 👋. Ок.")
        check(e.count == 2 && e[1].sourceRange(in: "Hi 👋. Ok.").map { String("Hi 👋. Ok."[$0]) } == "Ok.", "pairs: emoji do not shift ranges")
        // Ranges never overlap and stay in order.
        let ordered = SentencePairing.pairs(source: "A one. B two. C three. D four.", translation: "А раз. Б два. В три.")
        check(zip(ordered, ordered.dropFirst()).allSatisfy { $0.source.upperBound <= $1.source.location && $0.translation.upperBound <= $1.translation.location }, "pairs: ranges are ordered and disjoint")

        // MARK: saved model answers
        let vJSON = """
        {"variants":[{"text":"Кампания стартует 15 марта.","label":"ближе к тексту"},{"text":"Запускаем кампанию 15 марта.","label":"разговорнее"},{"text":"Старт кампании — 15 марта.","label":"короче"}]}
        """
        var vs = ExtrasParsing.variants(vJSON, sentence: "The campaign starts on March 15.", current: "Кампания начнётся 15 марта.", from: .english, to: .russian)
        check(vs.count == 3 && vs[1].label == "разговорнее", "variants: three labelled variants parsed", "\(vs)")
        vs = ExtrasParsing.variants("```json\n{\"variants\":[{\"text\":\"Кампания начнётся 15 марта!\",\"label\":\"x\"},{\"text\":\"Стартуем в марте.\",\"label\":\"\"},\"Старт 15 марта\"]}\n```",
                                    sentence: "The campaign starts on March 15.", current: "Кампания начнётся 15 марта.", from: .english, to: .russian)
        check(vs.map(\.text) == ["Старт 15 марта"], "variants: repeat of the current text and a variant that loses «15» dropped; plain string accepted; fenced JSON read", "\(vs)")
        check(vs.first?.label == "другой вариант", "variants: missing label gets a default")
        check(ExtrasParsing.variants("not json", sentence: "a", current: "b", from: .english, to: .russian).isEmpty, "variants: garbage -> empty")
        // MARK: whole-translation variants
        let tvSrc = "Hi Anna, could you send the report by 5 PM today? Thanks!"
        let tvCur = "Привет, Анна, можешь прислать отчёт до 17:00 сегодня? Спасибо!"
        let tvJSON = """
        {"variants":[{"label":"Строже","reason":"на «Вы», просьба как требование","text":"Здравствуйте, Анна. Не могли бы Вы прислать отчёт до 17:00 сегодня? Благодарю."},
        {"label":"Дружелюбнее","reason":"смягчено","text":"Анна, привет! Пришлёшь отчёт сегодня до 17:00? Спасибо!"},
        {"label":"Ближе к тексту","reason":"почти дословно","text":"Привет, Анна, можешь прислать отчёт до 17:00 сегодня? Спасибо!"}]}
        """
        var tv = ExtrasParsing.translationVariants(tvJSON, source: tvSrc, current: tvCur, from: .english, to: .russian)
        check(tv.count == 2 && tv[0].label == "Строже" && tv[0].reason.contains("Вы") && tv[1].label == "Дружелюбнее", "tvariants: parsed, the copy of the current translation dropped", "\(tv)")
        tv = ExtrasParsing.translationVariants("Вот:\n```json\n" + tvJSON + "\n```\nГотово.", source: tvSrc, current: tvCur, from: .english, to: .russian)
        check(tv.count == 2, "tvariants: fenced JSON with junk around is read", "\(tv)")
        tv = ExtrasParsing.translationVariants("[{\"label\":\"Короче\",\"reason\":\"r\",\"text\":\"Привет, Анна, отчёт до 17:00 сегодня?\"}, \"Привет, Анна, отчёт до 17:00 сегодня?\"]",
                                               source: tvSrc, current: tvCur, from: .english, to: .russian)
        check(tv.count == 1 && tv[0].label == "Короче", "tvariants: bare array read, duplicate of an earlier variant dropped", "\(tv)")
        let tvBad = """
        {"variants":[{"label":"a","reason":"r","text":"Привет, Анна, пришли отчёт сегодня."},
        {"label":"b","reason":"r","text":"Привет, Анна, можешь прислать отчёт до 18:00 сегодня. Спасибо!"},
        {"label":"c","reason":"r","text":"Анна, отправь отчёт до 17:00 сегодня. Спасибо!"},
        {"label":"d","reason":"r","text":"Привет, Анна, пришли отчёт до 17:00 сегодня, спасибо!"}]}
        """
        tv = ExtrasParsing.translationVariants(tvBad, source: tvSrc, current: tvCur, from: .english, to: .russian)
        check(tv.map(\.label) == ["d"], "tvariants: lost number, changed time and lost greeting are rejected (the one safe variant stays)", "\(tv.map(\.label))")
        check(ExtrasParsing.translationVariants("not json", source: "a", current: "b", from: .english, to: .russian).isEmpty
              && ExtrasParsing.translationVariants("{\"variants\":\"x\"}", source: "a", current: "b", from: .english, to: .russian).isEmpty, "tvariants: garbage -> empty")
        tv = ExtrasParsing.translationVariants("{\"variants\":[{\"text\":\"Здравствуйте\"},{\"text\":\"Добрый день\",\"label\":\"Очень длинная метка из пяти слов\"}]}",
                                               source: "Hello", current: "Привет", from: .english, to: .russian)
        check(tv.count == 2 && tv[0].label == "Другой вариант" && tv[0].reason.isEmpty && tv[1].label.split(separator: " ").count <= 3, "tvariants: default label, long label cut, a different greeting is allowed", "\(tv)")
        check(ExtrasParsing.translationVariants("{\"variants\":[{\"label\":\"x\",\"reason\":\"r\",\"text\":\"Пришли отчёт.\"},{\"label\":\"y\",\"reason\":\"r\",\"text\":\"Не могли бы Вы прислать отчёт?\"}]}",
                                                source: "Can you send the report?", current: "Можешь прислать отчёт?", from: .english, to: .russian).map(\.label) == ["y"],
              "tvariants: a question that became a statement is rejected")
        check(ExtrasParsing.translationVariants("{\"variants\":[{\"label\":\"x\",\"reason\":\"r\",\"text\":\"Кохана, я затримаюсь на роботі до 20:00, вечеряйте без мене. Цілую!\"}]}",
                                                source: "Любимая, я задержусь на работе до 20:00, ужинайте без меня. Целую!", current: "Кохана, я затримаюся на роботі до 20:00, вечеряйте без мене. Цілую!", from: .russian, to: .ukrainian).isEmpty,
              "tvariants: a one-letter difference is not a variant")
        let tvPrompt = ExtrasPrompt.translationVariants(from: .english, to: .russian, userLanguage: .ukrainian, tone: .chat, rules: "GLOSSARY-X")
        check(tvPrompt.contains("Ukrainian") && tvPrompt.contains("GLOSSARY-X") && tvPrompt.contains("WHOLE") && tvPrompt.contains("Never output the current translation"), "tvariants: prompt carries user language, rules and the difference demands")

        let eJSON = """
        Вот ответ: {"meaning":"Собеседник вежливо отказывается, потому что нет бюджета.","tone":"вежливый отказ","terms":[{"term":"circle back","meaning":"вернуться к теме позже"},{"term":"ballpark","meaning":"примерная оценка"},{"term":"synergy","meaning":"выдумка"}]}
        """
        let ex = ExtrasParsing.explanation(eJSON, message: "Let's circle back next quarter, we need a ballpark first.")
        check(ex?.tone == "вежливый отказ" && ex?.terms.count == 2 && ex?.terms.first?.term == "circle back", "explain: parsed, term not in the message dropped", "\(String(describing: ex))")
        let many = "{\"meaning\":\"m\",\"terms\":[" + (1...8).map { "{\"term\":\"w\($0)\",\"meaning\":\"x\"}" }.joined(separator: ",") + "]}"
        let ex2 = ExtrasParsing.explanation(many, message: (1...8).map { "w\($0)" }.joined(separator: " "))
        check(ex2?.terms.count == 5 && ex2?.tone == "нейтрально", "explain: at most 5 terms, default tone")
        check(ExtrasParsing.explanation("{\"tone\":\"x\"}", message: "m") == nil && ExtrasParsing.explanation("oops", message: "m") == nil, "explain: no meaning -> nil")

        // MARK: text cleaning
        check(ExtrasParsing.cleanText("«Привет, мир.»", original: "Привет, мир!") == "Привет, мир.", "clean: wrapping quotes removed")
        check(ExtrasParsing.cleanText("«Он сказал»", original: "«Он сказал»") == "«Он сказал»", "clean: quotes kept if the original had them")
        check(ExtrasParsing.cleanText("```\nHello\n```", original: "x") == "Hello", "clean: code fence removed")
        check(ExtrasParsing.capitalizeFormal("Когда вы сможете? Мы ждём вашего ответа, вам удобно.", lang: .russian) == "Когда Вы сможете? Мы ждём Вашего ответа, Вам удобно.", "capitalizeFormal: ru")
        check(ExtrasParsing.capitalizeFormal("Привіт, ви тут?", lang: .ukrainian) == "Привіт, Ви тут?", "capitalizeFormal: uk")
        check(ExtrasParsing.capitalizeFormal("you are", lang: .english) == "you are", "capitalizeFormal: en untouched")

        // MARK: rewrite guard
        func v(_ o: String, _ e: String, _ m: RewriteMode, _ l: Language = .russian) -> RewriteGuard.Verdict {
            RewriteGuard.verdict(original: o, edited: e, source: "", mode: m, from: .english, to: l)
        }
        check(v("Отчёт готов, 15 марта в 10:30.", "Отчёт будет 15 марта в 10:30.", .shorter) == .ok(pronounsChecked: false), "guard: facts kept -> ok")
        if case .rejected = v("Отчёт за 15 марта, бюджет 5 000 USD.", "Отчёт за 15 марта.", .shorter) {} else { check(false, "guard: lost number rejected") }
        if case .rejected = v("Смотри https://a.com/x тут.", "Смотри тут.", .softer) {} else { check(false, "guard: lost link rejected") }
        if case .rejected = v("Ты можешь прислать файл?", "Пришли файл.", .softer) {} else { check(false, "guard: question -> statement rejected") }
        if case .rejected = v("Привет, пришли файл, пожалуйста.", "Привет, пришли файл, пожалуйста, когда сможешь, очень нужно.", .shorter) {} else { check(false, "guard: «shorter» that is longer rejected") }
        if case .rejected = v("Привет, пришли файл.", "Здравствуйте, пришлите файл.", .softer) {} else { check(false, "guard: greeting swap rejected (not for formal)") }
        check(v("Привет, ты можешь прислать файл?", "Здравствуйте, Вы можете прислать файл?", .formal) == .ok(pronounsChecked: true), "guard: formal ru ok")
        if case .rejected = v("Ты можешь прислать файл?", "Ты можешь прислать файл, пожалуйста?", .formal) {} else { check(false, "guard: formal with «ты» left rejected") }
        if case .rejected = v("Вы можете прислать файл?", "Вы могли бы прислать файл?", .informal) {} else { check(false, "guard: informal with «Вы» left rejected") }
        check(v("Вы можете прислать файл?", "Ты можешь прислать файл?", .informal) == .ok(pronounsChecked: true), "guard: informal ru ok")
        check(v("Ви можете надіслати файл?", "Ти можеш надіслати файл?", .informal, .ukrainian) == .ok(pronounsChecked: true), "guard: informal uk ok")
        if case .rejected = v("Ты можешь прислать файл?", "Можно файл?", .formal) {} else { check(false, "guard: formal with no «Вы» at all rejected when the original had pronouns") }
        check(v("Пришли файл.", "Пришлите файл.", .formal) == .ok(pronounsChecked: true), "guard: imperative without pronouns is not blocked")
        check(v("Can you send it?", "Could you send it over?", .formal, .english) == .ok(pronounsChecked: false), "guard: english formal -> not verifiable")
        check(v("Kannst du das schicken?", "Könnten Sie das schicken?", .formal, .german) == .ok(pronounsChecked: true), "guard: formal de ok")
        if case .rejected = v("", "", .shorter) {} else { check(false, "guard: empty rejected") }
        check(RewriteMode.allCases.count == 8 && RewriteMode(rawValue: "professional") == .professional && RewriteMode.direct.russianTitle == "Прямо", "modes: professional and direct exist with titles")
        check(v("Пожалуйста, пришлите, если возможно, отчёт до 15 марта в 10:30.", "Просим прислать отчёт до 15 марта в 10:30.", .professional) == .ok(pronounsChecked: false), "guard: professional keeps facts")
        if case .rejected = v("Пожалуйста, не делайте так.", "Нам это не подходит. Ответ нужен до 12 мая.", .direct) {} else { check(false, "guard: direct with an invented deadline rejected") }
        if case .rejected = v("Отчёт до 15 марта, пожалуйста.", "Отчёт нужен.", .professional) {} else { check(false, "guard: professional that loses the date rejected") }
        check(v("Пожалуйста, не делайте так.", "Нам это не подходит.", .direct) == .ok(pronounsChecked: false), "guard: direct without new numbers ok")
        if case .rejected = v("Вы можете прислать файл?", "Присылайте файл.", .direct) {} else { check(false, "guard: direct turning a question into a statement rejected") }
        check(v("Привет! Мы отключим трафик 5 мая.", "Привет! Отключаем трафик 5 мая.", .professional) == .ok(pronounsChecked: false), "guard: professional keeps greeting and date")

        // MARK: compose (points -> message): parsing of a saved answer and the checks
        check(ComposeTone.allCases.map(\.rawValue) == ["neutral", "professional", "direct", "friendly"] && ComposeTone.direct.russianTitle == "Прямо", "compose: four tones")
        let pts = "Пусть отключит весь трафик с 3 июня, попробуем ещё раз завтра в 9:30. Если опять будет фуфло — стопнем насовсем."
        var cw = ExtrasParsing.composeWarnings(points: pts, text: "Please switch off all traffic from June 3. We will try again tomorrow at 9:30. If the quality is poor again, we stop for good.", from: .russian, to: .english)
        check(cw.isEmpty, "compose check: every number/time of the points present -> no warnings", "\(cw)")
        cw = ExtrasParsing.composeWarnings(points: pts, text: "Please switch off all traffic from June 3. We will try again tomorrow. If the quality is poor again, we stop for good.", from: .russian, to: .english)
        check(!cw.isEmpty, "compose check: lost time «9:30» -> warning", "\(cw)")
        cw = ExtrasParsing.composeWarnings(points: pts, text: "Please switch off all traffic from June 3. We will try again tomorrow at 9:30 and give you 48 hours. If the quality is poor again, we stop for good.", from: .russian, to: .english)
        check(cw.contains { $0.contains("48") }, "compose check: an invented number «48» -> warning", "\(cw)")
        check(ExtrasParsing.numberTokens("4,8 $ и 4.8 и 12:30").count == 2, "compose check: «4,8» and «4.8» are the same number")
        check(ExtrasParsing.composeWarnings(points: "Скажи, что нам это не нравится.", text: "We don't like this.", from: .russian, to: .english).isEmpty, "compose check: no numbers at all -> no warnings")

        // MARK: reply flow request
        let engine = DefaultTranslationEngine(config: TolkConfig(), rules: RulesStore(path: "/nonexistent/rules.md"),
                                              primary: OllamaProvider(config: TolkConfig(), rules: RulesStore(path: "/nonexistent/rules.md")), fallback: nil)
        let r1 = engine.replyRequest(message: "Hey, could you send me the report by Friday? Thanks!", reply: "Привет, пришлю в четверг.")
        check(r1.target == .english && r1.source == .russian && r1.replyTo != nil, "reply: partner EN -> reply RU→EN")
        let r2 = engine.replyRequest(message: "Привіт! Коли ти будеш вдома? Я вже чекаю на тебе.", reply: "I'll be there at 7")
        check(r2.target == .ukrainian && r2.source == .english, "reply: partner UK, user writes EN -> EN→UK")
        let r3 = engine.replyRequest(message: "Давай созвонимся завтра в 10, удобно?", reply: "Да, удобно")
        check(r3.target == .russian && r3.source != .russian, "reply: both RU -> source is moved off the partner's language")

        // MARK: back-translation diff (meaning only)
        let bsrc = "Hi Max! CTR is up 12%, but fill rate fell to 64%. We did not raise the floor price. Please send ads.txt by Friday."
        var bd = BackDiff.compare(source: bsrc, back: "Hello Max! CTR grew by 12%, but fill rate dropped to 64%. We did not increase the floor price. Please send ads.txt by Friday.")
        check(bd.isClean, "backdiff: synonyms (Hi/Hello, up/grew, fell/dropped, raise/increase) are not reported", "\(bd)")
        let wrong = "Hi Max! CTR is up 12%, but fill rate fell to 46%. We did raise the floor price. Please send ads.txt by Monday."
        bd = BackDiff.compare(source: bsrc, back: wrong)
        let marked = bd.marks.map { (wrong as NSString).substring(with: $0) }
        check(marked.contains("46") && marked.contains("Monday"), "backdiff: changed number and a new name are marked", "\(marked)")
        check(bd.missing.contains("64") && bd.missing.contains("Friday") && bd.missing.contains("отрицание"), "backdiff: lost number, name and negation are listed", "\(bd.missing)")
        bd = BackDiff.compare(source: "We will ship it.", back: "We will not ship it.")
        check(bd.marks.map { ("We will not ship it." as NSString).substring(with: $0) } == ["not"], "backdiff: added negation is marked")
        bd = BackDiff.compare(source: "Я никогда не видел этот отчёт.", back: "I never saw this report.")
        check(bd.isClean, "backdiff: double negation ru vs single en is not a discrepancy", "\(bd)")
        bd = BackDiff.compare(source: "Спасибо, Максим! Бюджет 1 500 евро.", back: "Thanks, Maksim! The budget is 1,500 euros.")
        check(!bd.marks.contains { _ in false } && bd.missing.contains("Максим") == true, "backdiff: a name in another script is reported as missing (honest, not silent)", "\(bd)")
        bd = BackDiff.compare(source: "Budget is 1 500 euro.", back: "The budget is 1,500 euro.")
        check(bd.isClean, "backdiff: thousand separators do not matter", "\(bd)")
        bd = BackDiff.compare(source: "Lower the floor price on mobile.", back: "Lower the minimum on mobile.",
                              glossary: [GlossaryHit(source: "floor price", targets: ["минимальная цена"])])
        check(bd.missing == ["floor price"], "backdiff: glossary term that did not survive is listed", "\(bd.missing)")

        // MARK: glossary hits for the page
        let rules = RulesStore(path: "/nonexistent/rules.md", builtIn: "# Style\nBe brief.\n\n## Глоссарий\n- floor price → флор / минимальная цена\n- fill rate → fill rate\n- cap → капа\n")
        let hits = rules.glossaryHits(in: "Lower the floor price. The fill rate is low, the capital is fine.", target: .russian)
        check(hits.map(\.source) == ["floor price", "fill rate"] && hits[0].targets == ["флор", "минимальная цена"], "glossary hits: only fired lines (cap ≠ capital), oriented to the target", "\(hits)")
        let ru = "Снизим флор. Fill rate низкий."
        let gm = RulesStore.marks(of: hits, in: ru).map { (ru as NSString).substring(with: $0.range) }
        check(gm == ["флор", "Fill rate"], "glossary marks: renderings found in the translation", "\(gm)")
        check(rules.glossaryHits(in: "Hello there", target: .english).isEmpty && rules.glossaryHits(in: "Снизим флор", target: .english).first?.targets == ["floor price"], "glossary hits: no hit without the source side; reverse direction is oriented too")
    }
}
