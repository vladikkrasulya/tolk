// Dev tool for the engine.
// swift run tolk-cli [--from CODE] [--to CODE]  (CODE: en ru uk de fr es it pt pl cs nl ro bg tr kk ka he ar zh ja ko hi id vi) [--tone auto|chat|formal]
//                    [--provider auto|ollama|google] [--show-rules] [--warm] [--rules PATH] [--refine]
//                    [--context-source TEXT --context-translation TEXT] [--self-test] "text"
// Translation goes to stdout, service info to stderr. Text can also come from stdin.
import Foundation
import TolkCore

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never { err(s); exit(2) }

var source: Language?, target: Language?, tone = Tone.auto
var providerName = "auto", showRules = false, wantNotes = false
var mode = TextMode.translate
var modelOverride: String?
var replyTo: String?
var showPrompt = false
var warmOnly = false
var rulesPath: String?
var wantRefine = false, selfTest = false
var contextSource: String?, contextTranslation: String?
var checkOnly: String?
var cancelAfter: Double?, addTerm: String?
var words: [String] = []
// Dev: `tolk-cli --ac-spawn CMD ARGS…` launches CMD the way Tolk launches llama-server (dies with this process), then waits.
if CommandLine.arguments.dropFirst().first == "--ac-spawn" {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ServerLifecycle.wrapperArguments(command: Array(CommandLine.arguments.dropFirst(2)))
    try? p.run()
    print("wrapper pid \(p.processIdentifier)")
    fflush(stdout)
    while true { sleep(1000) }
}
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    func value() -> String {
        guard let v = args.next() else { fail("missing value for \(a)") }
        return v
    }
    switch a {
    case "--from":
        guard let l = Language(rawValue: value()) else { fail("--from: " + Language.allCases.map(\.rawValue).joined(separator: "|")) }
        source = l
    case "--to":
        guard let l = Language(rawValue: value()) else { fail("--to: " + Language.allCases.map(\.rawValue).joined(separator: "|")) }
        target = l
    case "--tone":
        guard let t = Tone(rawValue: value()) else { fail("--tone: auto|chat|formal") }
        tone = t
    case "--provider": providerName = value()
    case "--show-rules": showRules = true
    case "--show-prompt": showPrompt = true
    case "--reply-to": replyTo = value()                     // partner's message the text answers
    case "--model": modelOverride = value()                  // e.g. gemma-translate
    case "--polish": mode = .polish                          // rewrite in the same language
    case "--notes": wantNotes = true                         // also print footnotes on debatable terms
    case "--cancel-after": cancelAfter = Double(value())   // dev: test consumer cancellation
    case "--rules": rulesPath = value()                      // use this rules file instead of the active profile's
    case "--refine": wantRefine = true                       // after translating, run the editor pass and print both
    case "--context-source": contextSource = value()         // already translated beginning (source side)
    case "--context-translation": contextTranslation = value()
    case "--check": checkOnly = value()                      // run only the automatic check: text = source, value = translation
    case "--self-test": selfTest = true                      // engine checks without model or network
    case "--warm": warmOnly = true                          // load the model on vkbox and report the time
    case "--add-term": addTerm = value()                    // "source => translation"
    case "-h", "--help":
        err("usage: tolk-cli [--from L] [--to L] [--tone auto|chat|formal] [--provider auto|ollama|google] [--show-rules] [--cancel-after SEC] text\n       tolk-cli --add-term 'source => translation'")
        exit(0)
    default: words.append(a)
    }
}
if selfTest {
    let (total, failures) = SelfTest.run()
    for f in failures { err("FAIL: " + f) }
    err("self-test: \(total - failures.count)/\(total) passed")
    exit(failures.isEmpty ? 0 : 1)
}
if let addTerm {
    let parts = addTerm.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2 else { fail("--add-term 'source => translation'") }
    do { try DefaultTranslationEngine(config: TolkConfig.load()).addGlossaryTerm(source: parts[0], translation: parts[1]) }
    catch { fail("add-term: \(error)") }
    err("added: - \(parts[0]) → \(parts[1])")
    exit(0)
}
if warmOnly {
    let o = OllamaProvider(config: TolkConfig.load(), rules: RulesStore(path: TolkConfig.load().effectiveRulesPath))
    let t0 = Date()
    let r = DispatchSemaphore(value: 0)
    Task {
        let loaded = await o.isModelLoaded()
        err("в памяти до прогрева: \(loaded.map { $0 ? "да" : "нет" } ?? "?")")
        let st = await o.ensureReady(timeout: 300)
        err("прогрев: \(st) за \(String(format: "%.1f", Date().timeIntervalSince(t0))) с")
        r.signal()
    }
    r.wait(); exit(0)
}
var text = words.joined(separator: " ")
if text.isEmpty, isatty(0) == 0 {
    text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}
if text.isEmpty { fail("no text; see --help") }

var config = TolkConfig.load()
if let modelOverride { config.model = modelOverride }
if let checkOnly {
    let s = source ?? LanguageDetector.detect(text)
    let t = target ?? LanguageDetector.defaultTarget(for: s, config: config)
    for w in TranslationCheck.warnings(source: text, translation: checkOnly, from: s, to: t) { print("⚠️ \(w)") }
    exit(0)
}
let engine: DefaultTranslationEngine
if let rulesPath {
    // Same engine, but the rules come from this file (e.g. to measure another profile).
    let store = RulesStore(path: rulesPath)
    let fallback: TranslationProvider? = config.fallback == .google ? GoogleProvider() : nil
    engine = DefaultTranslationEngine(config: config, rules: store, primary: OllamaProvider(config: config, rules: store), fallback: fallback)
} else {
    engine = DefaultTranslationEngine(config: config)
}
var context: TranslationContext?
if let contextSource, let contextTranslation { context = TranslationContext(source: contextSource, translation: contextTranslation) }
else if contextSource != nil || contextTranslation != nil { fail("--context-source and --context-translation go together") }
let request = TranslationRequest(text: text, source: source, target: target, tone: tone, mode: mode, replyTo: replyTo, context: context)
if showPrompt { print(engine.debugSystemPrompt(for: request)); exit(0) }
if showRules {
    let selector = [text, replyTo, contextSource].compactMap { $0 }.joined(separator: "\n")
    err("--- rules block ---\n" + engine.rules.promptBlock(for: selector) + "\n-------------------")
}

/// Runs one provider directly (no fallback), wrapped into engine-like events.
func direct(_ p: TranslationProvider) -> AsyncThrowingStream<TranslationEvent, Error> {
    let r = LanguageDetector.resolve(request, config: config)
    return AsyncThrowingStream { c in
        let t = Task {
            do {
                c.yield(.started(provider: p.name, source: r.source, target: r.target))
                for try await d in p.translate(r) { c.yield(.delta(d)) }
                c.yield(.finished); c.finish()
            } catch { c.finish(throwing: error) }
        }
        c.onTermination = { _ in t.cancel() }
    }
}

let stream: AsyncThrowingStream<TranslationEvent, Error>
switch providerName {
case "auto": stream = engine.translate(request)
case "ollama", "qwen": stream = direct(engine.primary)
case "google": stream = direct(GoogleProvider())
default: fail("--provider: auto|ollama|google")
}

let start = Date()
var translated = "", resolvedPair: (Language, Language)?
func ms() -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }
let done = DispatchSemaphore(value: 0)
var status: Int32 = 0
let consumer = Task {
    var first = true
    do {
        for try await e in stream {
            switch e {
            case let .started(p, s, t): err("[\(p) \(s.label)->\(t.label)] \(ms())"); first = true; resolvedPair = (s, t); translated = ""
            case let .delta(d):
                if first { err("[first chunk \(ms())]"); first = false }
                translated += d
                print(d, terminator: ""); fflush(stdout)
            case let .fellBack(from, reason): err("[fallback from \(from): \(reason)] \(ms())")
            case let .stats(st):
                let speed = st.tokensPerSecond.map { String(format: "%.0f ток/с%@", $0, st.tokensExact ? "" : "≈") } ?? "—"
                for w in st.warnings { err("⚠️ \(w)") }
                err("[\(st.routeTitle) · первое слово \(st.firstChunk.map { String(format: "%.2fs", $0) } ?? "—") · \(speed) · \(String(format: "%.2fs", st.total))\(st.fallbackReason.map { " · запасной: " + $0 } ?? "")]")
            case .finished: print(); fflush(stdout); err("[done \(ms())]")
            }
        }
        if wantRefine, let (s, t) = resolvedPair {
            err("[refine \(ms())]")
            var refined = ""
            for try await d in engine.refine(source: text, translation: translated, from: s, to: t, tone: tone) {
                refined += d
            }
            print("— после редактора —\n" + refined)
            if refined.trimmingCharacters(in: .whitespacesAndNewlines) == translated.trimmingCharacters(in: .whitespacesAndNewlines) {
                err("(без изменений)")
            }
            let ws = TranslationCheck.warnings(source: text, translation: refined, from: s, to: t)
            for w in ws { err("⚠️ после редактора: \(w)") }
            err("[refine done \(ms())]")
        }
        if wantNotes, let (s, t) = resolvedPair {
            let notes = await engine.notes(source: text, translation: translated, from: s, to: t)
            err("[notes \(ms())]")
            for n in notes { print("  • \(n.term) → «\(n.used)»" + (n.suggestion.map { " (лучше: «\($0)»)" } ?? "") + " — \(n.note)") }
            if notes.isEmpty { print("  (нет спорных терминов)") }
        }
    } catch {
        err("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        status = 1
    }
    done.signal()
}
if let cancelAfter {
    DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) { err("\n[cancel \(ms())]"); consumer.cancel() }
}
done.wait()
exit(status)
