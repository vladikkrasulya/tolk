// Dev: `TOLK_AC_EVAL=cases.txt [TOLK_AC_EVAL_CTX=context.txt] [TOLK_AC_PORT=8178] .build/debug/Tolk`
// Runs every line of the file (the text before the caret; a trailing "_" stands for a trailing space) through the same
// prompt, completion client, confidence cut and `clean` as live typing, against an already running llama-server, and
// prints what the model said and why a suggestion was or was not shown. No window, no event tap, no log.
import AppKit
import TolkCore

enum ACEval {
    @MainActor
    static func run(path: String) async {
        let env = ProcessInfo.processInfo.environment
        let port = env["TOLK_AC_PORT"] ?? "8178"
        let client = CompletionClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        await client.probeFormat()
        let cfg = TolkConfig.load()
        let th = AutocompleteTuning.thresholds(frequency: env["TOLK_AC_FREQ"] ?? cfg.autocompleteFrequency)
        AutocompletePrompt.firstTokenProb = th.first
        AutocompletePrompt.minTokenProb = th.next
        let ctx = env["TOLK_AC_EVAL_CTX"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let app = env["TOLK_AC_APP"] ?? "Telegram"
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        // TOLK_AC_FULL=1: everything live typing adds — instructions, clipboard, style examples, recent messages, word bias.
        let full = env["TOLK_AC_FULL"] != nil
        let bundle = env["TOLK_AC_BUNDLE"] ?? "com.anthropic.claudefordesktop"
        let prefs = PromptPrefs(config: cfg)
        if full {
            AutocompletePrompt.maxTokens = PromptPrefs.maxTokens(forWords: PromptPrefs.maxWords(for: cfg.autocompleteLength))
            if cfg.autocompleteLearnStyle, env["TOLK_AC_NOSTYLE"] == nil { StyleMemory.shared.load() }
            for _ in 0..<100 where StyleMemory.shared.allTexts().isEmpty && env["TOLK_AC_NOSTYLE"] == nil { try? await Task.sleep(for: .milliseconds(50)) }
            if cfg.autocompleteLearnStyle, env["TOLK_AC_NOBIAS"] == nil {
                let wb = WordBias()
                wb.refreshIfNeeded(baseURL: client.baseURL, model: cfg.autocompleteModel, mode: env["TOLK_AC_BIAS"] ?? cfg.autocompleteWordPreference,
                                   texts: { StyleMemory.shared.allTexts() })
                for _ in 0..<400 where AutocompletePrompt.logitBias.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                withExtendedLifetime(wb) {}
            }
            print("full: bias tokens=\(AutocompletePrompt.logitBias.count) style texts=\(StyleMemory.shared.allTexts().count) maxTokens=\(AutocompletePrompt.maxTokens)")
        }
        var shown = 0
        print("thresholds first=\(th.first) next=\(th.next) chat=\(AutocompletePrompt.chatTemplateAvailable) cases=\(lines.count)")
        for line in lines {
            let before = line.hasSuffix("_") ? String(line.dropLast()) + " " : line
            var extras = PromptExtras()
            if full {
                let field = FocusedField(pid: 0, bundleID: bundle, textBefore: before, restOfLine: "", caret: .zero, caretInfo: "eval")
                extras = prefs.extras(for: field)
                if env["TOLK_AC_NOSTYLE"] == nil { extras.examples += StyleMemory.shared.examples(for: field); extras.recent = StyleMemory.shared.recent(for: field) }
            }
            let prompt = AutocompletePrompt.prompt(textBefore: before, appName: app, context: ctx, extras: extras)
            guard let r = try? await client.complete(prompt: prompt, maxTokens: AutocompletePrompt.maxTokens) else { print("ERR  | \(line)"); continue }
            let sure = (r.firstProb ?? 0) >= AutocompletePrompt.sureProb
            var final = AutocompletePrompt.clean(r.text, textBefore: before, maxWords: extras.maxWords, sure: sure)
            var patient = false
            if final == nil, let bars = AutocompleteTuning.patientThresholds(frequency: env["TOLK_AC_FREQ"] ?? cfg.autocompleteFrequency), !r.tokens.isEmpty {
                let kept = AutocompletePrompt.confidentPrefix(r.tokens, textBefore: before, first: bars.first, next: bars.next)
                final = AutocompletePrompt.clean(kept, textBefore: before, maxWords: extras.maxWords, sure: sure)
                patient = final != nil
            }
            let rawClean = AutocompletePrompt.clean(r.raw, textBefore: before, maxWords: extras.maxWords)
            if final != nil { shown += 1 }
            let p1 = r.firstProb.map { String(format: "%.2f", $0) } ?? "-"
            let why = patient ? "PATIENT" : final != nil ? "SHOWN" : r.text.isEmpty ? (rawClean == nil ? "cut+clean" : "cut") : "clean"
            print("\(why.padding(toLength: 9, withPad: " ", startingAt: 0)) p1=\(p1) | …\(before.suffix(34)) ⟶ raw «\(r.raw)» kept «\(r.text)» final «\(final ?? "")»")
        }
        print("shown \(shown)/\(lines.count)")
    }
}
