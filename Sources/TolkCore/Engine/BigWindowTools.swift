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

public enum RewriteMode: String, CaseIterable, Sendable {
    case shorter, softer, firmer, simpler, formal, informal

    public var russianTitle: String {
        switch self {
        case .shorter: "Короче"; case .softer: "Мягче"; case .firmer: "Твёрже"
        case .simpler: "Проще"; case .formal: "На «Вы»"; case .informal: "На «ты»"
        }
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
            case let .started(_, _, _): text = ""
            case let .stats(st): warnings = st.warnings
            default: break
            }
        }
        return ReplyTranslation(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: request.target ?? .english, warnings: warnings)
    }

    /// The model must be up: wait for a cold load like a normal translation does.
    func readyOllama() async throws -> OllamaProvider {
        guard let ollama = primary as? OllamaProvider else { throw TolkError.unavailable("Эта функция работает только через модель на vkbox") }
        if await ollama.isAvailable() == false { throw TolkError.unavailable("vkbox недоступен (Ollama не отвечает)") }
        if await ollama.ensureReady(timeout: Self.coldLoadWait) == .stillLoading {
            throw TolkError.unavailable("модель ещё загружается на vkbox (холодный старт), попробуйте через минуту")
        }
        return ollama
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
        var s = """
        You help a translator. You get a \(from.englishName) text, its \(to.englishName) translation, ONE source sentence and its current translation.
        Give 2 or 3 OTHER ways to translate that sentence into \(to.englishName), each clearly different from the current one and from each other.
        Each variant must be a drop-in replacement for the current sentence: same meaning and facts, all numbers, names, links and glossary terms kept,
        the same form of address and grammatical gender as in the full translation, and it must fit between the neighbouring sentences.
        Natural native wording only, no calques. Do not repeat the current translation.
        Every variant has a short label in Russian (1-3 words) saying how it differs, for example: «ближе к тексту», «разговорнее», «короче», «формальнее», «мягче».
        Answer with JSON only: {"variants":[{"text":"...","label":"..."}]}
        """
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
        case .formal:
            what = "Switch the form of address to FORMAL and the register to polite and businesslike (\(formalHint(to))). Change pronouns and the verb forms that go with them everywhere, consistently. Do not make the text longer than needed."
        case .informal:
            what = "Switch the form of address to INFORMAL, friendly chat style (\(informalHint(to))). Change pronouns and the verb forms that go with them everywhere, consistently. Do not add slang or swearing that is not in the original."
        }
        var s = """
        You are a native \(to.englishName) editor. You get a SOURCE text in \(from.englishName) and its CURRENT TRANSLATION into \(to.englishName).
        Rewrite the CURRENT TRANSLATION as follows. \(what)
        Keep exactly: the meaning, all numbers, dates, times, names, links, e-mails, IDs, emoji, line breaks and the glossary terms below.
        Write numbers, currencies, times and dates exactly as in the CURRENT TRANSLATION (do not reformat «4,8 $» into «$4.8» or «7 PM» into «19:00»). Keep the letter «ё» if the translation uses it.
        Do not change the type of a sentence (a question stays a question). Do not add information.
        Output ONLY the rewritten text in \(to.englishName): no comments, no quotes around it, no alternatives.
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
        var s = """
        You help the user understand a message they received (in any language). Write ALL your answer in \(userLanguage.englishName).
        Be brief. Answer with JSON only:
        {"meaning":"...","tone":"...","terms":[{"term":"...","meaning":"..."}]}
        - "meaning": 1-2 short sentences: what the sender wants or says, including anything implied between the lines (a polite refusal, a hidden request, a deadline).
        - "tone": ONE or two words describing how it sounds: for example «нейтрально», «вежливый отказ», «раздражение», «шутка», «срочно», «дружелюбно», «настойчиво», «сарказм» (in \(userLanguage.englishName)).
        - "terms": up to 5 items — slang, jargon, idioms, abbreviations or cultural references that a non-native reader may not know; "term" is copied exactly from the message, "meaning" is a short explanation (at most 12 words). Skip ordinary words and names. Empty list if there is nothing to explain.
        Do not translate the whole message, do not give advice, do not add anything else.
        """
        if !rules.isEmpty { s += "\n\n# The user's work glossary (helps with jargon)\n" + rules }
        return s
    }
}

// MARK: - Parsing

enum ExtrasParsing {
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
