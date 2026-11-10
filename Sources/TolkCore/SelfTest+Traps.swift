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
        // Prompt rules measured on the trap corpus stay in the prompt.
        let r = ResolvedRequest(text: "x", source: .russian, target: .english, tone: .auto, mode: .translate)
        let en = Prompt.system(for: r, rules: "")
        check(en.contains("stop sending us X") && en.contains("don't do this again"), "prompt: «убрать от нас» / «в дальнейшем» rules")
        check(en.contains("until this is clarified") && en.contains("clean (not «clear»)") && en.contains("send / drive traffic"), "prompt: trap rules RU→EN")
        let ru = Prompt.system(for: ResolvedRequest(text: "x", source: .english, target: .russian, tone: .auto, mode: .translate), rules: "")
        check(ru.contains("«we» stays «мы»") && ru.contains("please advise") && ru.contains("после выставления счёта") && en.contains("never transliterate") && en.contains("keep «SubID» exactly"), "prompt: trap rules EN→RU")
    }
}
