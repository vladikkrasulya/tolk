// Deterministic list of frequent calques in RU / UK / EN (no model). Runs on the finished translation (target language).
//
// UI contract: a calque hit is added to `TranslationStats.warnings` as
//     "калька: «<found>» → «<suggestion>»"
// i.e. it starts with `CalqueDetector.warningPrefix`; `CalqueDetector.isCalque(warning)` tells it apart from the
// "потерян …" / "в переводе нет …" warnings of TranslationCheck. The editor pass gets `promptHint(for:)`.
import Foundation

public enum CalqueDetector {
    public static let warningPrefix = "калька: "

    public struct Hit: Sendable, Equatable {
        public let id: String
        public let found: String
        public let suggestion: String
        public let language: Language
    }

    struct Entry {
        let id: String
        let language: Language
        let pattern: String
        let suggestion: String
        let regex: NSRegularExpression
    }

    private static func w(_ s: String) -> String { "(?<![\\p{L}])(?:\(s))(?![\\p{L}])" }

    // (language, id, regex body, suggested replacement)
    private static let raw: [(Language, String, String, String)] = [
        // — Ukrainian —
        (.ukrainian, "uk-napered-dyakuyu", "наперед\\s+дякую", "заздалегідь дякую"),
        (.ukrainian, "uk-pryymaty-uchast", "прийма(?:ти|ю|єш|є|ємо|єте|ють|в|ла|ли|ло)\\s+участь", "брати участь"),
        (.ukrainian, "uk-po-krainiy-miri", "по\\s+крайній\\s+мірі", "принаймні"),
        (.ukrainian, "uk-na-danyy-moment", "на\\s+даний\\s+момент", "наразі / зараз"),
        (.ukrainian, "uk-vybachayus", "вибачаюсь|вибачаємось", "перепрошую / вибачте"),
        (.ukrainian, "uk-v-zalezhnosti", "в\\s+залежності\\s+від", "залежно від"),
        (.ukrainian, "uk-slidyuchyy", "слідуюч(?:ий|а|е|і|ого|ому|их|им)", "наступний"),
        (.ukrainian, "uk-yavlyayetsya", "являється|являються|являтися", "є"),
        (.ukrainian, "uk-na-protyazi", "на\\s+протязі", "протягом"),
        (.ukrainian, "uk-spivpadaty", "співпада(?:ти|є|ють|ло|ла|ли)", "збігатися"),
        (.ukrainian, "uk-pryymaty-miry", "прийма(?:ти|ю|є|ємо|ють)\\s+мір(?:и|у|ами)|прийня(?:ти|в|ла|ли)\\s+мір(?:и|у)", "вживати заходів"),
        (.ukrainian, "uk-pryymaty-do-uvahy", "прийма(?:ти|ю|є|ємо)\\s+до\\s+уваги|прийня(?:ти|в|ла|ли)\\s+до\\s+уваги", "брати / взяти до уваги"),
        (.ukrainian, "uk-proshu-vas", "прошу\\s+вас\\s+(?:вирішити|зробити|надіслати|відповісти|перевірити)", "будь ласка, вирішіть / зробіть …"),
        (.ukrainian, "uk-zhdaty", "ждати|ждемо|жду(?:\\s|$)", "чекати"),
        (.ukrainian, "uk-dyakuyu-zaranee", "дякую\\s+заране|заране\\s+дякую", "заздалегідь дякую"),
        // — Russian —
        (.russian, "ru-imeet-smysl", "им(?:еет|ело|ели)\\s+смысл", "есть смысл / логично"),
        (.russian, "ru-daite-znat", "дайте\\s+мне\\s+знать|дай\\s+мне\\s+знать", "сообщите / напиши"),
        (.russian, "ru-v-kontse-dnya", "в\\s+конце\\s+дня", "в итоге / в конечном счёте"),
        (.russian, "ru-vzyat-dush", "взя(?:ть|л|ла|ли)\\s+душ", "принять душ"),
        (.russian, "ru-proshu-vas", "прошу\\s+вас\\s+(?:решить|сделать|отправить|ответить|проверить)", "пожалуйста, решите / сделайте …"),
        (.russian, "ru-na-dannyy-moment", "на\\s+данный\\s+момент", "сейчас"),
        (.russian, "ru-soglasno-razgovoru", "согласно\\s+нашему\\s+разговору|в\\s+соответствии\\s+с\\s+нашим\\s+разговором|как\\s+по\\s+нашему\\s+разговору", "как мы договорились"),
        (.russian, "ru-na-osnove", "на\\s+(?:ежедневной|еженедельной|регулярной|ежемесячной)\\s+основе", "ежедневно / еженедельно / регулярно"),
        (.russian, "ru-byt-v-sostoyanii", "в\\s+состоянии\\s+(?:сделать|помочь|ответить|отправить)", "смогу / можете"),
        (.russian, "ru-delaet-smysl", "делает\\s+смысл|делать\\s+смысл", "имеет смысл / логично"),
        (.russian, "ru-delat-dengi", "делать\\s+деньги|делает\\s+деньги", "зарабатывать"),
        (.russian, "ru-obnovit-vas", "обновлю\\s+вас|обновить\\s+вас|обновит\\s+вас", "сообщу / держать в курсе"),
        (.russian, "ru-bud-proinf", "будьте\\s+проинформированы|пожалуйста,\\s+будьте\\s+проинформированы", "обратите внимание"),
        (.russian, "ru-prinyat-resheniye", "сдела(?:ть|л|ла|ли)\\s+решение", "принять решение"),
        // — English —
        (.english, "en-kindly-ask", "I\\s+kindly\\s+ask\\s+you", "Could you please"),
        (.english, "en-be-advised", "please\\s+be\\s+advised(?:\\s+that)?", "Please note / (drop it)"),
        (.english, "en-as-per-conv", "as\\s+per\\s+our\\s+(?:conversation|call|discussion|talk|agreement)", "as we discussed / agreed"),
        (.english, "en-as-per", "as\\s+per(?!\\s+our)", "according to"),
        (.english, "en-revert-back", "revert\\s+back|kindly\\s+revert", "get back to you / reply"),
        (.english, "en-do-needful", "do\\s+the\\s+needful", "take care of it"),
        (.english, "en-nearest-time", "in\\s+the\\s+nearest\\s+(?:time|future)|in\\s+the\\s+closest\\s+time", "soon"),
        (.english, "en-question-to-you", "(?:a\\s+)?question\\s+to\\s+you", "a question for you"),
        (.english, "en-since-long", "since\\s+a\\s+long\\s+time", "for a long time"),
        (.english, "en-i-am-agree", "I(?:\\s+am|'m)\\s+agree", "I agree"),
        (.english, "en-depends-from", "depend(?:s|ed)?\\s+from", "depends on"),
        (.english, "en-discuss-about", "discuss(?:es|ed|ing)?\\s+about", "discuss (no «about»)"),
        (.english, "en-according-to-me", "according\\s+to\\s+me", "in my opinion"),
        (.english, "en-waiting-answer", "I(?:\\s+am|'m)\\s+waiting\\s+for\\s+your\\s+(?:answer|reply|response)", "I look forward to your reply"),
        (.english, "en-explain-me", "explain\\s+me\\b", "explain to me"),
        (.english, "en-i-ask-you", "I\\s+ask\\s+you\\s+(?:to|for)", "I'd ask you to / please"),
        (.english, "en-hearing-you", "looking\\s+forward\\s+to\\s+hearing\\s+you", "hearing from you"),
        (.english, "en-in-attachment", "(?:please\\s+)?find\\s+in\\s+(?:the\\s+)?attachment", "please find attached"),
        (.english, "en-please-comma", "(?<![\\p{L}])please,\\s", "please (no comma)"),
        (.english, "en-ill-ask-you", "I(?:'ll|\\s+will|\\s+would\\s+like\\s+to)\\s+ask\\s+you\\s+to", "Please …"),
        (.english, "en-from-our-side", "from\\s+(?:our|your)\\s+side", "on our end / to our feeds / in your traffic (who does what?)"),
    ]

    private static let entries: [Entry] = raw.compactMap { lang, id, body, sug in
        guard let re = try? NSRegularExpression(pattern: w(body), options: [.caseInsensitive]) else { return nil }
        return Entry(id: id, language: lang, pattern: body, suggestion: sug, regex: re)
    }

    /// Number of entries (for the self-test).
    public static var count: Int { entries.count }
    public static func entries(for language: Language) -> Int { entries.filter { $0.language == language }.count }

    /// Calques in `text` (which is written in `language`). One hit per entry; the more specific «as per our …» wins over «as per».
    public static func detect(in text: String, language: Language) -> [Hit] {
        let ns = text as NSString
        var hits: [Hit] = []
        for e in entries where e.language == language {
            guard let m = e.regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            hits.append(Hit(id: e.id, found: ns.substring(with: m.range), suggestion: e.suggestion, language: language))
        }
        return hits
    }

    /// Warnings in the `TranslationStats.warnings` format; at most 2.
    public static func warnings(in text: String, language: Language) -> [String] {
        detect(in: text, language: language).prefix(2).map { warningPrefix + "«\($0.found)» → «\($0.suggestion)»" }
    }

    public static func isCalque(_ warning: String) -> Bool { warning.hasPrefix(warningPrefix) }

    /// Extra lines for the editor prompt; empty when there are no hits.
    public static func promptHint(for hits: [Hit]) -> String {
        guard !hits.isEmpty else { return "" }
        let lines = hits.map { "- «\($0.found)» is a calque; write \($0.suggestion) (in the right grammatical form)" }
        return "Known calques found in the draft — fix them:\n" + lines.joined(separator: "\n")
    }
}
