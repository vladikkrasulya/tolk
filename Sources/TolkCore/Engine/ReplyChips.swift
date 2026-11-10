// Ready answers in the «Ответить» window: one press = a short reply written by `compose` from a fixed instruction,
// in the user's own language, so it can be edited and then goes through the normal reply translation.
import Foundation

public struct ReplyChip: Sendable, Equatable {
    public let id: String
    public let title: String
    public let symbol: String       // SF Symbol
    public let tooltip: String
    /// The instruction for `compose` (Russian, like the user's own points). It never names facts: the partner's message gives them.
    public let points: String
}

public enum ReplyChips {
    public static let all: [ReplyChip] = [
        ReplyChip(id: "confirm", title: "Подтвердить", symbol: "checkmark.circle",
                  tooltip: "Подтвердить: понял, согласен",
                  points: "Подтверди: если собеседник о чём-то спрашивает или что-то предлагает — ответь согласием, если просто сообщает информацию — скажи, что получили и поняли. Больше ничего не добавляй: ни обещаний, ни «посмотрим»."),
        ReplyChip(id: "looking", title: "Смотрим", symbol: "eye",
                  tooltip: "Сказать, что посмотрим и вернёмся с ответом",
                  points: "Скажи, что мы посмотрим и вернёмся с ответом. Сроков не называй, ничего не обещай."),
        ReplyChip(id: "details", title: "Детали?", symbol: "questionmark.bubble",
                  tooltip: "Попросить уточнить детали",
                  points: "Попроси прислать больше деталей по этому вопросу: один короткий вопрос. Не придумывай, что именно неясно."),
        ReplyChip(id: "call", title: "Созвон?", symbol: "phone",
                  tooltip: "Предложить созвониться",
                  points: "Предложи созвониться, чтобы обсудить это голосом. Время не называй: спроси, когда удобно собеседнику."),
        ReplyChip(id: "decline", title: "Отказать", symbol: "xmark.circle",
                  tooltip: "Вежливо отказать",
                  points: "Вежливо откажи: мы не можем этого сделать. Причину не придумывай, без извинений, без «к сожалению»."),
    ]

    /// ⌘1…⌘N: index of the chip for a typed digit (nil: not a chip key).
    public static func index(forKey ch: Character) -> Int? {
        guard let n = ch.wholeNumberValue, n >= 1, n <= all.count else { return nil }
        return n - 1
    }

    /// The chips are offered while there is a message to answer and the user has not started writing their own text
    /// (an empty field, or the untouched text of the previous chip, which a new chip may replace).
    public static func visible(partnerText: String, input: String, lastChipText: String?) -> Bool {
        guard !partnerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == lastChipText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The app's tone of the chat -> the tone of the composed text.
    public static func composeTone(for tone: Tone) -> ComposeTone {
        switch tone { case .auto: .neutral; case .chat: .friendly; case .formal: .professional }
    }
}
