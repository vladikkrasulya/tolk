// Debug-only fake engine and sample text for previews (see MainWindowDemo).
#if DEBUG
import AppKit
import TolkCore

/// Fake engine that streams word by word, like Qwen does.
final class DemoTranslationEngine: TranslationEngine, @unchecked Sendable {
    enum Mode: String { case normal = "1", fallback, error }
    let mode: Mode
    /// Demo: no check warnings (shows the plain, long status line).
    nonisolated(unsafe) static var noWarnings = false
    /// Demo: a fixed translation text (popup render) and the «из кеша» mark.
    nonisolated(unsafe) static var fixedTranslation: String?
    nonisolated(unsafe) static var fromCache = false
    init(mode: Mode) { self.mode = mode }

    static let longRussian = """
    Привет! Мы посмотрели статистику по кампании за прошлую неделю: CTR вырос на 12 %, но eCPM \
    в тирах 2–3 просел, и fill rate на SSP упал примерно до 64 %. Похоже, проблема в floor price, \
    который мы подняли в пятницу. Предлагаю откатить флор до прежнего значения на сегменте мобильного \
    веба и параллельно запустить A/B-тест с динамическими флорами на десктопе.

    Ещё вопрос: можете прислать свежий ads.txt и подтвердить, что новые seller ID уже добавлены? \
    Без этого часть DSP режет трафик как unauthorized. Если всё ок, к среде сможем раскатить \
    изменения на 100 % трафика и вернуть объём.

    Спасибо, ждём обратной связи!
    """

    /// What the back-translation of `longRussian` looks like (a bit off on purpose: shows the highlighting).
    static let backEnglish = """
    Hi! We reviewed the campaign statistics for last week: CTR grew by 12%, but eCPM \
    in tiers 2–3 sank, and the SSP fill rate fell to roughly 46%. It seems the problem is the floor price \
    we raised on Friday. I suggest rolling the floor back to its previous value on the mobile \
    web segment and at the same time launching an A/B test with dynamic floors on desktop.

    One more question: could you send a fresh ads.txt and confirm that the new seller IDs have been added? \
    Without it, some DSPs cut the traffic as unauthorized. If everything is fine, by Wednesday we can roll out \
    the changes to 100% of traffic and bring back the volume.

    Thanks, waiting for your feedback!
    """

    // Reply-mode demo texts (a partner writes in English, the user answers in Russian).
    static let partnerMessage = """
    Hey! Quick one: the SSP is still cutting traffic from your seller ID, so we can't circle back on the floor \
    until you send a clean ads.txt. Can you ballpark a rollout by Wednesday? Not a blocker for us, but the buyers \
    are getting restless.
    """
    static let partnerRussian = """
    Привет! Коротко: SSP всё ещё режет трафик с вашего seller ID, поэтому мы не можем вернуться к вопросу флора, \
    пока вы не пришлёте чистый ads.txt. Можете прикинуть срок раскатки к среде? Для нас это не блокер, но покупатели \
    уже нервничают.
    """
    static let myReply = "Привет! Свежий ads.txt пришлю сегодня до вечера, новые seller ID уже добавлены. Флор на мобильном вебе откатим сегодня, а к среде раскатим изменения на 100 % трафика."
    static let myReplyEnglish = "Hi! I'll send a fresh ads.txt by tonight; the new seller IDs are already added. We'll roll the floor back on mobile web today and roll the changes out to 100% of traffic by Wednesday."
    static let myReplyBack = "Привет! Свежий ads.txt пришлю сегодня к вечеру, новые seller ID уже добавлены. Флор на мобильном вебе откатим сегодня, а к среде выкатим изменения на 100 % трафика."

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        let mode = self.mode
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    let src = request.source ?? .english
                    let dst = request.target ?? .russian
                    if mode == .error {
                        try await Task.sleep(for: .milliseconds(600))
                        throw URLError(.cannotConnectToHost)
                    }
                    if mode == .fallback {
                        c.yield(.started(provider: "qwen", source: src, target: dst))
                        try await Task.sleep(for: .milliseconds(400))
                        c.yield(.delta("Прив"))
                        try await Task.sleep(for: .milliseconds(500))
                        c.yield(.fellBack(from: "qwen", reason: "vkbox: connection refused"))
                        c.yield(.started(provider: "google", source: src, target: dst))
                    } else {
                        c.yield(.started(provider: "qwen", source: src, target: dst))
                    }
                    let text = Self.fixedTranslation ?? (request.replyTo != nil ? Self.myReplyEnglish
                        : request.text == Self.partnerMessage ? Self.partnerRussian
                        : request.text == Self.myReplyEnglish ? Self.myReplyBack
                        : request.target == .english && request.source == .russian ? Self.backEnglish
                        : request.text.count > 80 ? Self.longRussian
                        : "[\(request.tone.rawValue)] " + Self.longRussian.prefix(140) + "…")
                    var chunk = ""
                    for ch in text {
                        chunk.append(ch)
                        if ch == " " || ch == "\n" {
                            c.yield(.delta(chunk)); chunk = ""
                            try await Task.sleep(for: .milliseconds(25))
                        }
                    }
                    if !chunk.isEmpty { c.yield(.delta(chunk)) }
                    var stats = TranslationStats(provider: "gemma-translate", route: .home, firstChunk: 1.7, total: 6.8,
                                                 outputTokens: 110, tokensExact: true, fallbackReason: nil)
                    stats.fromCache = Self.fromCache
                    stats.warnings = Self.noWarnings || Self.fixedTranslation != nil ? [] : ["в переводе нет времени 15:30", "потеряна ссылка example.com/ads.txt"]
                    stats.firstChunk = 2.0; stats.outputTokens = 100
                    c.yield(.stats(stats))
                    c.yield(.finished)
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    func addGlossaryTerm(source: String, translation: String) throws {
        print("[demo] glossary: \(source) -> \(translation)")
    }

    func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote] {
        try? await Task.sleep(for: .milliseconds(500))
        return [
            TranslationNote(term: "floor price", used: "floor price", suggestion: "минимальная цена",
                            note: "В RTB/AdTech «floor» — минимальная ставка аукциона; в русской практике чаще «флор» или «минимальная цена»."),
            TranslationNote(term: "fill rate", used: "fill rate", suggestion: nil,
                            note: "Доля запросов, на которые пришла хотя бы одна ставка. Обычно не переводят."),
        ]
    }

    func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String] {
        try? await Task.sleep(for: .milliseconds(300))
        return ["минимальная цена", "порог цены", "флор", "нижняя граница ставки"]
    }

    func glossaryHits(in text: String, target: Language) -> [GlossaryHit] {
        var out: [GlossaryHit] = []
        if text.lowercased().contains("floor price") { out.append(GlossaryHit(source: "floor price", targets: ["floor price"])) }
        if text.lowercased().contains("fill rate") { out.append(GlossaryHit(source: "fill rate", targets: ["fill rate"])) }
        if text.lowercased().contains("seller id") { out.append(GlossaryHit(source: "seller ID", targets: ["seller ID"])) }
        return out
    }

    func sentenceVariants(sentence: String, current: String, fullSource: String, fullTranslation: String,
                          from: Language, to: Language, tone: Tone) async throws -> [SentenceVariant] {
        try await Task.sleep(for: .milliseconds(700))
        return [
            SentenceVariant(text: "Похоже, виноват floor price, который мы подняли в пятницу.", label: "ближе к тексту"),
            SentenceVariant(text: "Скорее всего, дело во флоре, который мы подняли в пятницу.", label: "разговорнее"),
            SentenceVariant(text: "Причина, видимо, в пятничном повышении floor price.", label: "короче"),
        ]
    }

    func rewrite(translation: String, source: String, from: Language, to: Language, mode: RewriteMode) async throws -> RewriteResult {
        try await Task.sleep(for: .milliseconds(800))
        var t = translation
        switch mode {
        case .shorter:
            t = t.replacingOccurrences(of: "\n\nСпасибо, ждём обратной связи!", with: "")
                .replacingOccurrences(of: "Мы посмотрели статистику по кампании за прошлую неделю", with: "По кампании за прошлую неделю")
                .replacingOccurrences(of: "Предлагаю откатить флор до прежнего значения", with: "Предлагаю откатить флор")
        case .softer:
            t = t.replacingOccurrences(of: "Предлагаю откатить", with: "Возможно, стоит откатить")
                .replacingOccurrences(of: "Без этого часть DSP режет", with: "Похоже, без этого часть DSP режет")
        case .simpler:
            t = t.replacingOccurrences(of: "раскатить изменения на 100 % трафика", with: "включить изменения для всего трафика")
        case .formal:
            t = t.replacingOccurrences(of: "можете прислать", with: "не могли бы Вы прислать")
        case .informal:
            t = t.replacingOccurrences(of: "можете прислать", with: "можешь прислать")
        case .professional:
            t = t.replacingOccurrences(of: "Предлагаю откатить", with: "Прошу откатить")
                .replacingOccurrences(of: "Спасибо, ждём обратной связи!", with: "Ждём обратной связи.")
                .replacingOccurrences(of: "можете прислать", with: "просим прислать")
        case .direct:
            t = t.replacingOccurrences(of: "Предлагаю откатить флор до прежнего значения", with: "Нужно откатить флор до прежнего значения")
                .replacingOccurrences(of: "Без этого часть DSP режет", with: "Без этого часть DSP режет")
        case .firmer:
            return RewriteResult(mode: mode, text: translation, accepted: false,
                                 rejection: "в тексте пропало число «64 %»", changed: false, pronounsChecked: false)
        }
        return RewriteResult(mode: mode, text: t, accepted: true, rejection: nil, changed: t != translation, pronounsChecked: false)
    }

    func translationVariants(source: String, translation: String, from: Language, to: Language, tone: Tone, replyTo: String?) async throws -> [TranslationVariant] {
        try await Task.sleep(for: .milliseconds(900))
        return [
            TranslationVariant(text: translation.replacingOccurrences(of: "можете прислать", with: "не могли бы Вы прислать")
                                .replacingOccurrences(of: "Предлагаю откатить", with: "Прошу откатить"),
                               label: "Строже", reason: "на «Вы», просьба звучит как формальное требование"),
            TranslationVariant(text: translation.replacingOccurrences(of: "Предлагаю откатить", with: "Давайте, пожалуй, откатим")
                                .replacingOccurrences(of: "Спасибо, ждём обратной связи!", with: "Буду рада любой обратной связи :)"),
                               label: "Дружелюбнее", reason: "смягчено, разговорный порядок слов"),
            TranslationVariant(text: translation.replacingOccurrences(of: "Мы посмотрели статистику по кампании", with: "Посмотрели статистику кампании")
                                .replacingOccurrences(of: "раскатить изменения на", with: "раскатить на"),
                               label: "Короче", reason: "убраны вводные слова, фразы сжаты"),
        ]
    }

    static let composeSample = "Hello! We would like you to switch off all fraud traffic, all resale and all iframe traffic, and we will try once more tomorrow morning. If the traffic turns out to be low quality again, we will stop for good. If low-quality traffic keeps coming in, we will ask for a refund. We don't need to be overly careful with them, but without aggression: it is important to say plainly that we don't like this situation."
    static let composeBack = "Здравствуйте! Мы хотели бы, чтобы вы отключили весь фродовый трафик, весь ресейл и весь iframe-трафик, и завтра с утра мы попробуем ещё раз. Если трафик снова окажется низкого качества, мы остановимся насовсем. Если некачественный трафик продолжит поступать, мы потребуем возврат средств. Но без агрессии: важно прямо сказать, что нас такая ситуация не устраивает."

    func compose(points: String, tone: ComposeTone, to: Language, partnerMessage: String?) async throws -> ComposeResult {
        try await Task.sleep(for: .milliseconds(900))
        let hasMsg = partnerMessage?.isEmpty == false
        return ComposeResult(text: Self.composeSample, language: hasMsg ? LanguageDetector.detect(partnerMessage ?? "") : to,
                             backTranslation: Self.composeBack,
                             warnings: points.contains("999") ? ["в сообщении пропало число «999»"] : [])
    }

    func explain(message: String) async throws -> MessageExplanation {
        try await Task.sleep(for: .milliseconds(900))
        return MessageExplanation(
            meaning: "Партнёр сообщает, что SSP режет ваш трафик из-за проблем с ads.txt, и пока это не исправлено, обсуждать флор он не будет. Просит назвать примерный срок раскатки к среде; формально это не блокер, но покупатели недовольны, так что время поджимает.",
            tone: "деловой, с лёгким нажимом",
            terms: [
                .init(term: "circle back", meaning: "вернуться к вопросу позже"),
                .init(term: "ballpark", meaning: "назвать приблизительную оценку, без точных цифр"),
                .init(term: "blocker", meaning: "то, что мешает двигаться дальше"),
            ])
    }

    func refine(source: String, translation: String, from: Language, to: Language, tone: Tone) -> AsyncThrowingStream<String, Error> {
        let edited = translation
            .replacingOccurrences(of: "Мы посмотрели статистику", with: "Мы просмотрели статистику")
            .replacingOccurrences(of: "Предлагаю откатить", with: "Предлагаю вернуть")
            .replacingOccurrences(of: "раскатить изменения", with: "выкатить изменения")
        return AsyncThrowingStream { c in c.yield(edited); c.finish() }
    }
}

@MainActor
enum TolkUIDemo {
    static let sampleEnglish = """
    Hi team! We looked at last week's campaign stats: CTR is up 12%, but eCPM in tiers 2–3 dropped \
    and SSP fill rate fell to about 64%. It looks like the floor price we raised on Friday is the \
    culprit. I suggest rolling the floor back on mobile web and running an A/B test with dynamic \
    floors on desktop in parallel. Also, could you send the latest ads.txt and confirm the new \
    seller IDs are in? Thanks!
    """
}
#endif
