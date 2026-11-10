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
