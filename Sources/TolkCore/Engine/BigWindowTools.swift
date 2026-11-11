// Engine for the extra functions of the big window. Every function is one separate model call that the UI starts
// on a button press (the model may be cold: these calls wait for it like a normal translation, up to coldLoadWait).
// All of them take the user's rules profile, glossary and tone into account.
//   - sentenceVariants: 2-3 other renderings of one sentence of the translation
//   - rewrite: shorter / softer / firmer / simpler / formal / informal version of the translation (guarded)
//   - explain: «what did they mean» for an incoming message, in the user's language
//   - replyRequest / translateReply: the reply flow (partner's message + user's answer) as an API
// Sentence pairs (no model) are in SentencePairs.swift.
import Foundation

// MARK: - Types

public struct SentenceVariant: Sendable, Equatable {
    public var text: String
    /// Short Russian label: «ближе к тексту», «разговорнее», «короче».
    public var label: String
    public init(text: String, label: String) { self.text = text; self.label = label }
}

/// One of 2-3 whole-translation alternatives with the model's own label and reason.
public struct TranslationVariant: Sendable, Equatable {
    public var text: String
    /// 1-3 words in the user's language, chosen by the model for this situation: «Строже», «Дружелюбнее», «Ближе к тексту».
    public var label: String
    /// One short phrase in the user's language: HOW this variant differs from the current translation.
    public var reason: String
    public init(text: String, label: String, reason: String) { self.text = text; self.label = label; self.reason = reason }
}

public enum RewriteMode: String, CaseIterable, Sendable {
    case shorter, softer, firmer, simpler, formal, informal, professional, direct

    public var russianTitle: String {
        switch self {
        case .shorter: "Короче"; case .softer: "Мягче"; case .firmer: "Твёрже"
        case .simpler: "Проще"; case .formal: "На «Вы»"; case .informal: "На «ты»"
        case .professional: "По-деловому"; case .direct: "Прямо"
        }
    }
}

/// Tone of a message composed from the user's points («Сформулировать»).
public enum ComposeTone: String, CaseIterable, Sendable {
    case neutral, professional, direct, friendly

    public var russianTitle: String {
        switch self {
        case .neutral: "Нейтрально"; case .professional: "По-деловому"; case .direct: "Прямо"; case .friendly: "Дружелюбно"
        }
    }

    var promptHint: String {
        switch self {
        case .neutral:
            "NEUTRAL: plain, polite, everyday wording, the middle of the road. Neither cold nor warm. No pressure, no flattery."
        case .professional:
            "BUSINESSLIKE: the shortest correct wording in standard business phrasing. Compact sentences, polite-neutral, impersonal where possible («Please note», «We would appreciate», «The report was delivered two days late»). No contractions, no filler, no apologies, no slang, no emotions, no chatty words. «Please» only if the points make a real request."
        case .direct:
            "DIRECT: position and consequence, nothing cushioning them. State what is wrong and what follows as plain facts («This doesn't work for us. If it happens again, we will stop.»). Requests become demands without «please», «could you», «would you mind», «if possible», «kindly»; short, flat sentences; no thanks, no warm-up, no apologies. But no rudeness, insults or threats beyond what the points say, and never harsher words than the points use."
        case .friendly:
            "FRIENDLY: warm and conversational, as to a colleague you like. Contractions («we'll», «it's», «doesn't»), casual connectors and light softeners («just», «really», «no worries», «could we», «it'd be great if»), a positive frame when the points allow it, No greeting word at the start, no thanks, no emoji. Still exactly the points: no new facts, promises or compliments."
        }
    }

    /// One example per tone for the same neutral case (different from anything users write about, so it cannot be copied).
    var promptExample: String {
        switch self {
        case .neutral: "The shipment arrived two days late. This is the second time. We would like it to arrive on time next time."
        case .professional: "The shipment was delivered two days late, for the second time. Please ensure timely delivery going forward."
        case .direct: "The shipment is two days late again. That's the second time. It has to arrive on time from now on."
        case .friendly: "The shipment came two days late again — that's the second time now. Could we please get it on time next time?"
        }
    }
}

public struct ComposeResult: Sendable, Equatable {
    /// The ready message in the recipient's language.
    public var text: String
    public var language: Language
    /// Honest translation of `text` back to the user's language (nil: not available or same language).
    public var backTranslation: String?
    /// Automatic check warnings: a number/time/date of the points is missing, or a number was added.
    public var warnings: [String]
    /// false = the tone could not make this (short) text different from the neutral one: the UI should say
    /// «тон не меняет этот текст» instead of showing four identical variants.
    public var toneChangesText: Bool
    /// The neutral text the style pass started from (nil for the neutral tone itself).
    public var neutralText: String?
    public init(text: String, language: Language, backTranslation: String?, warnings: [String],
                toneChangesText: Bool = true, neutralText: String? = nil) {
        self.text = text; self.language = language; self.backTranslation = backTranslation; self.warnings = warnings
        self.toneChangesText = toneChangesText; self.neutralText = neutralText
    }
}

public struct RewriteResult: Sendable, Equatable {
    public var mode: RewriteMode
    /// The new translation if `accepted`, otherwise the original text unchanged.
    public var text: String
    /// false = the safety net rejected the rewrite (twice); `text` is the original and `rejection` says why (Russian).
    public var accepted: Bool
    public var rejection: String?
    /// accepted and different from the original (false = the model found nothing to change).
    public var changed: Bool
    /// formal/informal: was the pronoun switch verified (only ru/uk/de/fr; false for English and others).
    public var pronounsChecked: Bool
    public init(mode: RewriteMode, text: String, accepted: Bool, rejection: String?, changed: Bool, pronounsChecked: Bool) {
        self.mode = mode; self.text = text; self.accepted = accepted; self.rejection = rejection
        self.changed = changed; self.pronounsChecked = pronounsChecked
    }
}

public struct MessageExplanation: Sendable, Equatable {
    /// 1-2 sentences in the user's language.
    public var meaning: String
    /// One short label: «нейтрально», «вежливый отказ», «раздражение», «шутка», «срочно», …
    public var tone: String
    /// Up to 5 «term — meaning» items; the terms are taken from the message.
    public var terms: [Term]
    public struct Term: Sendable, Equatable {
        public var term: String; public var meaning: String
        public init(term: String, meaning: String) { self.term = term; self.meaning = meaning }
    }
    public init(meaning: String, tone: String, terms: [Term]) { self.meaning = meaning; self.tone = tone; self.terms = terms }
}

public struct ReplyTranslation: Sendable, Equatable {
    public var text: String
    /// The partner's language (detected from their message) = the language of `text`.
    public var language: Language
    /// Automatic check warnings (lost numbers, links, ...).
    public var warnings: [String]
}

// MARK: - Engine API

extension DefaultTranslationEngine {
    /// Other renderings of ONE sentence of the translation. `sentence` = source sentence, `current` = its current
    /// translation, `fullSource`/`fullTranslation` = whole texts for context. Returns 0...3 variants (never the current one).
    /// Typical time 2-4 s. Throws if the model is unreachable.
    public func sentenceVariants(sentence: String, current: String, fullSource: String, fullTranslation: String,
                                 from: Language, to: Language, tone: Tone = .auto) async throws -> [SentenceVariant] {
        let ollama = try await readyOllama()
        let system = ExtrasPrompt.variants(from: from, to: to, tone: tone, rules: rules.promptBlock(for: fullSource + "\n" + sentence, target: to))
        let user = "FULL SOURCE:\n\(fullSource.prefix(3000))\n\nFULL TRANSLATION:\n\(fullTranslation.prefix(3000))\n\nSOURCE SENTENCE:\n\(sentence)\n\nCURRENT TRANSLATION OF THE SENTENCE:\n\(current)"
        guard let content = try await ollama.chatContent(system: system, user: user, json: true, maxTokens: 500, temperature: 0.5, timeout: 60)
        else { throw TolkError.badResponse("Модель не ответила") }
        return ExtrasParsing.variants(content, sentence: sentence, current: current, from: from, to: to)
    }

    /// 2-3 alternative translations of the WHOLE text, each with a label and a reason (one JSON request).
    /// Variants that lose a number/link/time, turn a question into a statement or drop a greeting are discarded,
    /// so the result can have 0...3 items (never the current translation, never repeats). Typical time 6-15 s.
    public func translationVariants(source: String, translation: String, from: Language, to: Language,
                                    tone: Tone = .auto, replyTo: String? = nil) async throws -> [TranslationVariant] {
        let ollama = try await readyOllama()
        let userLang = config.primaryLanguage
        let selector = [source, replyTo].compactMap { $0 }.joined(separator: "\n")
        let system = ExtrasPrompt.translationVariants(from: from, to: to, userLanguage: userLang, tone: tone,
                                                      rules: rules.promptBlock(for: selector, target: to))
        var user = "SOURCE:\n\(source.prefix(4000))\n\nCURRENT TRANSLATION:\n\(translation.prefix(4000))"
        if let r = replyTo?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
            user += "\n\nThe source is the user's REPLY to this message (keep the form of address and terms of the other person):\n\(r.prefix(2000))"
        }
        guard let content = try await ollama.chatContent(system: system, user: user, json: true, maxTokens: 1800, temperature: 0.5, timeout: 90)
        else { throw TolkError.badResponse("Модель не ответила") }
        return ExtrasParsing.translationVariants(content, source: source, current: translation, from: from, to: to)
    }

    /// Rewrites the current translation. `source` = original text, `translation` = current translation (language `to`).
    /// Never throws for a bad answer: a rejected rewrite comes back with `accepted == false` and the original text.
    /// Typical time 2-5 s.
    public func rewrite(translation: String, source: String, from: Language, to: Language, mode: RewriteMode) async throws -> RewriteResult {
        let ollama = try await readyOllama()
        let system = ExtrasPrompt.rewrite(mode: mode, from: from, to: to, rules: rules.promptBlock(for: source, target: to))
        var user = "SOURCE:\n\(source)\n\nCURRENT TRANSLATION:\n\(translation)"
        var rejection: String?
        for attempt in 0..<2 {
            guard let raw = try await ollama.chatContent(system: system, user: user, json: false, maxTokens: 2000, temperature: attempt == 0 ? 0.2 : 0.0, timeout: 90)
            else { throw TolkError.badResponse("Модель не ответила") }
            var edited = ExtrasParsing.cleanText(raw, original: translation)
            if mode == .formal { edited = ExtrasParsing.capitalizeFormal(edited, lang: to) }
            switch RewriteGuard.verdict(original: translation, edited: edited, source: source, mode: mode, from: from, to: to) {
            case let .ok(pronounsChecked):
                let same = edited.trimmingCharacters(in: .whitespacesAndNewlines) == translation.trimmingCharacters(in: .whitespacesAndNewlines)
                return RewriteResult(mode: mode, text: edited, accepted: true, rejection: nil, changed: !same, pronounsChecked: pronounsChecked)
            case let .rejected(why):
                rejection = why
                user += "\n\nYOUR PREVIOUS ATTEMPT WAS REJECTED: \(why). Try again and fix exactly this."
            }
        }
        return RewriteResult(mode: mode, text: translation, accepted: false, rejection: rejection, changed: false, pronounsChecked: false)
    }

    /// «What did they mean»: an incoming message in any language -> short analysis in `config.primaryLanguage`.
    /// Typical time 3-5 s.
    public func explain(message: String) async throws -> MessageExplanation {
        let ollama = try await readyOllama()
        let lang = config.primaryLanguage
        let system = ExtrasPrompt.explain(userLanguage: lang, rules: rules.promptBlock(for: message, target: lang))
        guard let content = try await ollama.chatContent(system: system, user: message.prefix(4000).description, json: true, maxTokens: 600, temperature: 0.2, timeout: 60),
              let result = ExtrasParsing.explanation(content, message: message)
        else { throw TolkError.badResponse("Модель вернула непонятный ответ") }
        return result
    }

    /// The request for the reply flow: `reply` is written by the user (any language, detected), the target is the
    /// language of the partner's `message` (detected), and the message is passed as context so the translation keeps
    /// the partner's terms, names and form of address.
    public func replyRequest(message: String, reply: String, tone: Tone = .auto) -> TranslationRequest {
        let partner = LanguageDetector.detect(message)
        var source = LanguageDetector.detect(reply)
        if source == partner { source = config.primaryLanguage == partner ? config.secondaryLanguage : config.primaryLanguage }
        return TranslationRequest(text: reply, source: source, target: partner, tone: tone, replyTo: message)
    }

    /// Whole reply flow in one call (collects the stream of `translate`). Typical time 2-6 s.
    public func translateReply(message: String, reply: String, tone: Tone = .auto) async throws -> ReplyTranslation {
        let request = replyRequest(message: message, reply: reply, tone: tone)
        var text = "", warnings: [String] = []
        for try await e in translate(request) {
            switch e {
            case let .delta(d): text += d
            case .started: text = ""
            case let .stats(st): warnings = st.warnings
            default: break
            }
        }
        return ReplyTranslation(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: request.target ?? .english, warnings: warnings)
    }

    /// «Сформулировать»: the user's points (their language, any wording, may be an instruction like «пусть отключит…»)
    /// -> a ready message to the recipient. The language is that of `partnerMessage` if there is one, otherwise `to`.
    /// The text must carry EVERY point and nothing else; numbers/times/dates are verified (warnings), the honest back-translation is a separate
    /// call (`composeBackTranslation`) so that the text appears right after the first answer. Typical time 3-6 s.
    /// The `TranslationEngine` requirement. Without this exact signature the protocol falls back to its default
    /// («недоступно для этого движка») — the variant with `neutral:` below does not satisfy the requirement.
    public func compose(points: String, tone: ComposeTone, to: Language, partnerMessage: String?, threadContext: String?) async throws -> ComposeResult {
        try await compose(points: points, tone: tone, to: to, partnerMessage: partnerMessage, threadContext: threadContext, neutral: nil)
    }

    public func compose(points: String, tone: ComposeTone, to: Language, partnerMessage: String? = nil, threadContext: String? = nil,
                        neutral: ComposeResult?) async throws -> ComposeResult {
        // Two passes: the neutral text carries the facts (checked); a non-neutral tone is a style transfer of it.
        // `neutral` = an already composed neutral result of the same points (the window keeps it between tones).
        let base: ComposeResult
        if let neutral { base = neutral } else { base = try await composeFacts(points: points, tone: .neutral, to: to, partnerMessage: partnerMessage, threadContext: threadContext) }
        if tone == .neutral { return base }
        let ollama = try await readyOllama()
        let lang = base.language
        let system = ExtrasPrompt.toneTransfer(tone: tone, language: lang, rules: rules.promptBlock(for: points + "\n" + (partnerMessage ?? ""), target: lang))
        var user = "NEUTRAL TEXT:\n\(base.text)"
        var best: (text: String, bad: [String], sim: Double)? = nil
        for attempt in 0..<3 {
            guard let raw = try await ollama.chatContent(system: system, user: user, json: false, maxTokens: 1000, temperature: attempt == 0 ? 0.3 : 0.5, timeout: 90),
                  case let t = ExtrasParsing.cleanText(raw, original: base.text), !t.isEmpty else { continue }
            var bad = ExtrasParsing.composeWarnings(points: base.text, text: t, from: lang, to: lang, partnerMessage: partnerMessage ?? "")
            bad += ExtrasParsing.invented(points: points + "\n" + base.text, text: t, partnerMessage: partnerMessage ?? "")
            bad += ToneLexicon.violations(t, tone: tone, language: lang)
            if LanguageDetector.detect(t) != lang { bad.append("FRIENDLY/DIRECT/BUSINESSLIKE output must be in \(lang.englishName) only, not another language") }
            let sim = ToneLexicon.similarity(t, base.text)
            if sim >= 0.8 { bad.append("the text is almost the same as the neutral one: rephrase every sentence in the register of the tone") }
            if best == nil || (bad.count, -sim) < (best!.bad.count, -best!.sim) { best = (t, bad, sim) }
            if bad.isEmpty { break }
            user = "NEUTRAL TEXT:\n\(base.text)\n\nYOUR PREVIOUS ATTEMPT WAS REJECTED:\n«\(t)»\nProblems: \(bad.joined(separator: "; ")). Write it again, fix exactly this, keep every fact."
        }
        guard let best else { return ComposeResult(text: base.text, language: lang, backTranslation: nil, warnings: base.warnings, toneChangesText: false, neutralText: base.text) }
        // Facts lost / invented in the style pass: fall back to the checked neutral text, flagged as «tone does not change it».
        let factProblems = best.bad.filter { !$0.hasPrefix("the text is almost") && !$0.hasPrefix("tone") }
        let leaked = best.bad.contains { $0.hasPrefix("тон") || $0.hasPrefix("в сообщении") || $0.hasPrefix("потер") || $0.hasPrefix("⚠") }
        if leaked || !factProblems.filter({ ExtrasParsing.isFactProblem($0) }).isEmpty {
            return ComposeResult(text: base.text, language: lang, backTranslation: nil, warnings: base.warnings, toneChangesText: false, neutralText: base.text)
        }
        let differs = best.sim < 0.8
        return ComposeResult(text: differs ? best.text : base.text, language: lang, backTranslation: nil,
                             warnings: differs ? [] : base.warnings, toneChangesText: differs, neutralText: base.text)
    }

    /// First pass of `compose`: points → message in the given tone (checked for numbers/invented words), as before.
    func composeFacts(points: String, tone: ComposeTone, to: Language, partnerMessage: String?, threadContext: String?) async throws -> ComposeResult {
        let ollama = try await readyOllama()
        let partner = partnerMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (partner?.isEmpty == false) ? LanguageDetector.detect(partner!) : to
        let pointsLang = LanguageDetector.detect(points)
        let system = ExtrasPrompt.compose(tone: tone, pointsLanguage: pointsLang, to: target, hasPartner: partner?.isEmpty == false,
                                          rules: rules.promptBlock(for: points + "\n" + (partner ?? ""), target: target))
        var user = "POINTS:\n\(points.prefix(3000))"
        if let partner, !partner.isEmpty { user += "\n\nPARTNER'S MESSAGE (the user answers it; keep the partner's terms and form of address):\n\(partner.prefix(2000))" }
        if let t = threadContext?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            user += "\n\nEARLIER IN THIS CHAT (background only: do not repeat or answer it):\n\(t.suffix(1500))"
        }
        var text = "", warnings: [String] = []
        for attempt in 0..<2 {
            guard let raw = try await ollama.chatContent(system: system, user: user, json: false, maxTokens: 1500, temperature: attempt == 0 ? 0.3 : 0.0, timeout: 90)
            else { throw TolkError.badResponse("Модель не ответила") }
            text = ExtrasParsing.cleanText(raw, original: points)
            warnings = ExtrasParsing.composeWarnings(points: points, text: text, from: pointsLang, to: target, partnerMessage: partner ?? "")
            if warnings.isEmpty || text.isEmpty { break }
            user += "\n\nYOUR PREVIOUS ATTEMPT WAS REJECTED: \(warnings.joined(separator: "; ")). Write it again and fix exactly this; add nothing that is not in the points."
        }
        if text.isEmpty { throw TolkError.badResponse("Модель вернула пустой ответ") }
        return ComposeResult(text: text, language: target, backTranslation: nil, warnings: warnings)
    }

    /// The model must be up: wait for a cold load like a normal translation does.
    func readyOllama() async throws -> OllamaProvider {
        guard let ollama = primary as? OllamaProvider else { throw TolkError.unavailable("Эта функция работает только через модель на сервере") }
        if await ollama.isAvailable() == false { throw TolkError.unavailable("сервер недоступен (Ollama не отвечает)") }
        if await ollama.ensureReady(timeout: Self.coldLoadWait) == .stillLoading {
            throw TolkError.unavailable("модель ещё загружается на сервере (холодный старт), попробуйте через минуту")
        }
        return ollama
    }
}

extension TranslationEngine {
    /// Honest translation of a composed message back to the user's language (nil: same language or failed). Typical time 5-9 s.
    public func composeBackTranslation(of result: ComposeResult, userLanguage userLang: Language) async -> String? {
        guard result.language != userLang else { return nil }
        var acc = ""
        do {
            for try await e in translate(TranslationRequest(text: result.text, source: result.language, target: userLang, tone: .auto)) {
                switch e {
                case let .delta(d): acc += d
                case .started: acc = ""
                default: break
                }
            }
        } catch { return nil }
        let t = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - HTTP

extension OllamaProvider {
    /// One non-streamed chat completion; the text of the answer. nil = no usable answer.
    func chatContent(system: String, user: String, json: Bool, maxTokens: Int, temperature: Double, timeout: TimeInterval) async throws -> String? {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        var body: [String: Any] = [
            "model": model, "stream": false, "reasoning_effort": "none", "temperature": temperature, "seed": 42,
            "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        authorize(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw TolkError.http(provider: name, status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: Self.errorMessage(data))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }
}

// MARK: - Prompts

enum ExtrasPrompt {
    static func variants(from: Language, to: Language, tone: Tone, rules: String) -> String {
        var s = PromptCatalog.filled("tools.sentenceVariants", ["from": from.englishName, "to": to.englishName])
        if !rules.isEmpty { s += "\n\n# User's rules and glossary (authoritative)\n" + rules }
        s += "\n\n# Tone of the text\n" + Prompt.tone(tone)
        return s
    }

    static func translationVariants(from: Language, to: Language, userLanguage: Language, tone: Tone, rules: String) -> String {
        var s = PromptCatalog.filled("tools.variants", ["from": from.englishName, "to": to.englishName, "user": userLanguage.englishName])
        if !rules.isEmpty { s += "\n\n# User's rules and glossary (authoritative)\n" + rules }
        s += "\n\n# Tone of the text\n" + Prompt.tone(tone)
        return s
    }

    static func rewrite(mode: RewriteMode, from: Language, to: Language, rules: String) -> String {
        let what: String
        switch mode {
        case .shorter:
            what = "Make it SHORTER: about a quarter to a third fewer words. Cut filler, repetition and wordy phrases; keep every fact, number, name, date and request."
        case .softer:
            what = "Make it SOFTER and more tactful: less blunt, more polite, soften demands into requests and criticism into suggestions. Do not add apologies that change the meaning and do not drop any fact or request."
        case .firmer:
            what = "Make it FIRMER and more direct: confident, no hedging or softeners («perhaps», «if possible», «sorry to bother»), clear about what is needed and by when. Stay polite and professional: no rudeness, no threats, no new demands or deadlines that are not in the text."
        case .simpler:
            what = "Make it SIMPLER: plain everyday words, shorter sentences, no bureaucratic or bookish phrases, so that anyone understands it at once. Keep glossary terms and technical terms that have no plain equivalent. Keep all facts."
        case .professional:
            what = "Make it BUSINESSLIKE: the shortest correct standard business wording, impersonal where possible, compact sentences. Remove contractions, slang, chatty words, emotions, filler, apologies and repeated «please». Replace rude or emotional words with neutral professional ones. Keep every fact, request and condition, and the same strength of position: do not soften or sharpen it. Example: «Hey, the shipment came two days late again, could you please fix that?» -> «The shipment was delivered two days late again. Please address this.» Add nothing: no new subjects, greetings, promises, deadlines or terms."
        case .direct:
            what = "Make it DIRECT: position and consequence, no cushioning. Turn every request into a plain statement of what is needed or what is wrong, remove «please», «could you», «would you mind», «if possible», «perhaps», «kindly», «sorry», «unfortunately», «we would appreciate», thanks and warm-up phrases; short flat sentences. Example: «Could you please look into the late shipment? We would appreciate it if it arrived on time.» -> «The shipment is late. It has to arrive on time.» If the text is already direct, change little. Never harsher than the original: no rudeness, no insults, no stronger words («not good» must not become «unacceptable»), no new threats, demands, deadlines, subjects or terms."
        case .formal:
            what = "Switch the form of address to FORMAL and the register to polite and businesslike (\(formalHint(to))). Change pronouns and the verb forms that go with them everywhere, consistently. Do not make the text longer than needed."
        case .informal:
            what = "Switch the form of address to INFORMAL, friendly chat style (\(informalHint(to))). Change pronouns and the verb forms that go with them everywhere, consistently. Do not add slang or swearing that is not in the original."
        }
        var s = PromptCatalog.filled("tools.rewrite", ["from": from.englishName, "to": to.englishName, "what": what])
        if !rules.isEmpty { s += "\n\n# User's rules and glossary (authoritative)\n" + rules }
        return s
    }

    static func compose(tone: ComposeTone, pointsLanguage: Language, to: Language, hasPartner: Bool, rules: String) -> String {
        var s = PromptCatalog.filled("tools.compose", ["points": pointsLanguage.englishName, "to": to.englishName, "tone": tone.promptHint, "example": tone.promptExample])
        if hasPartner { s += "\nThe message answers the PARTNER'S MESSAGE: use the form of address (you/Вы/du/Sie) and the terms the partner uses." }
        if !rules.isEmpty { s += "\n\n# User's rules and glossary (authoritative)\n" + rules }
        return s
    }

    /// Second pass: restyle a finished neutral text into one tone. Facts stay, register changes.
    static func toneTransfer(tone: ComposeTone, language l: Language, rules: String) -> String {
        let en = l == .english
        let reg: String, ex: String
        switch tone {
        case .neutral:
            reg = tone.promptHint; ex = ""
        case .professional:
            reg = """
            BUSINESSLIKE register: complete forms, no contractions, no chatty words, no slang; formal vocabulary (provide, confirm, resolve, inform, require; \
            in Russian/Ukrainian: «просимо», «прошу», «необхідно», «у зв'язку з», «забезпечити»). Keep WHO does what: keep «we» and «you» as subjects, \
            do NOT turn sentences into passive or impersonal ones that hide the actor («we will stop» stays «we will stop», never «it will be stopped»). \
            Keep every sentence a direct statement or request; no new politeness formulas and no apologies the text does not have.
            """
            ex = en ? """
            Example (other topic). NEUTRAL: «The files still haven't come and we're waiting. Can you send them today?» → BUSINESSLIKE: «We have not yet received the files. Please send them today.»
            Example. NEUTRAL: «We don't like how this went, so we'll stop if it happens again.» → BUSINESSLIKE: «We are dissatisfied with how this was handled. If it recurs, we will discontinue the cooperation.»
            """ : ""
        case .direct:
            reg = """
            DIRECT register: no cushioning at all. Requests become imperatives (a short command) or a plain «we will…» / «we need…»; \
            NO «please», «could you», «would you», «would like», «kindly», «if possible», «we hope», «perhaps», «appreciate» (in Russian/Ukrainian also no «будь ласка», «пожалуйста», «не могли б»). \
            Short flat sentences, one fact each; consequences stated as facts. No thanks, no warm-up, no apologies. \
            An offer or suggestion («let's have a call») stays an offer, only requests and demands become commands. Not rude, nothing harsher than the neutral text.
            """
            ex = en ? """
            Example (other topic). NEUTRAL: «The files still haven't come and we're waiting. Could you please send them today?» → DIRECT: «We have not received the files. Send them today.»
            Example. NEUTRAL: «Please disable all test traffic, and we will try again tomorrow.» → DIRECT: «Disable all test traffic. We will try again tomorrow.»
            """ : ""
        case .friendly:
            reg = """
            FRIENDLY register: warm, conversational, like to a colleague you like. Contractions (we'll, it's, don't), casual connectors (so, and), \\
            light softeners for requests («could you», «it'd be great if», «no worries»; in Russian/Ukrainian «давай», «можешь», «було б круто»). \\
            No stiff office words (ensure, provide, kindly, regarding, inform). Do NOT start with a fixed lead-in such as «Just a heads-up» or «Quick note»: begin straight with the content. \\
            No greeting word, no thanks, no emoji, no compliments, nothing the neutral text does not say.
            """
            ex = en ? """
            Example (other topic). NEUTRAL: «The files have not been received. Please send them today.» → FRIENDLY: «The files haven't come through yet, so could you send them over today?»
            Example. NEUTRAL: «The meeting is moved to Friday because the room is busy.» → FRIENDLY: «We're moving the meeting to Friday, the room's taken.»
            """ : ""
        }
        var s = """
        You restyle a finished message. Input: NEUTRAL TEXT in \(l.englishName). Output: the same message in the tone below. \
        The output language is \(l.englishName) ONLY (the same as the input): never switch language, never use English examples as wording in another language.
        \(reg)
        \(ex)
        Hard rules:
        - Keep EVERY fact, request, condition, number, date, name and the strength of every opinion. Add NOTHING: no new reasons, promises, offers, thanks, greetings, apologies, lead-ins.
        - Change the wording clearly: reword every sentence in the register, do not copy it. Do not just add or drop one word.
        - Keep «if» as «if»; a demand stays a demand; keep the form of address (you/Вы/Ви) and who does what.
        Output ONLY the restyled text: no comments, no quotes, no alternatives.
        """
        if !rules.isEmpty { s += "\n\n# User's rules and glossary (authoritative)\n" + rules }
        return s
    }

    static func formalHint(_ l: Language) -> String {
        switch l {
        case .russian: "«Вы» with a capital letter, «Здравствуйте», «не могли бы Вы»"
        case .ukrainian: "«Ви» with a capital letter, «Доброго дня», «чи не могли б Ви»"
        case .german: "«Sie»"; case .french: "«vous»"; case .spanish: "«usted»"
        default: "polite, complete sentences, no contractions, no slang"
        }
    }

    static func informalHint(_ l: Language) -> String {
        switch l {
        case .russian: "«ты», «привет»"; case .ukrainian: "«ти», «привіт»"
        case .german: "«du»"; case .french: "«tu»"; case .spanish: "«tú»"
        default: "casual wording as people write in chats, contractions are fine"
        }
    }

    static func explain(userLanguage: Language, rules: String) -> String {
        var s = PromptCatalog.filled("tools.explain", ["user": userLanguage.englishName])
        if !rules.isEmpty { s += "\n\n# The user's work glossary (helps with jargon)\n" + rules }
        return s
    }
}

// MARK: - Parsing

/// Lexical checks of a tone: what the register forbids («Прямо» has no «please», «По-деловому» no contractions).
enum ToneLexicon {
    static func has(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }

    static func violations(_ text: String, tone: ComposeTone, language: Language) -> [String] {
        var v: [String] = []
        switch (tone, language) {
        case (.direct, .english):
            if has("\\bplease\\b|could you|would you|kindly|would like|if possible|we hope|\\bperhaps\\b|we appreciate|i think|would be great", text) { v.append("DIRECT must not use please / could you / would like / kindly / hope: use imperatives or «we will»") }
        case (.direct, .ukrainian), (.direct, .russian):
            if has("будь ласка|будь-ласка|будьте ласкаві|пожалуйста|будьте добры|не могли б|не могли бы|чи не могли|якщо можливо|если возможно", text) { v.append("DIRECT must not use «будь ласка / пожалуйста / не могли б»: use imperatives or a flat statement") }
        case (.professional, .english):
            if has("\\b\\w+(n't|'ll|'re|'ve|'d|'m)\\b|\\b(it|that|there|he|she|here)'s\\b|\\bwe're\\b", text) { v.append("BUSINESSLIKE must not use contractions: write the full forms") }
            if has("\\b(will|would|can|is|are|was|were) be (made|stopped|requested|required|informed|liked|processed|sent|taken)\\b|\\bis not liked\\b", text) { v.append("BUSINESSLIKE must keep who does what: «we will…», «you must…», not passive voice") }
            if has("\\b(just|really|quick|a bit|pretty|heads-up|no worries)\\b", text) { v.append("BUSINESSLIKE must not use chatty words (just, really, quick, a bit)") }
        case (.professional, _) where language != .english && language != .ukrainian && language != .russian: break
        case (.friendly, .english):
            if has("^(just a heads-up|quick note|heads-up|just a quick)", text.trimmingCharacters(in: .whitespaces)) { v.append("FRIENDLY must not start with a fixed lead-in (heads-up / quick note): start with the content") }
            if !has("\\b\\w+(n't|'ll|'re|'ve|'d|'m)\\b|\\b(it|that|there|here)'s\\b|\\bwe're\\b|\\bjust\\b|\\breally\\b|\\bquick\\b|no worries|heads-up|\\bso\\b", text) { v.append("FRIENDLY needs contractions and casual connectors (we'll, it's, just, so)") }
            if has("\\b(ensure|provide|kindly|regarding|inform|pursuant|herewith)\\b", text) { v.append("FRIENDLY must not use stiff office words (ensure, provide, kindly, regarding)") }
        default: break
        }
        return v
    }

    static func words(_ s: String) -> Set<String> { Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)) }
    /// Jaccard similarity of the word sets (1 = same words).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        return x.isEmpty && y.isEmpty ? 1 : Double(x.intersection(y).count) / Double(max(1, x.union(y).count))
    }
}

enum ExtrasParsing {
    /// A check problem that means a lost / invented FACT (not a style complaint).
    static func isFactProblem(_ w: String) -> Bool { !w.hasPrefix("DIRECT") && !w.hasPrefix("BUSINESSLIKE") && !w.hasPrefix("FRIENDLY") }

    static func jsonObject(_ content: String) -> [String: Any]? {
        var json = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = json.firstIndex(of: "{"), let b = json.lastIndex(of: "}"), a <= b { json = String(json[a...b]) }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    static func norm(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!…\"«»“” "))
    }

    /// Variants: element by element, without repeats of the current sentence, with a default label, losing no numbers.
    static func variants(_ content: String, sentence: String, current: String, from: Language, to: Language) -> [SentenceVariant] {
        guard let root = jsonObject(content), let raw = (root["variants"] ?? root["alternatives"]) as? [Any] else { return [] }
        var seen: Set<String> = [norm(current)]
        var out: [SentenceVariant] = []
        for item in raw {
            var text: String?, label = ""
            if let o = item as? [String: Any] {
                text = (o["text"] ?? o["variant"] ?? o["translation"]) as? String
                label = (o["label"] as? String) ?? ""
            } else if let s = item as? String { text = s }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  seen.insert(norm(t)).inserted else { continue }
            // A variant that loses a number/link of the source sentence is worse than none.
            if !TranslationCheck.warnings(source: sentence, translation: t, from: from, to: to).filter({ !$0.hasPrefix("текст") && !$0.contains("язык") }).isEmpty { continue }
            label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(SentenceVariant(text: t, label: label.isEmpty ? "другой вариант" : label))
            if out.count == 3 { break }
        }
        return out
    }

    /// Whole-translation variants: JSON with fallbacks (fence, junk around, bare array, «alternatives» key), then the safety net.
    static func translationVariants(_ content: String, source: String, current: String, from: Language, to: Language) -> [TranslationVariant] {
        var raw: [Any]?
        if let root = jsonObject(content) {
            raw = (root["variants"] ?? root["alternatives"] ?? root["translations"]) as? [Any]
        }
        if raw == nil, let a = content.firstIndex(of: "["), let b = content.lastIndex(of: "]"), a < b,
                  let arr = try? JSONSerialization.jsonObject(with: Data(content[a...b].utf8)) as? [Any] {
            raw = arr
        }
        guard let raw else { return [] }
        var seen: Set<String> = [norm(current)]
        var shown: [String] = [current]
        var out: [TranslationVariant] = []
        for item in raw {
            var text: String?, label = "", reason = ""
            if let o = item as? [String: Any] {
                text = (o["text"] ?? o["translation"] ?? o["variant"]) as? String
                label = (o["label"] ?? o["title"]) as? String ?? ""
                reason = (o["reason"] ?? o["why"] ?? o["explanation"]) as? String ?? ""
            } else if let s = item as? String { text = s }
            guard let t = text.map({ cleanText($0, original: current) }), !t.isEmpty,
                  seen.insert(norm(t)).inserted else { continue }
            if variantRejection(source: source, current: current, variant: t, from: from, to: to) != nil { continue }
            if shown.contains(where: { nearlySame($0, t) }) { continue }   // a one-letter difference is not a variant
            shown.append(t)
            label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.split(separator: " ").count > 4 { label = label.split(separator: " ").prefix(3).joined(separator: " ") }
            out.append(TranslationVariant(text: t, label: label.isEmpty ? "Другой вариант" : label,
                                          reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)))
            if out.count == 3 { break }
        }
        return out
    }

    /// Why a whole-translation variant must not be shown (nil = fine). Same net as `rewrite`: numbers/links/times,
    /// question -> statement, lost greeting. A different greeting is allowed (a stricter variant says «Здравствуйте» instead of «Привет»).
    static func variantRejection(source: String, current: String, variant: String, from: Language, to: Language) -> String? {
        let lost = TranslationCheck.warnings(source: source, translation: variant, from: from, to: to)
            .filter { !$0.hasPrefix("текст") && !$0.lowercased().contains("язык") }
        if let w = lost.first { return w }
        if RefineGuard.endsWithQuestion(current) && !RefineGuard.endsWithQuestion(variant) { return "вопрос стал утверждением" }
        if opensWithGreeting(current), !opensWithGreeting(variant) { return "пропало приветствие" }
        return nil
    }

    /// Word sets overlap by 80 % or more (case and punctuation ignored).
    static func nearlySame(_ a: String, _ b: String) -> Bool {
        let x = Set(RewriteGuard.words(a.lowercased())), y = Set(RewriteGuard.words(b.lowercased()))
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.8
    }

    /// A greeting among the first three words («Привет, Анна», «Анна, привет!», «Good morning»).
    static func opensWithGreeting(_ s: String) -> Bool {
        let words = s.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).prefix(3)
        for i in words.indices {
            let tail = words[i...].joined(separator: " ")
            if RefineGuard.greetingKey(tail) != nil { return true }
        }
        return false
    }

    static func explanation(_ content: String, message: String) -> MessageExplanation? {
        guard let root = jsonObject(content), let meaning = (root["meaning"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !meaning.isEmpty else { return nil }
        let tone = ((root["tone"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        var terms: [MessageExplanation.Term] = []
        for o in (root["terms"] as? [[String: Any]]) ?? [] {
            guard let t = (o["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  let m = (o["meaning"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty,
                  lowered.contains(t.lowercased()) else { continue }   // hallucinated terms are dropped
            if terms.contains(where: { $0.term.lowercased() == t.lowercased() }) { continue }
            terms.append(.init(term: t, meaning: m))
            if terms.count == 5 { break }
        }
        return MessageExplanation(meaning: meaning, tone: tone.isEmpty ? "нейтрально" : tone, terms: terms)
    }

    /// Digits of a text as comparable tokens («4,8» and «4.8» are the same, spaces and % are ignored).
    static func numberTokens(_ s: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: "\\d+(?:[.,:]\\d+)*") else { return [] }
        var out = Set<String>()
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let r = Range(m.range, in: s) { out.insert(s[r].replacingOccurrences(of: ",", with: ".")) }
        }
        return out
    }

    /// Check of a composed message: numbers/times/dates/links of the points must be in it, no number may appear from nowhere.
    static func composeWarnings(points: String, text: String, from: Language, to: Language, partnerMessage: String = "") -> [String] {
        var out = TranslationCheck.warnings(source: points, translation: text, from: from, to: to)
            .filter { !$0.hasPrefix("текст") && !$0.lowercased().contains("язык") }
        let added = numberTokens(text).subtracting(numberTokens(points + " " + partnerMessage))
        if !added.isEmpty { out.append("в сообщении появилось то, чего нет в тезисах: \(added.sorted().joined(separator: ", "))") }
        out += invented(points: points, text: text, partnerMessage: partnerMessage)
        return out
    }

    /// Things the model likes to add on its own: (what it looks like in the text, how it may look in the points).
    /// A group fires only when the text has it and neither the points nor the partner's message do.
    static let inventedGroups: [(name: String, text: String, source: String)] = [
        ("integration", "integrat|інтеграц|интеграц", "integrat|інтеграц|интеграц"),
        ("refund", "refund|money back|reimburs|рефанд|повернен|поверн.*грош|возврат|верн[а-я]+ дены", "refund|money back|рефанд|повернен|поверн|возврат|верн|деньг|грош|кошт"),
        ("deadline", "deadline|дедлайн|крайн\\p{L}+ срок|кінцев\\p{L}+ термін", "deadline|дедлайн|срок|термін|до \\d|by \\d|сегодня|сьогодні|завтра|today|tomorrow"),
        ("penalty/legal", "penalt|\\bfine\\b|lawsuit|legal action|court|штраф|судов|позов|суд\\b", "penalt|штраф|суд|позов|legal|court|юрист"),
        ("discount", "discount|знижк|скидк", "discount|знижк|скидк|цен|ціна|ціну|price"),
        ("contract", "contract|agreement|контракт|договір|договор", "contract|agreement|контракт|договор|договір"),
        ("«unacceptable»", "unacceptable|not acceptable|outrageous|inacceptable|неприйнятн|недопустим|неприемлем|obscene|disgrac", "неприйнятн|недопустим|неприемлем|unacceptable|not acceptable|безобраз|свинств"),
        ("CPM/CPA/CTR", "\\b(e?cpm|cpa|cpc|ctr|cpl|roi)\\b", "\\b(e?cpm|cpa|cpc|ctr|cpl|roi)\\b"),
        ("urgency", "\\basap\\b|urgent|immediately|right away|терміново|негайно|срочно|немедленно", "срочно|терміново|asap|urgent|немедленно|негайно|сразу|одразу|прямо сейчас|зараз"),
    ]

    static func invented(points: String, text: String, partnerMessage: String = "", rewrite: Bool = false) -> [String] {
        let src = (points + "\n" + partnerMessage).lowercased(), out = text.lowercased()
        var res: [String] = []
        func has(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        for g in inventedGroups where has(g.text, out) && !has(g.source, src) {
            res.append("в сообщении появилось то, чего нет в тезисах: «\(g.name)»")
        }
        // A greeting the points did not ask for (the partner's own greeting does not count: a reply starting with «Привет!» is not wanted).
        let greetWords = "привет|привіт|здравств|добрый|доброго|добрий|вітаю|поздоров|\\bhi\\b|hello|\\bhey\\b|dear|greeting|good (morning|day|afternoon)"
        if opensWithGreeting(text), !has(greetWords, points.lowercased()) { res.append("в сообщении появилось приветствие, которого не просили") }
        // A style instruction written out as a sentence («we want to be direct», «not overly gentle»).
        let leak = "(want|like|need|have|going) to be (direct|honest|frank|blunt)|(be|being|are|is) (direct|frank|blunt) (with|about)|(overly|too|very) (gentle|careful|soft|nice)|(without|no) (being )?(aggress|rude)|not (be )?(aggressive|rude)|don't need to be|do not need to be|speak (plainly|directly|frankly)|(state|say|tell them|let them know|make it clear) (it )?(directly|clearly|plainly|frankly)"
        if has(leak, out), rewrite ? !has(leak, src) : has("аккуратн|агресс|прямо|помягч|мягк|официоз|не грубо|без наезд|обережн|без агрес", src) {
            res.append("указание о тоне попало в текст как фраза")
        }
        return res
    }

    /// The same checks for a rewritten translation: what the original text did not have must not appear.
    static func inventedInRewrite(original: String, edited: String) -> String? {
        invented(points: original, text: edited).first
    }

    /// Formal «Вы»/«Ви» forms are written with a capital letter (user rule): fix lower-case ones the model left.
    static func capitalizeFormal(_ text: String, lang: Language) -> String {
        guard lang == .russian || lang == .ukrainian else { return text }
        let list = lang == .russian ? RewriteGuard.formalRU : RewriteGuard.formalUK
        let pattern = "(?<![\\p{L}])(" + list.joined(separator: "|") + ")(?![\\p{L}])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: out[r].prefix(1).uppercased() + out[r].dropFirst())
        }
        return out
    }

    /// Strips code fences, a leading «Here is…:» line and quotes the model wraps around the answer.
    static func cleanText(_ raw: String, original: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```[a-zA-Z]*\\n?", with: "", options: .regularExpression)
                .replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("«", "»"), ("“", "”")]
        for (l, r) in pairs where t.first == l && t.last == r && t.count > 2 && !(o.first == l && o.last == r) {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return t
    }
}

// MARK: - Safety net for rewrites

enum RewriteGuard {
    enum Verdict: Equatable { case ok(pronounsChecked: Bool), rejected(String) }

    static let informalRU = ["ты", "тебя", "тебе", "тобой", "твой", "твоя", "твоё", "твоего", "твоей", "твоему", "твои", "твоих", "твоим", "твоими"]
    static let formalRU = ["вы", "вас", "вам", "вами", "ваш", "ваша", "ваше", "вашего", "вашей", "вашему", "ваши", "ваших", "вашим", "вашими"]
    static let informalUK = ["ти", "тебе", "тобі", "тобою", "твій", "твоя", "твоє", "твого", "твоєї", "твоєму", "твої", "твоїх", "твоїм"]
    static let formalUK = ["ви", "вас", "вам", "вами", "ваш", "ваша", "ваше", "вашого", "вашої", "вашому", "ваші", "ваших", "вашим"]
    static let informalDE = ["du", "dich", "dir", "dein", "deine", "deiner", "deinen", "deinem"]
    static let formalDE = ["sie", "ihnen", "ihr", "ihre", "ihrer", "ihren", "ihrem"]
    static let informalFR = ["tu", "te", "toi", "ton", "ta", "tes"]
    static let formalFR = ["vous", "votre", "vos"]

    /// (informal, formal) pronoun lists for languages where the switch can be verified.
    static func pronouns(_ l: Language) -> (informal: [String], formal: [String])? {
        switch l {
        case .russian: (informalRU, formalRU)
        case .ukrainian: (informalUK, formalUK)
        case .german: (informalDE, formalDE)
        case .french: (informalFR, formalFR)
        default: nil
        }
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && $0 != "’" && $0 != "'" }).map { String($0) }
    }

    /// Number of pronoun hits in the text. German «Sie»/«Ihr…» only count capitalised (lower-case «sie» is «she/they»).
    static func hits(_ text: String, _ list: [String], lang: Language, formal: Bool) -> Int {
        words(text).filter { w in
            if lang == .german, formal { return list.contains(w.lowercased()) && w.first?.isUppercase == true && w != words(text).first }
            return list.contains(w.lowercased())
        }.count
    }

    static func verdict(original: String, edited: String, source: String, mode: RewriteMode, from: Language, to: Language) -> Verdict {
        let e = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return .rejected("пустой ответ") }
        // Numbers, links, times, IDs of the current translation must survive.
        let lost = TranslationCheck.warnings(source: original, translation: e, from: to, to: to)
            .filter { !$0.lowercased().contains("язык") }
        if let w = lost.first { return .rejected(w) }
        if RefineGuard.endsWithQuestion(original) && !RefineGuard.endsWithQuestion(e) { return .rejected("вопрос стал утверждением") }
        if mode != .formal, mode != .informal, let g = RefineGuard.greetingKey(original), RefineGuard.greetingKey(e) != g, mode != .shorter {
            return .rejected("сменилось приветствие")
        }
        if mode == .professional || mode == .direct || mode == .firmer {
            // A sharper or businesslike version must not invent numbers, dates or deadlines.
            let added = ExtrasParsing.numberTokens(e).subtracting(ExtrasParsing.numberTokens(original))
            if !added.isEmpty { return .rejected("появилось число, которого не было: \(added.sorted().joined(separator: ", "))") }
        }
        if mode == .professional || mode == .direct || mode == .firmer || mode == .softer,
           let why = ExtrasParsing.invented(points: original, text: e, rewrite: true).first {
            return .rejected(why.replacingOccurrences(of: "в сообщении появилось", with: "появилось").replacingOccurrences(of: "то, чего нет в тезисах", with: "то, чего не было в тексте"))
        }
        if mode == .direct || mode == .firmer {
            let soft = "\\b(please|could you|would you|kindly|if possible|perhaps|sorry|unfortunately|would appreciate|пожалуйста|будь ласка|могли бы|не могли бы|извините|вибачте|к сожалению|на жаль)\\b"
            let before = original.lowercased().ranges(of: try! Regex(soft)).count, after = e.lowercased().ranges(of: try! Regex(soft)).count
            if before > 0, after >= before { return .rejected("смягчающие слова остались: прямой тон — это позиция без «пожалуйста»/«не могли бы»") }
        }
        if mode == .shorter, e.count >= original.count, e != original.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .rejected("текст не стал короче")
        }
        if mode == .formal || mode == .informal, let p = pronouns(to) {
            let wantFormal = mode == .formal
            let wrong = wantFormal ? p.informal : p.formal
            let right = wantFormal ? p.formal : p.informal
            if hits(e, wrong, lang: to, formal: !wantFormal) > 0 {
                return .rejected(wantFormal ? "остались местоимения на «ты»" : "остались местоимения на «Вы»")
            }
            // The original used the other form, the edit must now use the wanted one somewhere (imperatives have no pronoun: then nothing to verify).
            if hits(original, wrong, lang: to, formal: !wantFormal) > 0, hits(e, right, lang: to, formal: wantFormal) == 0 {
                return .rejected(wantFormal ? "нет обращения на «Вы»" : "нет обращения на «ты»")
            }
            return .ok(pronounsChecked: true)
        }
        return .ok(pronounsChecked: false)
    }
}
