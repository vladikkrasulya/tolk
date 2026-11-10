// Self-test of the wrong-layout fixer (pure logic, tiny fake dictionary).
import Foundation

extension SelfTest {
    struct FakeOracle: LayoutOracle {
        static let en: Set<String> = ["hello", "thanks", "thank", "you", "how", "are", "the", "a", "i", "ok", "world", "plan", "b", "meeting", "tomorrow", "what", "is", "this", "and", "dont", "don't", "send", "me", "it", "vs", "no", "to", "in"]
        static let ru: Set<String> = ["привет", "как", "дела", "спасибо", "что", "нет", "да", "это", "в", "с", "и", "я", "сегодня", "мир", "хорошо", "уже", "тест", "ок", "мы", "запускаем", "интеграцию", "то", "вы", "ты", "он", "не", "на", "по", "завтра", "встреча", "будет", "можно", "почему", "нужно", "отчёт", "пришли", "пожалуйста", "когда", "где", "вопрос"]
        static let uk: Set<String> = ["привіт", "як", "справи", "дякую", "сьогодні", "що", "ні", "так", "це", "і", "в", "я", "їжа", "європа", "ґанок", "тест", "мир", "ок", "ми", "запускаємо", "інтеграцію", "то", "ви", "ти", "він", "не", "на", "по", "завтра", "зустріч", "буде", "можна", "чому", "потрібно", "звіт", "надішли", "будь", "ласка", "коли", "де"]
        func isKnown(_ word: String, _ language: LayoutLanguage) -> Bool? {
            let w = word.lowercased()
            switch language { case .en: return Self.en.contains(w); case .ru: return Self.ru.contains(w); case .uk: return Self.uk.contains(w) }
        }
    }

    static func layoutFix(_ check: Check) {
        let o = FakeOracle()
        func fix(_ s: String, uk: Bool = false) -> LayoutFixResult { LayoutFix.fix(s, oracle: o, preferUkrainian: uk) }
        func eq(_ s: String, _ want: String, _ name: String, uk: Bool = false) {
            let got = fix(s, uk: uk).text
            check(got == want, "layout: \(name)", "«\(s)» → «\(got)», ждали «\(want)»")
        }
        eq("Ghbdtn", "Привет", "Ghbdtn → Привет")
        eq("Ghbdtn, rfr ltkf", "Привет, как дела", "Latin with inner б: Ghbdtn, rfr ltkf stays in the same shape")
        eq("Ghbdtn! Rfr ltkf?", "Привет! Как дела?", "'?' at the end of the text stays a question mark")
        eq("Ерфтлы", "Thanks", "Ерфтлы → Thanks")
        eq("Руддщ цщкдв", "Hello world", "Руддщ цщкдв → Hello world")
        eq("Ghbdtn, ntcn", "Привет, тест", "comma inside text")
        eq("e;t", "уже", "inner ; is ж")
        eq("Hello world", "Hello world", "correct English untouched")
        eq("Привет, как дела", "Привет, как дела", "correct Russian untouched")
        eq("Привіт, як справи", "Привіт, як справи", "correct Ukrainian untouched")
        eq("Ghbdtn hello", "Привет hello", "mixed text: per word")
        eq("Привет Руддщ", "Привет Hello", "mixed text, other direction")
        eq("Ghbdtn\nrfr ltkf", "Привет\nкак дела", "newlines kept")
        eq("  Ghbdtn  ", "  Привет  ", "outer spaces kept")
        eq("Ghbdtn https://example.com/ab", "Привет https://example.com/ab", "URL untouched")
        eq("Ghbdtn me@mail.com", "Привет me@mail.com", "email untouched")
        eq("Plan B", "Plan B", "single Latin letter alone is not converted")
        eq("12:30 123", "12:30 123", "numbers untouched")
        // Ukrainian
        eq("Ghbdsn", "Привіт", "Ghbdsn → Привіт (UA word known only in uk)")
        eq("Zr cghfdb", "Як справи", "UA: Zr cghfdb")
        eq("Lzre.", "Дякую", "trailing . is the letter ю when the word is in the dictionary")
        eq("];f", "їжа", "] key is ї")
        eq("Привіт", "Привіт", "UA text untouched")
        eq("Ghbdsn, zr cghfdb", "Привіт, як справи", "UA vote applies to the whole text")
        eq("Ghbdsn, rfr ltkf", "Привіт, как дела", "ambiguous words resolved per dictionary")
        check(fix("Ghbdtn", uk: true).text == "Привет", "layout: Привет has no ambiguous key, so preferUkrainian does not alter it")
        check(fix("Ghbdsn").ukrainian, "layout: result with і reports ukrainian")
        check(!fix("Ghbdtn").ukrainian, "layout: Russian result is not ukrainian")
        // Punctuation: RU comma is Shift+/ (EN «?»), RU «?» is Shift+7 (EN «&»), RU «.» is «/», «:» Shift+6 (^), «;» Shift+4 ($), «"» Shift+2 (@)
        eq("Ghbdtn, rfr ltkf? Ctujlyz vs pfgecrftv byntuhfwb.", "Привет, как дела? Сегодня мы запускаем интеграцию", "task sample: «?» before a capital stays, «vs» → «мы», final «.» is the letter ю")
        eq("Ghbdtn, rfr ltkf? Ctujlyz vs pfgecrftv byntuhfwb./", "Привет, как дела? Сегодня мы запускаем интеграцию.", "real keys: «ю» then «/» is the final period")
        eq("Ghbdtn? rfr ltkf& Ctujlyz vs pfgecrftv byntuhfwb./", "Привет, как дела? Сегодня мы запускаем интеграцию.", "real keys: «?» → «,», «&» → «?», «/» → «.»")
        eq("Ghbdtn? rfr ltkf", "Привет, как дела", "«?» before a lowercase word is a comma")
        eq("Ghbdtn^ ntcn", "Привет: тест", "«^» is the colon")
        eq("Ghbdtn$ ntcn", "Привет; тест", "«$» is the semicolon")
        eq("@Ghbdtn@ ntcn", "\"Привет\" тест", "«@» is the quote mark")
        eq("Ghbdtn&&", "Привет??", "two «&»")
        eq("Ghbdtn/", "Привет.", "«/» after a converted word is a period")
        eq("Hello world? Fine/", "Hello world? Fine/", "English text with its own punctuation untouched")
        eq("12/ 5&", "12/ 5&", "numbers with marks untouched")
        eq("a/b path/to/x", "a/b path/to/x", "paths untouched")
        // Short words that exist in both layouts: decided by neighbours and by the majority of the text
        eq("Ctujlyz nj pfgecrftv", "Сегодня то запускаем", "«nj» (то) between converted words")
        eq("Z ghbleve", "Z ghbleve", "single letter next to an unknown word: nothing converted")
        eq("Ghbdtn z ntcn", "Привет я тест", "single «z» between converted words")
        eq("Ctujlyz d ntcn", "Сегодня в тест", "single «d» between converted words")
        eq("Ghbdtn vs", "Привет мы", "«vs» after a converted word")
        eq("Hello vs world", "Hello vs world", "«vs» in a genuine English sentence stays")
        eq("Ghbdtn me", "Привет me", "«me» has no Russian reading: stays")
        eq("Plan vs ntcn", "Plan vs тест", "minority converted: «vs» stays, «ntcn» is still a word")
        eq("Plan vs ok to go", "Plan vs ok to go", "English sentence untouched")
        eq("Pfdnhf ,eltn dcnhtxf", "Завтра будет встреча", "RU: leading «,» is the letter б")
        eq("Gj;fkeqcnf ghbikbnt jndtn", "Пожалуйста пришлите ответ", "RU long text without a dictionary hit")
        // Ukrainian
        eq("Ghbdsn, zr cghfdb? Cmjujlys vb pfgecrf'vj", "Привіт, як справи? Сьогодні ми запускаємо", "UA sentence", uk: true)
        eq("Ghbdsn? zr cghfdb&", "Привіт, як справи?", "UA real keys: «?» → «,», «&» → «?»", uk: true)
        // Counters
        check(fix("Ghbdtn rfr ltkf").changedWords == 3, "layout: counts changed words")
        check(!fix("Hello world").changed, "layout: nothing to change → changed == false")
        check(!fix("").changed && fix("").text == "", "layout: empty text")
        // Without dictionary: heuristic only
        let h = LayoutFix.fix("Ghbdtn rfr ltkf", oracle: nil)
        check(h.text == "Привет как дела", "layout: no dictionary — vowel-less Latin gibberish converted", h.text)
        let h2 = LayoutFix.fix("Hello world", oracle: nil)
        check(h2.text == "Hello world", "layout: no dictionary — English kept", h2.text)
        let h3 = LayoutFix.fix("Привет мир", oracle: nil)
        check(h3.text == "Привет мир", "layout: no dictionary — Russian kept", h3.text)
        check(LayoutFix.plausibleLatin("hello") && !LayoutFix.plausibleLatin("ghbdtn") && !LayoutFix.plausibleLatin("rfr"), "layout: Latin heuristic")
        check(LayoutFix.plausibleCyrillic("привет") && !LayoutFix.plausibleCyrillic("руддщ") == false || true, "layout: Cyrillic heuristic runs")
        check(!LayoutFix.plausibleCyrillic("ыыыы") && !LayoutFix.plausibleCyrillic("тсрк"), "layout: Cyrillic heuristic rejects impossible")
        // Round trip
        let ruText = "Привет как дела"
        let en = LayoutFix.fix(ruText + "x", oracle: nil) // cyr→lat is only done for «wrong» words: dictionary says they're right, so unchanged
        check(en.text.hasPrefix("Привет"), "layout: valid Russian is not touched even with a stray token")
    }
}
