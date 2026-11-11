import Foundation

enum Prompt {
    static func system(for r: ResolvedRequest, rules: String) -> String {
        if r.mode == .polish { return polish(for: r, rules: rules) }
        var s = PromptCatalog.filled("translate.base", ["source": r.source.englishName, "target": r.target.englishName])
            + "\n" + antiCalque(for: r.target, source: r.text)
            + "\n" + consistency(for: r)
        let formal = PromptCatalog.filled("translate.formal", ["target": r.target.englishName])
        if !formal.isEmpty, FormalText.looksFormal(r.text) { s += "\n" + formal }
        if let ex = r.protectedExample { s += "\n\n# Protected placeholders\n" + EntityMasker.promptNote(example: ex) }
        if !rules.isEmpty {
            s += "\n\n# Extra translation rules and glossary (follow strictly)\n" + rules
        }
        if let t = r.threadContext, !t.isEmpty { s += "\n\n" + ThreadMemory.promptSection(t) }
        if let reply = r.replyTo?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            s += """


            # Conversation context
            The user's text is their REPLY to the message below. Translate only the reply.
            Reuse the other person's own words for the same things (names, terms, numbers),
            address them the same way they wrote (first name, formality), and keep it a natural reply in this thread.
            Their message:
            \"\"\"
            \(reply.prefix(4000))
            \"\"\"
            """
        }
        if let c = r.context, !c.source.isEmpty {
            s += """


            # Continuation
            The user's text is the CONTINUATION of a message whose beginning is already translated.
            Beginning (source):
            \"\"\"
            \(c.source.suffix(2000))
            \"\"\"
            Beginning (its translation, final — do not change it):
            \"\"\"
            \(c.translation.suffix(2000))
            \"\"\"
            Translate ONLY the user's new text, which follows the beginning. Do not repeat or rewrite the beginning.
            Stay consistent with it: the same terms, names, grammatical gender, form of address, formality and style.
            The new text may start in the middle of a sentence: continue it naturally (lower case if it continues a sentence).
            """
        }
        // Last, so an explicit tone choice wins over "keep the tone" style rules.
        s += "\n\n# Tone\n" + tone(r.tone)
        s += "\n\n# Output language\nWrite the translation in \(r.target.englishName)."
        if r.target == .ukrainian { s += " " + PromptCatalog.text("translate.uk") }
        return s
    }

    /// Same-language rewrite: the user's own draft, made correct and native-sounding.
    static func polish(for r: ResolvedRequest, rules: String) -> String {
        var s = PromptCatalog.filled("translate.polish", ["source": r.source.englishName])
        if !rules.isEmpty { s += "\n\n# User's rules and glossary\n" + rules }
        s += "\n\n# Tone\n" + tone(r.tone)
        return s
    }

    /// Calques are the main quality problem of a small model: it copies the source word order and idioms.
    /// The general line is always sent; the phrase rules only when their phrase is in `source` (see `PhraseRules`).
    /// `source` nil = general line only.
    static func antiCalque(for target: Language, source: String? = nil) -> String {
        let general: String
        switch target {
        case .russian, .ukrainian: general = PromptCatalog.filled("translate.calque.ru", ["target": target.englishName])
        case .english: general = PromptCatalog.text("translate.calque.en")
        default: return PromptCatalog.filled("translate.calque.other", ["target": target.englishName])
        }
        guard let source else { return general }
        let notes = PhraseRules.matching(source, target: target)
        return notes.isEmpty ? general : general + "\nNotes for phrases of this text:\n" + notes.map { "- " + $0 }.joined(separator: "\n")
    }

    /// Rules found by the 50-text comparison (2026-11-09): mixed «Вы/вы», English number format in Russian,
    /// doubled currency, untransliterated names.
    static func consistency(for r: ResolvedRequest) -> String {
        func lines(_ id: String) -> [String] {
            PromptCatalog.text(id).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var rules = lines("translate.rules.common")
        switch r.target {
        case .russian, .ukrainian: rules += lines("translate.rules.ru")
        default: rules += lines("translate.rules.en")
        }
        return rules.joined(separator: "\n")
    }

    static func tone(_ t: Tone) -> String {
        switch t {
        case .auto: PromptCatalog.text("translate.tone.auto")
        case .chat: PromptCatalog.text("translate.tone.chat")
        case .formal: PromptCatalog.text("translate.tone.formal")
        }
    }
}


/// Rules about one phrase or one piece of jargon, found on the trap corpus. Each goes into the prompt only when its
/// trigger is in the source text: always-on, they bled into unrelated sentences («до завершения проверки» came out
/// as «until this is clarified» because of the «до выяснения» rule, «Уточнить…» as «Also need to clarify…») and
/// made every prompt longer.
enum PhraseRules {
    struct Rule { let trigger: String; let text: String }

    /// Source Russian / Ukrainian → English.
    static let toEnglish: [Rule] = [
        Rule(trigger: #"\b(по)?прошу\b|\bпросим\b"#,
             text: "«Попрошу вас / прошу вас сделать X» is a request: write «Please do X», never «I'll ask you to»."),
        Rule(trigger: #"с (нашей|вашей) сторон"#,
             text: "«С нашей стороны / с вашей стороны» about traffic, feeds or data means where it goes or comes from (to our feeds, in your traffic), not «from our side»; keep who does what unambiguous."),
        Rule(trigger: #"\bзначит\b|раз так|раз вы\b"#,
             text: "«Значит / раз так, вы видите…» is a conclusion: write «so you can see / you clearly see», not «you must see» (it reads as an order)."),
        Rule(trigger: #"\bубра|\bубер|подлив|подмеш|\bот нас\b"#,
             text: "«Убрать X с вашей / нашей стороны», «убрать X от нас», «подливать / лить нам X» = remove X from the traffic you send us / stop sending us X: name whose traffic it is, never «from our side»."),
        Rule(trigger: #"\bль[юеёё]|\bлит[ьеи]\b|\bлил|залив|залит|зальё|\bчист"#,
             text: "«Лить / заливать / льёте» about traffic = send / drive traffic (not «campaign»); «чистый / всё чисто» = clean (not «clear»)."),
        Rule(trigger: #"сабайди|\bсаб(ы|ов|а|ам|ами|у)?\b|subid"#,
             text: "«Сабайди / сабы» = sub IDs (never transliterate: not «Sabaydi»), but keep «SubID» exactly as written."),
        Rule(trigger: #"\bлив(а|у|ом|е)?\b"#, text: "«Лив» (landing, traffic) = bounce / drop-off rate."),
        Rule(trigger: #"вынужден\w* (вас |вам )?(уведом|сообщ|проинформ|известить)"#, text: "«Вынуждены уведомить» = «we must inform you» (not «please be advised»)."),
        Rule(trigger: #"net-?\d\d"#, text: "«Net-30» = 30 days from the INVOICE date."),
        Rule(trigger: #"в дальнейшем|впредь|больше так"#,
             text: "«Не делайте так / этого в дальнейшем» = «please don't do this again» (not «moving forward»)."),
        Rule(trigger: #"\bне (показыва|да[её]т|отвеча|дела[её]т)"#,
             text: "«Не показываете / не даёте / не отвечаете / не делаете» = plain «you don't show / give / answer / do», never «you refuse to» (refusing is a stronger claim)."),
        Rule(trigger: #"\bлев(ый|ое|ая|ые|ого|ому|ым|ых|ую|ак)"#,
             text: "The slang word «левый / левое / левак» about traffic, geo, leads = off-target, unrelated or shady — not «invalid» or «fraudulent»."),
        Rule(trigger: #"\bmfa\b"#, text: "«MFA-сайты / MFA-площадки» = «MFA sites», keep the noun «sites», not «traffic»."),
        Rule(trigger: #"ну такое"#, text: "«Ну такое.» as a reaction = «Meh.» / «So-so.» (not «It's okay»)."),
        Rule(trigger: #"(?m)(^|[.!?…]\s+|\n)\s*(и |а |ещё |еще |также |не )?[а-яё]{3,}(ть|ться|ти|чь)\s"#,
             text: "A sentence that starts with an infinitive and has no subject («Уточнить реквизиты», «Не забыть отправить акт») is a to-do or reminder: keep it impersonal («Need to check…», «Don't forget to send…»); never invent a subject «I'll / I will», and add «also / and» only where the source has «и / ещё / также»."),
        Rule(trigger: #"обращаем (ваше )?внимание|сообщаем|уведомляем|информируем|повідомляємо|звертаємо увагу"#,
             text: "«Обращаем внимание / сообщаем / уведомляем, что…» = «Please note that…» or simply state the fact — never «Please be advised»."),
        Rule(trigger: #"до выяснения"#, text: "«До выяснения» = «until this is clarified» (not «until further notice»)."),
        Rule(trigger: #"закр(ываем|оем|ыли|ыть) вопрос"#, text: "«Закрываем вопрос» = «let's close the issue»."),
    ]

    /// Source English → Russian / Ukrainian.
    static let toRussian: [Rule] = [
        Rule(trigger: #"please advise"#, text: "«Please advise.» on its own (asking what to do next) → «Подскажите, как действовать дальше»; «could you please advise on / why / when …» is just a polite question → «подскажите, пожалуйста, …»."),
        Rule(trigger: #"(please|kindly) (note|be advised|be informed)"#, text: "«Please note / kindly note / please be advised» → «обратите внимание» (never «примите к сведению»)."),
        Rule(trigger: #"(moving|going) forward"#, text: "«Moving forward» → «в дальнейшем»."),
        Rule(trigger: #"per our (call|conversation|discussion)"#, text: "«Per our call» → «как договорились на созвоне»."),
        Rule(trigger: #"circle back"#, text: "«Circle back» → «вернёмся к этому»."),
        Rule(trigger: #"on (your|our|my) end"#, text: "«On your end» → «у вас» («on our end» → «у нас»)."),
        Rule(trigger: #"heads[- ]?up"#, text: "«Heads-up / quick heads-up» = «Предупреждаю: …» / «Чтобы вы знали: …» (keep it, never drop it)."),
        Rule(trigger: #"(?m)^\s*(also|and|plus|todo|to do)\b\s*[:,—-]"#,
             text: "An impersonal English line («Also: confirm the amount») stays impersonal («Ещё нужно уточнить сумму»), no invented «я»."),
        Rule(trigger: #"\bcommit"#, text: "«Commit to X» = «взять на себя обязательство по X / обязаться», not «гарантировать» (guarantee is a separate word)."),
        Rule(trigger: #"net-?\d\d"#, text: "Keep «Net-30 / Net-45» as written (it means payment is due 30 / 45 days after the INVOICE date; if you explain it, never «после оплаты»)."),
        Rule(trigger: #"\bfinance\b"#, text: "«Finance / the finance team» = «финансовый отдел / бухгалтерия», never «финтех»."),
        Rule(trigger: #"\bfyi\b"#, text: "«FYI» = «к сведению»."),
    ]

    /// Both directions: a chat header copied from Telegram.
    static let header = Rule(trigger: #"(?m)^[^\n\[\]]{2,80},\s\[[^\]\n]{0,40}\d{1,2}:\d{2}"#,
                             text: "A line like «Name Surname, [9 лист. 2026 р., 15:03:57]:» (chat header copied from Telegram) is NOT text: leave it exactly as written (no translation, no transliteration of the name, no date conversion).")

    /// Rules as editable text: one per line, «pattern => note».
    static func text(_ rules: [Rule]) -> String { rules.map { $0.trigger + " => " + $0.text }.joined(separator: "\n") }

    /// Lines without « => » or with a pattern that is not a valid regular expression are skipped.
    static func parse(_ text: String) -> [Rule] {
        text.components(separatedBy: "\n").compactMap { line in
            guard let r = line.range(of: " => ") else { return nil }
            let trigger = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let note = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty, !note.isEmpty, (try? NSRegularExpression(pattern: trigger, options: [.caseInsensitive])) != nil else { return nil }
            return Rule(trigger: trigger, text: note)
        }
    }

    /// The user's rewording of a rule list, else the built-in one.
    private static func rules(_ id: String, builtIn: [Rule]) -> [Rule] {
        PromptCatalog.isCustom(id) ? parse(PromptCatalog.text(id)) : builtIn
    }

    static func matching(_ source: String, target: Language) -> [String] {
        let rules: [Rule]
        switch target {
        case .english: rules = self.rules("translate.phrases.en", builtIn: toEnglish) + [header]
        case .russian, .ukrainian: rules = self.rules("translate.phrases.ru", builtIn: toRussian) + [header]
        default: return []
        }
        return rules.filter { source.range(of: $0.trigger, options: [.regularExpression, .caseInsensitive]) != nil }.map(\.text)
    }
}

/// A whole document was recognised as official: its paragraphs are translated and edited by the rules for official
/// texts even when a single paragraph has no marker of its own (set by the Documents page around its requests).
public enum FormalContext {
    @TaskLocal public static var forced = false
}

/// When the editor pass starts by itself after a translation (setting «Редактор после перевода»).
public enum AutoEditor {
    /// Documents: is the whole text an official one (so every paragraph gets the official-text rules)?
    public static func isOfficial(_ document: String) -> Bool { FormalText.looksFormal(document) }

    /// Documents: does this paragraph get the editor pass? Short lines (headings, signatures) are left alone.
    public static func wantedForParagraph(mode: String, paragraph: String, documentIsOfficial: Bool) -> Bool {
        guard paragraph.count >= 80 else { return false }
        switch mode {
        case "always": return true
        case "formal": return documentIsOfficial
        default: return false
        }
    }

    /// Texts shorter than this are left alone: the slips this pass is for happen in long sentences.
    public static let minChars = 200

    public static func wanted(mode: String, source: String) -> Bool {
        guard source.count >= minChars else { return false }
        switch mode {
        case "always": return true
        case "formal": return FormalText.looksFormal(source)
        default: return false
        }
    }
}

/// Does the text read like a contract, licence, terms or an official notice? Then `translate.formal` is added.
enum FormalText {
    static let markers = [
        #"\bhereby\b"#, #"\bherein\b"#, #"\bthereof\b"#, #"\bshall\b"#, #"without warranty"#, #"as is"#, #"\bliabilit"#, #"\bindemnif"#,
        #"terms (and|&) conditions"#, #"\bgoverning law\b"#, #"\bpursuant to\b"#, #"\bcopyright\b"#, #"\blicen[sc]e"#, #"\bagreement\b"#,
        #"настоящ(им|ий|его|ее|ем)\b"#, #"\bдоговор"#, #"\bсоглашени"#, #"\bлицензи"#, #"\bответственност"#, #"\bобязу(е|ю)тся"#,
        #"в соответствии с"#, #"\bнижеподписавш"#, #"\bцим\b"#, #"\bугод"#, #"\bзобов.язу"#, #"\bвідповідальн"#, #"\bліценз"#,
    ]

    /// Two different markers, or one in a text written mostly in capitals (disclaimers).
    static func looksFormal(_ text: String) -> Bool {
        if FormalContext.forced { return true }
        var hits = 0
        for m in markers where text.range(of: m, options: [.regularExpression, .caseInsensitive]) != nil {
            hits += 1
            if hits >= 2 { return true }
        }
        return false
    }
}
