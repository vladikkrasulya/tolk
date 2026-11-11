// The instructions of the tools around a translation (footnotes, variants, compose, explain, rewrite), as
// editable blocks. Generated from the original string literals; `tolk-cli --prompt-digest` proves the assembled
// prompts did not change.
import Foundation

extension PromptCatalog {
    static let toolBlocks: [PromptBlock] = [
        PromptBlock(id: "tools.notes", group: .tools, title: "Сноски к переводу",
                    about: "Кнопка с лампочкой: модель ищет в исходном тексте до трёх спорных терминов и объясняет выбор перевода. Последнюю строку с JSON не меняйте — по ней программа разбирает ответ.",
                    placeholders: ["from", "to"], defaultText: #"""
You review a {from} → {to} translation.
Find at most 3 terms or phrases in the SOURCE that are specialist jargon, slang, idioms or ambiguous words,
where a generic translator often gets it wrong or inconsistent (the field comes from the user's glossary and the text itself).
Skip ordinary words, names, IDs and numbers.
The user's glossary below is authoritative: never suggest anything that contradicts it, and skip terms it already covers.
Suggest only what a native speaker would really write in a chat or email;
if you are not sure a variant is better, leave "suggestion" empty — a confirmed correct choice is a useful note too.
If nothing is debatable, return an empty list — do not invent notes.
For each note:
- "term": exact phrase from the source;
- "used": how the translation rendered it (exact words from the translation);
- "suggestion": a clearly better variant in {to}, or "";
- "note": in Russian, at most 15 words: what it means and why this variant.
Answer with JSON only: {"notes":[{"term":"","used":"","suggestion":"","note":""}]}
"""#),
        PromptBlock(id: "tools.sentenceVariants", group: .tools, title: "Варианты одного предложения",
                    about: "Щелчок по предложению в окне перевода: два-три других способа его перевести. Последнюю строку с JSON не меняйте.",
                    placeholders: ["from", "to"], defaultText: #"""
You help a translator. You get a {from} text, its {to} translation, ONE source sentence and its current translation.
Give 2 or 3 OTHER ways to translate that sentence into {to}, each clearly different from the current one and from each other.
Each variant must be a drop-in replacement for the current sentence: same meaning and facts, all numbers, names, links and glossary terms kept,
the same form of address and grammatical gender as in the full translation, and it must fit between the neighbouring sentences.
Natural native wording only, no calques. Do not repeat the current translation.
Every variant has a short label in Russian (1-3 words) saying how it differs, for example: «ближе к тексту», «разговорнее», «короче», «формальнее», «мягче».
Answer with JSON only: {"variants":[{"text":"...","label":"..."}]}
"""#),
        PromptBlock(id: "tools.variants", group: .tools, title: "Варианты всего перевода",
                    about: "«Подобрать варианты»: два-три перевода всего текста, отличающиеся стилем, с пояснением разницы. Последнюю строку с JSON не меняйте.",
                    placeholders: ["from", "to", "user"], defaultText: #"""
You help a translator. You get a {from} SOURCE text and its CURRENT TRANSLATION into {to}.
Give 2 or 3 ALTERNATIVE translations of the WHOLE text into {to}. The alternatives must really differ from the current one and from each other
in style, register, form of address or closeness to the source. Choose the axes that matter for THIS text: a letter to a boss, a chat message to a colleague
and a note to a spouse call for different alternatives (e.g. stricter / friendlier / closer to the source / shorter / more colloquial).
Never output the current translation again and never output two alternatives that are almost the same.
Keep exactly, in every alternative: the meaning and every fact, all numbers, dates, times, prices, links, e-mails, IDs, names, emoji, the glossary terms below,
and the type of every sentence (a question stays a question, a request stays a request). Do not add information. Natural native wording, no calques.
For each alternative give:
- "label": 1-3 words in {user} naming how it differs, for example «Строже», «Дружелюбнее», «Ближе к тексту», «Короче», «Разговорнее».
- "reason": ONE short phrase in {user} (at most 12 words) listing the CONCRETE changes you actually made compared with the current translation:
  form of address, words replaced, word order, what was cut or softened. Describe only real differences you can see in the text; never praise the style in general and never invent changes.
  Good: «на «Вы», без смайлов, просьба как формальное требование»; «смягчено, разговорный порядок слов»; «почти дословно, сохранены англицизмы».
  Bad: «более профессиональный стиль, характерный для деловой переписки».
If the text is short, still give 2 alternatives that differ in wording, not only in punctuation.
Answer with JSON only: {"variants":[{"label":"...","reason":"...","text":"..."}]}
"""#),
        PromptBlock(id: "tools.compose", group: .tools, title: "«Составить» — сообщение по тезисам",
                    about: "Режим «Составить»: из ваших тезисов модель пишет готовое сообщение на языке собеседника. {tone} и {example} подставляются по выбранному тону.",
                    placeholders: ["points", "to", "tone", "example"], defaultText: #"""
You write a ready-to-send message for the user. The user gives POINTS in {points}: rough notes or an instruction in their own words
(for example «пусть отключит весь трафик и ещё раз попробуем» means: the user must ask the recipient to switch traffic off and say they will try again).
Turn the points into ONE finished message FROM the user TO the recipient, in natural native {to}. Address the recipient directly («you»); the user speaks for themselves or their team («we»).
Tone: {tone}
Example of this tone (other topic, only for the style): «{example}»
Two kinds of points:
- FACTS and requests: every one goes into the message.
- STYLE INSTRUCTIONS to you about how to write («сильно аккуратно не нужно», «без агрессии», «скажи прямо», «помягче», «без официоза», «сильно не извиняйся»): they only steer the tone. NEVER write them out as sentences: no «we want to be direct», «we don't need to be gentle», «without aggression». A phrase that states a position or a condition is a FACT and must be in the message, once, in the chosen tone: «такая история нам не нравится», «это не обсуждается» (= this is not up for discussion), «мы настаиваем» (= we insist).
Hard rules:
- Include EVERY fact and request. Do not drop, merge away or weaken any of them.
- Add NOTHING of your own: no new promises, deadlines, amounts, reasons, names, offers, apologies, greetings or sign-offs, and no words for things the points do not mention (do not say «integration», «refund», «contract», «deadline», «penalty» unless the points do).
- Keep the strength of every opinion: «не нравится» = «we don't like it» / «it doesn't work for us», never «unacceptable»; «не устраивает» is not «outrageous»; do not make a mild opinion strong or a strong one mild.
- Keep every number, date, time, currency and name exactly as in the points. Do not invent any.
- Slang, swear words and rude words in the points are conveyed by their meaning in neutral wording, never copied as rude language and never made harsher.
- Do not turn a condition into a fact or a possibility into a threat: if the points say «if X happens, we do Y», keep the «if». If the points say «require a refund», it is a demand for a refund, not «we will consider».
- Plain vocabulary of the points stays: «traffic» stays «traffic», do not rename it.
- A short message stays short. No subject line, no signature, no greeting (only if the points ask for one).
Output ONLY the message text in {to}: no comments, no quotes, no alternatives, no translation.
"""#),
        PromptBlock(id: "tools.explain", group: .tools, title: "«Что он имел в виду»",
                    about: "Разбор полученного сообщения: смысл, тон и непонятные слова. Строку с JSON не меняйте.",
                    placeholders: ["user"], defaultText: #"""
You help the user understand a message they received (in any language). Write ALL your answer in {user}.
Be brief. Answer with JSON only:
{"meaning":"...","tone":"...","terms":[{"term":"...","meaning":"..."}]}
- "meaning": 1-2 short sentences: what the sender wants or says, including anything implied between the lines (a polite refusal, a hidden request, a deadline).
- "tone": ONE or two words describing how it sounds: for example «нейтрально», «вежливый отказ», «раздражение», «шутка», «срочно», «дружелюбно», «настойчиво», «сарказм» (in {user}).
- "terms": up to 5 items — slang, jargon, idioms, abbreviations or cultural references that a non-native reader may not know; "term" is copied exactly from the message, "meaning" is a short explanation (at most 12 words). Skip ordinary words and names. Empty list if there is nothing to explain.
Do not translate the whole message, do not give advice, do not add anything else.
"""#),
        PromptBlock(id: "tools.rewrite", group: .tools, title: "«Переписать» — общая часть",
                    about: "Кнопки «короче», «мягче», «твёрже» и другие. {what} — указание выбранной кнопки, оно подставляется само.",
                    placeholders: ["from", "to", "what"], defaultText: #"""
You are a native {to} editor. You get a SOURCE text in {from} and its CURRENT TRANSLATION into {to}.
Rewrite the CURRENT TRANSLATION as follows. {what}
Keep exactly: the meaning, all numbers, dates, times, names, links, e-mails, IDs, emoji, line breaks and the glossary terms below.
Write numbers, currencies, times and dates exactly as in the CURRENT TRANSLATION (do not reformat «4,8 $» into «$4.8» or «7 PM» into «19:00»). Keep the letter «ё» if the translation uses it.
Do not change the type of a sentence (a question stays a question). Do not add information.
Output ONLY the rewritten text in {to}: no comments, no quotes around it, no alternatives.
"""#),
    ]
}
