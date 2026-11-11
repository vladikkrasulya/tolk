// Dev: fingerprints of every assembled prompt (`tolk-cli --prompt-digest`), to prove that moving a prompt into
// `PromptCatalog` did not change a single character of what the model gets.
import Foundation
import CryptoKit

public enum PromptDigest {
    public static func lines() -> [String] {
        func h(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() + " \(s.count)" }
        var out: [String] = []
        let pairs: [(Language, Language)] = [(.english, .russian), (.russian, .english), (.english, .ukrainian), (.german, .french)]
        for (a, b) in pairs {
            out.append("notes \(a.rawValue)\(b.rawValue) " + h(NotesPrompt.system(from: a, to: b, rules: "R")))
            for t in Tone.allCases {
                out.append("variants \(a.rawValue)\(b.rawValue) \(t.rawValue) " + h(ExtrasPrompt.variants(from: a, to: b, tone: t, rules: "R")))
                out.append("tvariants \(a.rawValue)\(b.rawValue) \(t.rawValue) " + h(ExtrasPrompt.translationVariants(from: a, to: b, userLanguage: .russian, tone: t, rules: "")))
                out.append("refine \(a.rawValue)\(b.rawValue) \(t.rawValue) " + h(RefinePrompt.system(from: a, to: b, tone: t, rules: "R")))
            }
            for m in RewriteMode.allCases { out.append("rewrite \(a.rawValue)\(b.rawValue) \(m) " + h(ExtrasPrompt.rewrite(mode: m, from: a, to: b, rules: "R"))) }
            for t in ComposeTone.allCases {
                out.append("compose \(a.rawValue)\(b.rawValue) \(t) " + h(ExtrasPrompt.compose(tone: t, pointsLanguage: a, to: b, hasPartner: true, rules: "R")))
                out.append("compose- \(a.rawValue)\(b.rawValue) \(t) " + h(ExtrasPrompt.compose(tone: t, pointsLanguage: a, to: b, hasPartner: false, rules: "")))
                out.append("tone \(b.rawValue) \(t) " + h(ExtrasPrompt.toneTransfer(tone: t, language: b, rules: "R")))
            }
            out.append("explain \(a.rawValue) " + h(ExtrasPrompt.explain(userLanguage: a, rules: "R")))
        }
        return out
    }
}
