// Token healing for the autocomplete prompt. Pure logic, no AppKit. Self-test: SelfTest+ACHeal.swift.
//
// A half-typed word ("не получи") ends the prompt in the middle of a token, which the model has never seen there: it
// answered "а" / "т" instead of the rest of the word (0 of 15 mid-word endings correct on the raw prompt). Healing:
//   1. the unfinished word is cut off the prompt (`Plan.head`);
//   2. llama-server's `grammar` forces the reply to start with those letters (`Plan.literal`, `grammar(forLiteral:)`);
//   3. the forced letters are removed from the reply again (`strip`), what remains is the continuation.
// Measured on 54 fragments (E2B): endings right 0 → 9 of 15 (autocomplete-eval, «healing» round).
import Foundation

public enum AutocompleteHealing {
    public struct Plan: Equatable, Sendable {
        /// Text for the prompt: no unfinished word, no trailing spaces.
        public let head: String
        /// What the reply must begin with: the cut-off word, with the leading space that was stripped from `head`.
        /// nil when the caret is not right after a letter (nothing to heal).
        public let literal: String?
    }

    public static func plan(textBefore: String) -> Plan {
        func stripSpaces(_ s: String) -> String {
            var t = s
            while let l = t.last, l == " " || l == "\t" || l == "\u{00A0}" { t.removeLast() }
            return t
        }
        guard let last = textBefore.last, last.isLetter else { return Plan(head: stripSpaces(textBefore), literal: nil) }
        var partial = ""
        var rest = Substring(textBefore)
        while let c = rest.last, c.isLetter { partial.insert(c, at: partial.startIndex); rest = rest.dropLast() }
        let head = stripSpaces(String(rest))
        let hadSpace = head.count != rest.count
        return Plan(head: head, literal: (hadSpace ? " " : "") + partial)
    }

    /// GBNF: the reply starts with `literal`, then anything up to the end of the line.
    public static func grammar(forLiteral literal: String) -> String {
        let esc = literal.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return "root ::= \"\(esc)\" [^\\n]*"
    }

    public struct Token: Equatable, Sendable {
        public var text: String
        public var prob: Double
        /// Alternatives the model considered at this position (llama-server `top_logprobs`, probabilities).
        public var top: [(text: String, prob: Double)]
        public init(text: String, prob: Double, top: [(text: String, prob: Double)] = []) { self.text = text; self.prob = prob; self.top = top }
        public static func == (a: Token, b: Token) -> Bool { a.text == b.text && a.prob == b.prob }
    }

    /// Removes the forced `literal` from the generated stream. llama-server reports the model's own probabilities, which
    /// for forced letters are low ("what the model wanted instead"), so the token that crosses the end of the literal gets
    /// its probability renormalised over the alternatives that are consistent with the literal.
    public static func strip(literal: String, content: String, tokens: [Token]) -> (content: String, tokens: [Token]) {
        guard !literal.isEmpty else { return (content, tokens) }
        let lit = Array(literal.unicodeScalars)
        var consumed = 0
        var out: [Token] = []
        for t in tokens {
            if consumed >= lit.count { out.append(Token(text: t.text, prob: t.prob)); continue }
            let tt = Array(t.text.unicodeScalars)
            let rem = Array(lit[consumed...])
            if tt.count <= rem.count { consumed += tt.count; continue }
            // This token crosses the end of the literal: the part after it is the first free text.
            func has(_ s: [Unicode.Scalar], prefix p: [Unicode.Scalar]) -> Bool { s.count >= p.count && Array(s[..<p.count]) == p }
            let consistent = t.top.filter { c in
                let cs = Array(c.text.unicodeScalars)
                return has(cs, prefix: rem) || (!cs.isEmpty && has(rem, prefix: cs))
            }
            let z = consistent.reduce(0) { $0 + $1.prob }
            // The chosen token may be missing from the reported alternatives (the model's raw favourites were all
            // inconsistent with the typed letters, e.g. tokens with a leading space): it is still the best consistent
            // one, so it is weighed against the consistent alternatives that were reported. It used to keep its raw
            // probability (~0), and correct endings («дост» → «упа») were thrown away as "unsure".
            let inTop = consistent.contains { $0.text == t.text }
            let total = inTop ? z : z + t.prob
            var p = total > 0 ? min(1, t.prob / total) : t.prob
            // Nothing to compare with (no consistent alternative was reported): the model was far off its own track,
            // so this is a guess, never a "sure" one («каче» → «р.» came out with probability 1.0).
            if !inTop, z == 0 { p = min(p, 0.5) }
            var s = String.UnicodeScalarView(); s.append(contentsOf: tt[rem.count...])
            out.append(Token(text: String(s), prob: p))
            consumed = lit.count
        }
        let rest = content.hasPrefix(literal) ? String(content.dropFirst(literal.count)) : content
        return (rest, out)
    }
}
