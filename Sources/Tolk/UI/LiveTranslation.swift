// Decision part of live typing, free of AppKit so it can be checked from the command line:
// one `IncrementalSession` per text field + how a request is built for each kind of plan.
import Foundation
import TolkCore

@MainActor
final class LiveTranslation {
    /// What to do after a debounced change of the text.
    struct Step {
        let plan: IncrementalPlan?
        /// `.unchanged`: show `kept`, send nothing. `.full`: whole text. `.partial`: `kept` + streamed tail.
        let kind: IncrementalPlan.Kind
        /// Already translated beginning (empty for `.full`).
        let kept: String
        /// nil for `.unchanged`.
        let request: TranslationRequest?
        /// One line for tolk.log.
        let logLine: String
    }

    private let session = IncrementalSession()
    private var langs: (source: Language, target: Language)?
    /// A partial translation was committed since the last full one — the shown text is stitched from pieces.
    private(set) var hadPartials = false

    func reset() { session.reset(); langs = nil; hadPartials = false }

    /// The final whole-text pass produced `translation` for `text`: it becomes the new base of the session.
    func adoptFinal(text: String, key: String, translation: String) {
        session.reset()
        let plan = session.plan(for: text, key: key)
        session.commit(plan, translation: translation)
        hadPartials = false
    }

    /// Remember the languages the engine actually used (from the last `.started` of this session).
    func started(source: Language, target: Language) { langs = (source, target) }

    /// Fingerprint of everything besides the text that changes the result.
    static func key(source: Language?, target: Language?, tone: Tone, mode: TextMode,
                    config: TolkConfig, replyTo: String? = nil) -> String {
        [source?.rawValue ?? "-", target?.rawValue ?? "-", tone.rawValue, "\(mode)",
         config.activeProfileID, config.effectiveModel, RulesFingerprint.of(path: config.effectiveRulesPath), replyTo ?? ""].joined(separator: "\u{1F}")
    }

    func prepare(text: String, source: Language?, target: Language?, tone: Tone, mode: TextMode = .translate,
                 replyTo: String? = nil, key: String) -> Step {
        let whole = TranslationRequest(text: text, source: source, target: target, tone: tone, mode: mode, replyTo: replyTo)
        guard mode != .polish else {
            reset()
            return Step(plan: nil, kind: .full, kept: "", request: whole, logLine: "incremental: full (polish)")
        }
        let plan = session.plan(for: text, key: key)
        switch plan.kind {
        case .unchanged:
            return Step(plan: plan, kind: .unchanged, kept: plan.keptTranslation, request: nil,
                        logLine: "incremental: unchanged kept=\(SentenceSplitter.split(plan.keptSource).count)")
        case .full:
            return Step(plan: plan, kind: .full, kept: "", request: whole,
                        logLine: "incremental: full sent=\(SentenceSplitter.split(text).count) chars=\(text.count)")
        case .partial:
            let req = TranslationRequest(text: plan.changedSource, source: langs?.source ?? source,
                                         target: langs?.target ?? target, tone: tone, mode: mode,
                                         replyTo: replyTo, context: plan.context)
            return Step(plan: plan, kind: .partial, kept: plan.keptTranslation, request: req,
                        logLine: "incremental: partial kept=\(SentenceSplitter.split(plan.keptSource).count) "
                            + "sent=\(SentenceSplitter.split(plan.changedSource).count) chars=\(plan.changedSource.count)")
        }
    }

    /// Request finished: `tail` is the translation of what was sent (the whole text for `.full`).
    func commit(_ step: Step, tail: String) {
        guard let plan = step.plan else { return }
        session.commit(plan, translation: tail)
        if plan.kind == .partial { hadPartials = true } else if plan.kind == .full { hadPartials = false }
    }
}
