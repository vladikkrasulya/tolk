// Plugs autocomplete features into the controller from the current config.
// Called by AppDelegate.applyAutocomplete() on launch and on every settings change.
// Each section is owned by one feature (one session edits only its own section).
import AppKit
import TolkCore

@MainActor
enum AutocompleteFeatures {
    static func configure(_ c: AutocompleteController, config: TolkConfig) {
        var providers: [InstantSuggestionProvider] = []
        // Typo fixes and emoji work on their own; everything that feeds the model needs autocomplete itself on.
        c.modelEnabled = config.autocomplete

        // Frequency → confidence thresholds (measured in autocomplete-eval.md, round 3):
        // rare 0.6 ≈ 67 % right / 17 % shown; normal 0.4 ≈ 45 % / 30 %; often 0.25 ≈ 35 % / 45 %.
        switch config.autocompleteFrequency {
        case "rare":  AutocompletePrompt.firstTokenProb = 0.6;  AutocompletePrompt.minTokenProb = 0.35
        case "often": AutocompletePrompt.firstTokenProb = 0.25; AutocompletePrompt.minTokenProb = 0.25
        default:      AutocompletePrompt.firstTokenProb = 0.4;  AutocompletePrompt.minTokenProb = 0.3
        }

        // MARK: [autocorrect] — typo fixes (section owned by the autocorrect feature)
        if config.autocorrect {
            providers.insert(Autocorrect(rulesPath: config.effectiveRulesPath), at: 0)
        }

        // MARK: [prefs] — emoji, instructions, glossary, tone, clipboard, length (section owned by the prefs feature)
        // [prefs] SETS the base `c.promptExtras` (configure runs on every settings change, so it must not wrap the old one);
        // later sections wrap it: `let base = c.promptExtras; c.promptExtras = { f in var e = base?(f) ?? PromptExtras(); …; return e }`.
        if config.autocompleteEmoji { providers.append(EmojiSuggestions()) }
        let prefs = PromptPrefs(config: config)
        if config.autocomplete && config.autocompleteClipboard { ClipboardWatcher.shared.start() }
        AutocompletePrompt.maxTokens = PromptPrefs.maxTokens(forWords: PromptPrefs.maxWords(for: config.autocompleteLength))
        c.promptExtras = { field in prefs.extras(for: field) }

        // MARK: [style] — learning from accepted/sent text (section owned by the style feature)
        let style = StyleMemory.shared
        style.observeDeleteAll()
        style.generation += 1                       // closures from earlier configure calls become pass-through
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOLK_STYLE_SELFTEST"] != nil {
            let fails = StyleMemory.selfTest()
            FileHandle.standardError.write(Data("style selftest: \(fails.isEmpty ? "PASSED" : "FAILED")\n\(fails.joined(separator: "\n"))\n".utf8))
            exit(fails.isEmpty ? 0 : 1)
        }
        #endif
        if config.autocomplete && config.autocompleteLearnStyle {
            style.load()
            let gen = style.generation
            let prevExtras = c.promptExtras
            c.promptExtras = { field in
                var e = prevExtras?(field) ?? PromptExtras()
                if StyleMemory.shared.generation == gen { e.examples += StyleMemory.shared.examples(for: field) }
                return e
            }
            let prevAccepted = c.onAccepted
            c.onAccepted = { [weak c] a in
                prevAccepted?(a)
                guard StyleMemory.shared.generation == gen else { return }
                StyleMemory.shared.handle(a, disabledApps: c?.disabledApps ?? [])
            }
        }

        c.instantProviders = providers
        _ = config
    }
}
