// Self-test of the trap-corpus checker and the calque entries added for it. No model.
import Foundation

extension SelfTest {
    static func trapCorpus(_ check: Check) {
        let item = TrapItem(id: "T", trap: "polite", from: .russian, to: .english, tone: .auto, text: "Попрошу вас прислать отчёт до 15:00.",
                            must: ["(?i)please|could you", "15:00|3 ?pm"], forbid: ["(?i)I('ll| will)? ask you"])
        check(TrapCorpus.failures(item, translation: "Please send the report by 3 PM.").isEmpty, "trap: good translation passes")
        check(!TrapCorpus.failures(item, translation: "I'll ask you to send the report by 3 PM.").isEmpty, "trap: forbidden phrase fails")
        check(TrapCorpus.failures(item, translation: "Please send the report.").contains { $0.hasPrefix("нет:") }, "trap: missing required fails")
        check(TrapCorpus.failures(item, translation: "Please send the report by 3 PM, as per our call.").contains { CalqueDetector.isCalque($0) },
              "trap: calque warning counted")
        let rs = [(item: item, passed: true), (item: item, passed: false)]
        check(TrapCorpus.summary(rs).first.map { $0.passed == 1 && $0.total == 2 } == true, "trap: summary tally")
        check(TrapCorpus.load(path: "/nonexistent/corpus.json") == nil, "trap: missing file -> nil")

        // Back-translation signal: key elements of the original vs the back-translation
        check(BackCheck.compare(source: "We will not pay 120 USD if you do not send the report.", back: "We will not pay 120 USD if you do not send the report.", lang: .english).isEmpty, "back: identical text is consistent")
        check(BackCheck.compare(source: "We will not pay 120 USD.", back: "We will pay 120 USD.", lang: .english).contains { $0.contains("отрицание") }, "back: lost negation is flagged")
        check(BackCheck.compare(source: "Ставка 0,35 $, бюджет 12 500 $.", back: "Ставка 0.35 $, бюджет 12,500 $", lang: .russian).isEmpty, "back: localized numbers are equal")
        check(BackCheck.compare(source: "Ставка 0,35 $.", back: "Ставка 0,53 $.", lang: .russian).contains { $0.contains("чисел") }, "back: a changed number is flagged")
        check(BackCheck.compare(source: "Мы вернём деньги, если вы пришлёте чек.", back: "Я верну деньги, если пришлёшь чек.", lang: .russian).contains { $0.contains("мы") }, "back: we → I is flagged")
        check(BackCheck.compare(source: "Если вы не ответите, мы отключим трафик.", back: "Вы ответите, мы отключим трафик.", lang: .russian).contains { $0.contains("условие") }, "back: lost condition is flagged")

        // Telegram header stays verbatim (masked as one entity)
        let tg = "Javier Corchuelo, [9 лист. 2026 р., 15:03:57]:\nДобрий день, надішліть рахунок"
        let tgm = EntityMasker.mask(tg)
        check(tgm.entities.first?.original == "Javier Corchuelo, [9 лист. 2026 р., 15:03:57]:", "masker: Telegram header is one entity", tgm.summary)
        check(tgm.text.hasPrefix("<x1/>\n"), "masker: Telegram header is replaced by a placeholder", tgm.text)
        check(EntityMasker.mask("Anna, [Nov 9, 2026, 3:03 PM]:\nHi").entities.count == 1, "masker: English date header")
        check(EntityMasker.mask("Спасибо, [ссылка] тут").entities.isEmpty || !EntityMasker.mask("Спасибо, [ссылка] тут").entities.contains { $0.kind == .id }, "masker: ordinary text is not a header")
        let tg2 = EntityMasker.mask("Первый абзац.\n\nИван Петров, [10 ноя 2026, 09:12]:\nОтвет")
        check(tg2.entities.count == 1 && tg2.entities[0].original.hasPrefix("Иван Петров"), "masker: header of a later paragraph")

        func hit(_ t: String, _ l: Language) -> Bool { !CalqueDetector.detect(in: t, language: l).isEmpty }
        func ids(_ t: String, _ l: Language) -> [String] { CalqueDetector.detect(in: t, language: l).map(\.id) }
        // Trap-corpus calque entries.
        check(ids("Пожалуйста, примите к сведению, что выплата будет в пятницу.", .russian) == ["ru-primite-k-svedeniyu"], "calque: «примите к сведению»")
        check(hit("Пожалуйста, посоветуйте, какие у нас дальнейшие шаги.", .russian), "calque: «посоветуйте» (please advise)")
        check(hit("Двигаясь вперёд, присылайте отчёты до 10:00.", .russian), "calque: «двигаясь вперёд»")
        check(hit("Проверьте расхождение на вашем конце.", .russian), "calque: «на вашем конце»")
        check(hit("Сделаю в первую вещь завтра.", .russian), "calque: «в первую вещь»")
        check(!hit("Обратите внимание, что выплата будет в пятницу.", .russian), "calque: «обратите внимание» is fine")
        check(hit("You must see the quality of the traffic.", .english), "calque: «you must see»")
        check(hit("Be so kind and check the postbacks.", .english), "calque: «be so kind»")
        check(!hit("Be kind to the new publishers.", .english), "calque: «be kind to» is fine")
        check(hit("I'm in touch all day, write me.", .english), "calque: «in touch all day»")
        check(hit("I request you to remove it.", .english), "calque: «I request you to»")
        check(!hit("Please send the report by Friday.", .english), "calque: normal request is clean")
        check(ids("Please advise.", .russian).isEmpty, "calque: EN text not checked as RU")
        // One-way glossary hints: «русское → English» is not applied when translating into Russian.
        check(RulesStore.oriented("- разжать (лимит) → raise / increase", toCyrillic: true) == nil, "glossary: RU→EN hint is one-way")
        check(RulesStore.oriented("- разжать (лимит) → raise / increase", toCyrillic: false) == "- разжать (лимит) → raise / increase", "glossary: RU→EN hint applies to English")
        check(RulesStore.oriented("- cap → капа; разжать → raise", toCyrillic: true) == "- cap → капа", "glossary: only the one-way pair of a line is dropped")
        check(RulesStore.oriented("- cap → капа", toCyrillic: false) == "- капа → cap", "glossary: EN→RU pair works both ways")
        // Prompt rules measured on the trap corpus stay in the prompt.
        func sys(_ text: String, _ from: Language, _ to: Language) -> String {
            Prompt.system(for: ResolvedRequest(text: text, source: from, target: to, tone: .auto, mode: .translate), rules: "")
        }
        let en = sys("Попрошу вас убрать от нас фрод и не делать так в дальнейшем. Сабайди чистые, льём дальше, до выяснения.", .russian, .english)
        check(en.contains("stop sending us X") && en.contains("don't do this again"), "prompt: «убрать от нас» / «в дальнейшем» rules")
        check(en.contains("until this is clarified") && en.contains("clean (not «clear»)") && en.contains("send / drive traffic"), "prompt: trap rules RU→EN")
        let ru = sys("Please advise. Net-30 terms apply.", .english, .russian)
        check(ru.contains("«we» stays «мы»") && ru.contains("Please advise") && ru.contains("INVOICE date") && en.contains("never transliterate") && en.contains("keep «SubID» exactly"), "prompt: trap rules EN→RU")
        // A phrase rule is sent only with its phrase: no bleeding into unrelated texts.
        let plain = sys("Оставляем за собой право приостановить выплаты до завершения проверки.", .russian, .english)
        check(!plain.contains("until this is clarified") && !plain.contains("Notes for phrases"), "prompt: no phrase rules without their phrases")
        check(sys("Уточнить у бухгалтерии реквизиты.", .russian, .english).contains("never invent a subject"), "prompt: impersonal infinitive rule fires")
        check(!sys("Мы хотим уточнить реквизиты.", .russian, .english).contains("never invent a subject"), "prompt: infinitive inside a sentence does not fire")
        check(sys("Vlad K, [9 лист. 2026 р., 15:03:57]:\nпривет", .russian, .english).contains("chat header copied from Telegram"), "prompt: Telegram header rule fires")
        check(PhraseRules.matching("The capital is fine", target: .russian).isEmpty && !PhraseRules.matching("FYI, finance flagged it", target: .russian).isEmpty, "prompt: EN→RU triggers")
    }
}
