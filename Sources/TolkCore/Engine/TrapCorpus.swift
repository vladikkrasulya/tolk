// «Basic traps» corpus: short realistic business/adtech messages, each with simple checkable rules for the
// translation (regexes that MUST match, regexes that MUST NOT). The checker is a pure function (self-tested);
// running the corpus needs the model and lives in `tolk-cli --trap-corpus FILE`.
import Foundation

public struct TrapItem: Sendable, Equatable {
    public let id: String
    public let trap: String          // polite / roles / modal / position / negation / jargon / numbers / en2ru
    public let from: Language
    public let to: Language
    public let tone: Tone
    public let text: String
    public let must: [String]
    public let forbid: [String]
}

public enum TrapCorpus {
    /// JSON: [{id, trap, dir: "ru-en"|"en-ru", tone, text, must: [regex], forbid: [regex]}]
    public static func load(path: String) -> [TrapItem]? {
        guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap { d in
            guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
            let dir = (d["dir"] as? String ?? "ru-en").split(separator: "-").map(String.init)
            guard dir.count == 2, let f = Language(rawValue: dir[0]), let t = Language(rawValue: dir[1]) else { return nil }
            return TrapItem(id: id, trap: d["trap"] as? String ?? "other", from: f, to: t,
                            tone: (d["tone"] as? String).flatMap { Tone(rawValue: $0) } ?? .auto, text: text,
                            must: d["must"] as? [String] ?? [], forbid: d["forbid"] as? [String] ?? [])
        }
    }

    /// Failures of `translation` against the item's rules (empty = passed). Includes TranslationCheck and calque warnings.
    public static func failures(_ item: TrapItem, translation: String) -> [String] {
        var out: [String] = []
        func match(_ p: String) -> Bool {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: translation, range: NSRange(location: 0, length: (translation as NSString).length)) != nil
        }
        for p in item.must where !match(p) { out.append("нет: \(p)") }
        for p in item.forbid where match(p) { out.append("нельзя: \(p)") }
        out += TranslationCheck.warnings(source: item.text, translation: translation, from: item.from, to: item.to)
        out += CalqueDetector.warnings(in: translation, language: item.to)
        return out
    }

    /// Per-trap tally: (passed, total).
    public static func summary(_ results: [(item: TrapItem, passed: Bool)]) -> [(trap: String, passed: Int, total: Int)] {
        var order: [String] = []
        var tally: [String: (Int, Int)] = [:]
        for r in results {
            if tally[r.item.trap] == nil { order.append(r.item.trap) }
            let o = tally[r.item.trap] ?? (0, 0)
            tally[r.item.trap] = (o.0 + (r.passed ? 1 : 0), o.1 + 1)
        }
        return order.map { ($0, tally[$0]!.0, tally[$0]!.1) }
    }
}

/// Second, independent signal for the corpus: the translation is translated back to the source language by the model
/// and the key elements of the original are compared with the back-translation (no regexes of the corpus involved):
/// numbers/ids, negation, condition, request, obligation, stop/disable, money/refund, who (we / you).
/// A mismatch is a «disputed» text for a human, not a verdict (the back-translation can be wrong too).
public enum BackCheck {
    private static func has(_ p: String, _ s: String) -> Bool { s.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
    private static func count(_ p: String, _ s: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return 0 }
        return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static let b = "(?<![\\p{L}])"
    private static let e = "(?![\\p{L}])"
    private static func w(_ s: String) -> String { b + "(?:" + s + ")" + e }
    private static func stem(_ s: String) -> String { b + "(?:" + s + ")" }   // prefix match

    /// (name, pattern in ru/uk, pattern in en)
    private static let classes: [(String, String, String)] = [
        ("отрицание", w("не|нет|ни|ничего|никогда|нельзя|ні|ніколи|без") + "|не можна", w("not|no|never|without|cannot|none|nothing") + "|n't\\b"),
        ("условие", w("если|иначе|раз|якщо|інакше|коли") + "|в случае|у разі|пока не|поки не|до тех пор|до тих пір", w("if|otherwise|unless|until|once|provided") + "|in case"),
        ("просьба", stem("прош|попрош|просим|пожалуйста|будьте добры|подскаж|підкаж|будь ласка|просимо") + "|не могли б|чи не могли", "please|could you|can you|would you|kindly|ask you|request"),
        ("требование", stem("нужн|надо|необходим|обязан|должн|требу|обязательн|вынужд|потрібн|треба|мусите|повинн|вимага|обов'язков|зобов"), stem("must|need|have to|required|require|should|insist|demand|obliged")),
        ("остановка/отключение", stem("стоп|останов|отключ|прекра|заблок|выключ|приостан|пауз|зупин|вимкн|відключ|припин|закрыва|закрива"), stem("stop|pause|disabl|turn off|switch off|halt|block|cut|shut|suspend|terminat|clos|remov")),
        ("деньги/возврат", stem("рефанд|возврат|вернуть|верн[её]м|компенс|штраф|оплат|платит|платим|заплат|поверн|виплат|выплат"), stem("refund|return|pay|compensat|penalt|invoice|charg|reimburs")),
        ("мы", w("мы|нам|нас|наш\\p{L}*|ми|нам|нас|наш\\p{L}*"), w("we|us|our|ours|we'll|we're|we've")),
        ("вы/ты", w("вы|вам|вас|ваш\\p{L}*|ты|тебе|тебя|твой|твоя|твои|ви|вам|вас|ваш\\p{L}*|ти|тобі|тебе"), w("you|your|yours|you'll|you're|you've")),
    ]

    /// Digit-only forms of every number / id / time in the text (separators dropped: 0,35 and 0.35 are the same).
    static func numbers(_ s: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"\d(?:[\d\s.,:]*\d)?"#) else { return [] }
        var out = Set<String>()
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            let d = s[r].filter(\.isNumber)
            if d.count >= 1 { out.insert(String(d)) }
        }
        return out
    }

    /// Differences between the original and its back-translation (both in the source language `lang`). Empty = consistent.
    public static func compare(source: String, back: String, lang: Language) -> [String] {
        var out: [String] = []
        let missing = numbers(source).subtracting(numbers(back))
        if !missing.isEmpty { out.append("обратный перевод: нет чисел \(missing.sorted().joined(separator: ", "))") }
        let extra = numbers(back).subtracting(numbers(source))
        if !extra.isEmpty { out.append("обратный перевод: лишние числа \(extra.sorted().joined(separator: ", "))") }
        let en = lang == .english
        for (name, ruuk, enp) in classes {
            let p = en ? enp : ruuk
            let s = count(p, source), t = count(p, back)
            if name == "отрицание" {
                if s != t && (s == 0 || t == 0 || abs(s - t) >= 2) { out.append("обратный перевод: отрицание \(s)→\(t)") }
            } else if (s > 0) != (t > 0) {
                out.append("обратный перевод: \(name) \(s > 0 ? "потеряно" : "добавлено")")
            }
        }
        return out
    }
}
