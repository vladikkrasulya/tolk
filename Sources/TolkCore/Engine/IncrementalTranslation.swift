// Live typing without retranslating everything: the text is compared with the previous one sentence by
// sentence (on this Mac, no model call). Sentences before the first changed one keep their translation;
// the rest goes to the model as a separate request with the kept part as context.
import Foundation

public enum SentenceSplitter {
    /// Splits into sentences; each piece keeps its trailing whitespace, so `split(t).joined() == t`.
    public static func split(_ text: String) -> [String] {
        var out: [String] = []
        var covered = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            // Never lose characters between the ranges the system reports.
            let piece = String(text[covered..<enclosing.upperBound])
            covered = enclosing.upperBound
            let blank = piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let last = out.last, blank || last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out[out.count - 1] = last + piece
            } else {
                out.append(piece)
            }
        }
        if covered < text.endIndex {
            let rest = String(text[covered...])
            if out.isEmpty { out.append(rest) } else { out[out.count - 1] += rest }
        }
        return mergeAbbreviations(out)
    }

    /// Titles and the like that end with a full stop but do not end a sentence («Dr. Smith», «вул. Шевченка»).
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "mt", "no", "fig", "approx", "dept",
        "г", "гг", "ул", "пр", "тов", "им", "проф", "вул", "просп", "буд", "кв", "пров", "бул", "ім",
    ]

    private static func mergeAbbreviations(_ pieces: [String]) -> [String] {
        var out: [String] = []
        var carry = ""
        for (i, piece) in pieces.enumerated() {
            let cur = carry + piece
            carry = ""
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasNewline = piece.contains(where: \.isNewline)
            if i < pieces.count - 1, !hasNewline, trimmed.hasSuffix("."),
               let word = trimmed.dropLast().split(whereSeparator: { !$0.isLetter }).last,
               word.count <= 5, abbreviations.contains(word.lowercased()),
               // «…в 5 г. Он» is a sentence end; a title is followed by a capitalised name on the same line.
               trimmed.dropLast().last?.isLetter == true,
               trimmed.dropLast().dropLast(word.count).last.map({ !$0.isLetter }) ?? true {
                carry = cur
                continue
            }
            out.append(cur)
        }
        if !carry.isEmpty { out.append(carry) }
        return out
    }

    /// What must differ for a sentence to count as changed: letters, digits, inner punctuation, `?`/`!`.
    /// Case, spacing and a trailing full stop do not count.
    static func normalized(_ sentence: String) -> String {
        var s = sentence.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let last = s.last, last == "." || last == "…" { s.removeLast() }
        return s
    }

    static func trailingWhitespace(_ sentence: String) -> String {
        String(sentence.reversed().prefix(while: \.isWhitespace).reversed())
    }
}

public struct IncrementalPlan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Nothing meaningful changed: show `keptTranslation`, send nothing.
        case unchanged
        /// Translate the whole text in one ordinary request.
        case full
        /// Send only `changedSource` with `context`; show `keptTranslation` + the new translation.
        case partial
    }
    public let kind: Kind
    /// Unchanged beginning of the text, exactly as typed now.
    public let keptSource: String
    /// Its translation, ending with the separator that goes before the new part.
    public let keptTranslation: String
    /// The part to translate (the whole text for `.full`).
    public let changedSource: String

    let keptUnits: Int
    let keptSentences: Int
    let sentences: [String]
    let key: String
    let generation: Int

    public var context: TranslationContext? {
        kind == .partial ? TranslationContext(source: keptSource, translation: keptTranslation) : nil
    }
}

/// One typing session of one text field. Not thread-safe: use from the main actor.
public final class IncrementalSession {
    private struct Unit { var sources: [String]; var translation: String }
    private var units: [Unit] = []
    private var key = ""
    private var generation = 0

    public init() {}

    /// Forget everything: the next plan is `.full` (⌘↩, cleared field, error).
    public func reset() { units = []; generation += 1 }

    /// `key` is a fingerprint of everything else that affects the translation (languages, tone, profile,
    /// model, reply context). A different key means a full retranslation.
    public func plan(for text: String, key: String) -> IncrementalPlan {
        generation += 1
        let sentences = SentenceSplitter.split(text)
        func full() -> IncrementalPlan {
            IncrementalPlan(kind: .full, keptSource: "", keptTranslation: "", changedSource: text,
                            keptUnits: 0, keptSentences: 0, sentences: sentences, key: key, generation: generation)
        }
        guard key == self.key, !units.isEmpty else { return full() }

        var keptUnits = 0, idx = 0
        var keptTranslation = ""
        outer: for unit in units {
            guard idx + unit.sources.count <= sentences.count else { break }
            for (j, s) in unit.sources.enumerated()
            where SentenceSplitter.normalized(s) != SentenceSplitter.normalized(sentences[idx + j]) { break outer }
            idx += unit.sources.count
            keptUnits += 1
            var sep = SentenceSplitter.trailingWhitespace(sentences[idx - 1])
            if sep.isEmpty, idx < sentences.count { sep = " " }
            keptTranslation += unit.translation + sep
        }
        guard keptUnits > 0 else { return full() }

        if idx == sentences.count {
            // Only the tail was deleted (or nothing meaningful changed).
            units = Array(units.prefix(keptUnits))
            return IncrementalPlan(kind: .unchanged, keptSource: text,
                                   keptTranslation: keptTranslation.trimmingCharacters(in: .whitespacesAndNewlines),
                                   changedSource: "", keptUnits: keptUnits, keptSentences: idx,
                                   sentences: sentences, key: key, generation: generation)
        }
        return IncrementalPlan(kind: .partial, keptSource: sentences[..<idx].joined(), keptTranslation: keptTranslation,
                               changedSource: sentences[idx...].joined(), keptUnits: keptUnits, keptSentences: idx,
                               sentences: sentences, key: key, generation: generation)
    }

    /// Remember the finished translation of `plan.changedSource`. Ignored for a plan that is no longer the latest.
    public func commit(_ plan: IncrementalPlan, translation: String) {
        guard plan.generation == generation, plan.kind != .unchanged else { return }
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = Array(plan.sentences[plan.keptSentences...])
        guard !t.isEmpty, !changed.isEmpty else { return }
        key = plan.key
        units = Array(units.prefix(plan.keptUnits))
        let parts = SentenceSplitter.split(t)
        if parts.count == changed.count {
            for (s, p) in zip(changed, parts) {
                units.append(Unit(sources: [s], translation: p.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        } else {
            // Sentences did not map one to one: keep the block whole, it is retranslated as a block.
            units.append(Unit(sources: changed, translation: t))
        }
    }
}
