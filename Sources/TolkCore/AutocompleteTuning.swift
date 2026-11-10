// Pure rules of the «prompt on every key» autocomplete (measurements: autocomplete-eval, ac-cotypist round):
// pause before a request, confidence thresholds by frequency, fields where suggestions are not shown,
// Esc pause, what gets remembered, and the user's word list for the model's logit bias. Checked by `tolk-cli --self-test`.
import Foundation

public enum AutocompleteTuning {
    // MARK: Pause before a request

    /// Pause (ms) between the last key and the request. A request is also sent for every key, a stale one is cancelled.
    /// Measured on llama-server (E2B, -np 1): with keys every 70 ms a pause below ~60 ms piles requests up (answer 1.6–2.4 s
    /// after the last key), 60 ms keeps the queue empty; at ≥150 ms between keys 20 ms is as good as 0.
    public static func debounceMs(sinceLastKey gap: TimeInterval?) -> Int {
        guard let gap else { return 20 }
        return gap < 0.11 ? 60 : 20
    }

    // MARK: Confidence thresholds

    /// (first token, every later token). Curve on 54 cases with a request on every key
    /// (shown / right): 0.6 → 82/52, 0.5 → 87/52, 0.4 → 90/51, 0.3 → 97/51, 0.2 → 101/51:
    /// below 0.5 only wrong suggestions are added.
    public static func thresholds(frequency: String) -> (first: Double, next: Double) {
        switch frequency {
        case "rare": return (0.6, 0.35)
        case "often": return (0.3, 0.3)
        default: return (0.5, 0.35)
        }
    }

    // MARK: Small fields

    /// Why a field gets no suggestions (nil = fine): one-line search and address fields, table cells, tiny fields.
    /// `width`/`height` in points (nil = unknown → not judged by size); `labels` = title, description, placeholder, identifier.
    public static func fieldSkipReason(role: String, subrole: String, parentRole: String = "",
                                       width: Double?, height: Double?, labels: [String] = []) -> String? {
        if role == "AXSearchField" || subrole == "AXSearchField" { return "search-field" }
        if ["AXCell", "AXRow", "AXTable", "AXOutline", "AXColumn"].contains(parentRole) || role == "AXCell" { return "table-cell" }
        for l in labels {
            let s = l.lowercased()
            for k in ["address and search", "address bar", "адресная строка", "адрес и поиск", "omnibox", "web_browser_address",
                      "search", "поиск", "найти", "e-mail", "email", "эл. почта", "логин", "login", "iban", "card number", "номер карты"]
            where s.contains(k) { return "label:" + k }
        }
        if let h = height, h < 28 { return "short" }
        if let w = width, w < 150 { return "narrow" }
        return nil
    }

    // MARK: Esc pause

    /// Keys after which a pause set by Esc ends: the user probably moved to another field.
    public static func endsPause(keyCode: Int64, command: Bool, control: Bool) -> Bool {
        command || control || keyCode == 48 || keyCode == 36 || keyCode == 76
    }

    // MARK: Memory

    /// Is a sent message written to style memory? By default only when a suggestion was accepted while writing it.
    public static func recordSent(recordAll: Bool, hadAccepted: Bool) -> Bool { recordAll || hadAccepted }

    // MARK: Words of the user (logit bias)

    public static func biasStrength(_ mode: String) -> Double {
        switch mode { case "off": 0; case "strong": 2.5; default: 1.0 }
    }

    /// Words of 4+ letters with their counts (lowercased).
    public static func wordCounts(in texts: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for t in texts {
            var cur = ""
            func flush() { if cur.count >= 4 { out[cur, default: 0] += 1 }; cur = "" }
            for ch in t.lowercased() { if ch.isLetter { cur.append(ch) } else { flush() } }
            flush()
        }
        return out
    }

    /// The words worth a bias: the most frequent `limit`, ties by alphabet.
    public static func topWords(_ counts: [String: Int], limit: Int = 300) -> [(word: String, count: Int)] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { ($0.key, $0.value) }
    }

    /// Bias for the first token of a word seen `count` times: grows with log(count), full at 3+ uses, at most `strength`.
    public static func biasWeight(count: Int, strength: Double) -> Double {
        guard count > 0, strength > 0 else { return 0 }
        return strength * min(1.0, log(1.0 + Double(count)) / log(4.0))
    }
}

extension SelfTest {
    static func autocompleteTuning(_ check: Check) {
        typealias T = AutocompleteTuning
        // Pause
        check(T.debounceMs(sinceLastKey: 0.07) == 60, "tune: fast typing → 60 ms")
        check(T.debounceMs(sinceLastKey: 0.25) == 20 && T.debounceMs(sinceLastKey: nil) == 20, "tune: normal typing → 20 ms")
        // Thresholds
        let r = T.thresholds(frequency: "rare"), n = T.thresholds(frequency: "normal"), o = T.thresholds(frequency: "often")
        check(r.first > n.first && n.first > o.first, "tune: rare > normal > often")
        check(T.thresholds(frequency: "weird") == n || (T.thresholds(frequency: "weird").first == n.first), "tune: unknown frequency = normal")
        // Small fields
        check(T.fieldSkipReason(role: "AXTextField", subrole: "AXSearchField", width: 400, height: 40) == "search-field", "tune: search subrole")
        check(T.fieldSkipReason(role: "AXSearchField", subrole: "", width: 400, height: 40) == "search-field", "tune: search role")
        check(T.fieldSkipReason(role: "AXTextField", subrole: "", parentRole: "AXCell", width: 400, height: 40) == "table-cell", "tune: table cell")
        check(T.fieldSkipReason(role: "AXTextField", subrole: "", width: 600, height: 30, labels: ["Address and search bar"]) != nil, "tune: browser address bar")
        check(T.fieldSkipReason(role: "AXTextField", subrole: "", width: 300, height: 22) == "short", "tune: one-line field")
        check(T.fieldSkipReason(role: "AXTextField", subrole: "", width: 90, height: 60) == "narrow", "tune: narrow field")
        check(T.fieldSkipReason(role: "AXTextField", subrole: "", width: 300, height: 40, labels: ["Email"]) != nil, "tune: email field")
        check(T.fieldSkipReason(role: "AXTextArea", subrole: "", width: 640, height: 48, labels: ["Message"]) == nil, "tune: chat composer is fine")
        check(T.fieldSkipReason(role: "AXTextArea", subrole: "", width: nil, height: nil) == nil, "tune: unknown size is not judged")
        // Esc pause
        check(T.endsPause(keyCode: 48, command: false, control: false) && T.endsPause(keyCode: 36, command: false, control: false), "tune: Tab/Return end the pause")
        check(T.endsPause(keyCode: 37, command: true, control: false) && !T.endsPause(keyCode: 0, command: false, control: false), "tune: ⌘ ends the pause, a letter does not")
        // Memory
        check(!T.recordSent(recordAll: false, hadAccepted: false) && T.recordSent(recordAll: false, hadAccepted: true) && T.recordSent(recordAll: true, hadAccepted: false), "tune: record only messages with an accepted suggestion by default")
        // Words
        let wc = T.wordCounts(in: ["Привет, лог лог логи логи логи", "Логи ok"])
        check(wc["логи"] == 4 && wc["привет"] == 1 && wc["лог"] == nil && wc["ok"] == nil, "tune: word counts", "\(wc)")
        let top = T.topWords(["бета": 2, "альфа": 2, "гамма": 5], limit: 2).map(\.word)
        check(top == ["гамма", "альфа"], "tune: top words by count then alphabet", "\(top)")
        check(T.biasWeight(count: 3, strength: 1) == 1.0 && T.biasWeight(count: 1, strength: 1) < 1.0 && T.biasWeight(count: 9, strength: 2.5) == 2.5, "tune: bias grows then caps")
        check(T.biasWeight(count: 5, strength: T.biasStrength("off")) == 0 && T.biasStrength("strong") > T.biasStrength("medium"), "tune: bias off / medium / strong")
    }
}
