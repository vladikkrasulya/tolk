// Plugs autocomplete features into the controller from the current config.
// Called by AppDelegate.applyAutocomplete() on launch and on every settings change.
// Each section is owned by one feature (one session edits only its own section).
import AppKit
import IOKit.ps
import TolkCore

@MainActor
enum AutocompleteFeatures {
    static func configure(_ c: AutocompleteController, config: TolkConfig) {
        var providers: [InstantSuggestionProvider] = []
        // Typo fixes and emoji work on their own; everything that feeds the model needs autocomplete itself on.
        c.modelEnabled = config.autocomplete

        // On battery (switches in settings, all off by default): rarer / shorter suggestions, no screen snapshots.
        let power = PowerProfile.effective(
            frequency: config.autocompleteFrequency, length: config.autocompleteLength, screenContext: config.autocompleteScreenContext,
            onBattery: PowerMonitor.shared.onBattery, batteryRare: config.autocompleteBatteryRare,
            batteryNoScreen: config.autocompleteBatteryNoScreen, batteryShort: config.autocompleteBatteryShort)
        ScreenContext.ocrAllowed = power.screenContext
        var config = config
        config.autocompleteFrequency = power.frequency
        config.autocompleteLength = power.length

        // Frequency → confidence thresholds (curve on 54 cases with a request on every key, see AutocompleteTuning.thresholds):
        // rare 0.6 ≈ 63 % right; normal 0.5 ≈ 60 %; often 0.3 ≈ 53 %. Below 0.5 only wrong suggestions are added.
        let th = AutocompleteTuning.thresholds(frequency: config.autocompleteFrequency)
        AutocompletePrompt.firstTokenProb = th.first
        AutocompletePrompt.minTokenProb = th.next
        AutocompletePrompt.patient = AutocompleteTuning.patientThresholds(frequency: config.autocompleteFrequency)

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
        c.onAccepted = nil // same for the accepted-text hook: otherwise every settings save wrapped the previous closure (unbounded chain)

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
                if StyleMemory.shared.generation == gen { e.examples += StyleMemory.shared.examples(for: field); e.recent = StyleMemory.shared.recent(for: field) }
                return e
            }
            let prevAccepted = c.onAccepted
            c.onAccepted = { [weak c] a in
                prevAccepted?(a)
                guard StyleMemory.shared.generation == gen else { return }
                StyleMemory.shared.handle(a, disabledApps: c?.offApps ?? AutocompleteSafety.builtinOffApps, recordAll: config.autocompleteRecordAll)
            }
            c.wordBiasMode = config.autocompleteWordPreference
            c.wordBiasTexts = { StyleMemory.shared.allTexts() }
        }

        if !(config.autocomplete && config.autocompleteLearnStyle) { c.wordBiasMode = "off" }
        c.instantProviders = providers
        _ = config
    }
}

/// Power source: `onBattery` is true while the Mac runs on battery. `onChange` fires when it switches.
@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()
    private(set) var onBattery = PowerMonitor.read()
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.refresh() } }
        }, ctx)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    private func refresh() {
        let now = Self.read()
        guard now != onBattery else { return }
        onBattery = now
        Diagnostics.log("power: \(now ? "battery" : "AC")")
        onChange?()
    }

    nonisolated private static func read() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
