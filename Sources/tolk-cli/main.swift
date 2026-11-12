// Dev tool for the engine.
// swift run tolk-cli [--from CODE] [--to CODE]  (CODE: en ru uk de fr es it pt pl cs nl ro bg tr kk ka he ar zh ja ko hi id vi) [--tone auto|chat|formal]
//                    [--provider auto|ollama|google] [--show-rules] [--warm] [--rules PATH] [--refine] [--twice]
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
var pairsTranslation: String?, variantsCurrent: String?, rewriteMode: RewriteMode?, rewriteTranslation: String?, wantExplain = false, variantsAll: String?, composeTone: ComposeTone?
var maskShow: String?, maskEval: String?, maskFormats = "brackets,section,square", noMask = false, maskFormat: String?
var prevTurns: [String] = [], calquesText: String?, tzText: String?, tzLocal: String?, tzNow: String?, showFingerprint = false
var words: [String] = []
var typeSimPartner: String?
var typeSimNoPartner = false
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
var twice = false
var trapCorpusPath: String?, trapOut: String?, trapOnly: String?, trapBack = false
// `tolk-cli --ac-stats [JSON_PATH [LOG_PATH]]` prints the autocomplete statistics (JSON, else the log). Read-only.
if CommandLine.arguments.dropFirst().first == "--ac-stats" {
    let a = Array(CommandLine.arguments.dropFirst(2))
    let data = ACStats.loadReadOnly(path: a.first ?? ACStats.defaultPath, logPath: a.dropFirst().first ?? ACStats.defaultLogPath)
    print(ACStats.report(data))
    exit(0)
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
    case "--trap-corpus": trapCorpusPath = value()           // JSON corpus of basic traps: translate each, check the rules, print a summary (model!)
    case "--trap-out": trapOut = value()                     // with --trap-corpus: also write the results as JSON
    case "--trap-back": trapBack = true                       // with --trap-corpus: also translate every result back and compare the key elements
    case "--trap-only": trapOnly = value()                   // with --trap-corpus: only ids/traps from this comma list
    case "--twice": twice = true                             // translate the text twice in one process: shows the result cache
    case "--prompt-digest": print(PromptDigest.lines().joined(separator: "\n")); exit(0)  // fingerprints of the assembled prompts
    case "--log-guide": print(LogGuide.markdown()); exit(0)  // the guide to tolk.log as Markdown (docs/journal.md)
    case "--self-test": selfTest = true                      // engine checks without model or network
    case "--warm": warmOnly = true                          // load the model on the home server and report the time
    case "--pairs": pairsTranslation = value()               // text = source; value = translation: sentence pairs (no model)
    case "--variants": variantsCurrent = value()             // text = source sentence; value = its translation; full texts via --context-*
    case "--variants-all": variantsAll = value()             // text = source; value = its translation: 2-3 whole-translation variants (--reply-to works)
    case "--compose":                                        // --compose TONE, text = points, --to LANG / --reply-to MESSAGE
        guard let t = ComposeTone(rawValue: value()) else { fail("--compose: " + ComposeTone.allCases.map(\.rawValue).joined(separator: "|")) }
        composeTone = t
    case "--rewrite":                                        // --rewrite MODE TRANSLATION, text = source
        guard let m = RewriteMode(rawValue: value()) else { fail("--rewrite: " + RewriteMode.allCases.map(\.rawValue).joined(separator: "|") + " TRANSLATION") }
        rewriteMode = m; rewriteTranslation = value()
    case "--explain": wantExplain = true                     // text = incoming message: what did they mean
    case "--mask": maskShow = value()                        // show the masked text and the entities (no model)
    case "--mask-eval": maskEval = value()                   // JSON file [{id,text,tone?}]: baseline vs masked, per format (model!)
    case "--mask-formats": maskFormats = value()             // comma list of: brackets,section,square,tag,word
    case "--mask-format": maskFormat = value()               // format used by the engine for this run
    case "--mask-on": noMask = true                          // protect links/macros with placeholders (off by default)
    case "--prev": prevTurns.append(value())                 // thread context line "source => translation" (repeatable)
    case "--type-sim": typeSimPartner = value()              // «Перевод при наборе»: value = partner's message on screen, text = my draft
    case "--type-sim-empty": typeSimNoPartner = true         // same, with an empty screen (partner language unknown → secondaryLanguage)
    case "--calques": calquesText = value()                  // list calques in this text (use --to for the language)
    case "--tz": tzText = value()                            // time zones in this text -> local time
    case "--tz-local": tzLocal = value()                     // zone id for --tz (default: this Mac)
    case "--tz-now": tzNow = value()                         // ISO8601 "now" for --tz
    case "--fingerprint": showFingerprint = true             // print the rules fingerprint of the active profile
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
if let calquesText {
    let l = target ?? LanguageDetector.detect(calquesText)
    let hits = CalqueDetector.detect(in: calquesText, language: l)
    for h in hits { print("калька [\(h.id)] «\(h.found)» → «\(h.suggestion)»") }
    if hits.isEmpty { print("(калек нет)") }
    exit(0)
}
if let tzText {
    var now = Date()
    if let tzNow { guard let d = ISO8601DateFormatter().date(from: tzNow) else { fail("--tz-now: ISO8601") }; now = d }
    let z = tzLocal.flatMap { TimeZone(identifier: $0) } ?? .current
    err("местное время: \(z.identifier)")
    let rs = TimezoneConverter.convert(in: tzText, now: now, localZone: z)
    for r in rs { print(r.display) }
    if rs.isEmpty { print("(времён с поясом нет)") }
    exit(0)
}
if showFingerprint {
    let c = TolkConfig.load()
    print("\(c.activeProfileID) \(c.effectiveRulesPath) \(RulesFingerprint.of(path: c.effectiveRulesPath))")
    exit(0)
}
if let maskShow {
    let f = maskFormat.flatMap { EntityMasker.Format(rawValue: $0) }
    let m = EntityMasker.mask(maskShow, format: f)
    print(m.text)
    for e in m.entities { print("  \(e.token)  [\(e.kind.rawValue)]  \(e.original)") }
    print(m.restore(m.text) == maskShow ? "restore: ok" : "restore: MISMATCH")
    exit(0)
}
if noMask { EntityMasking.enabled = true }
if let maskFormat { guard let f = EntityMasker.Format(rawValue: maskFormat) else { fail("--mask-format: brackets|section|square|tag|word") }; EntityMasker.defaultFormat = f }
EngineLog.sink = { err("[log] " + $0) }
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
if text.isEmpty, trapCorpusPath == nil, isatty(0) == 0 {
    text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}
if text.isEmpty, trapCorpusPath == nil { fail("no text; see --help") }

var config = TolkConfig.load()
if let modelOverride { config.model = modelOverride }
if let checkOnly {
    let s = source ?? LanguageDetector.detect(text)
    let t = target ?? LanguageDetector.defaultTarget(for: s, config: config)
    for w in TranslationCheck.warnings(source: text, translation: checkOnly, from: s, to: t) { print("⚠️ \(w)") }
    exit(0)
}
if let pairsTranslation {
    for p in SentencePairing.pairs(source: text, translation: pairsTranslation) {
        let a = p.sourceRange(in: text).map { String(text[$0]) } ?? "?"
        let b = p.translationRange(in: pairsTranslation).map { String(pairsTranslation[$0]) } ?? "?"
        print("\(p.isConfident ? "✓" : "?") [\(p.source.location),\(p.source.length)] «\(a)»  ⇄  [\(p.translation.location),\(p.translation.length)] «\(b)»")
    }
    exit(0)
}
if typeSimPartner != nil || typeSimNoPartner {
    // What the line under the field would show (no UI, no keys): partner on screen + my draft → silent / translation.
    var c = config
    c.fallback = .none  // the conversation never goes to Google
    let eng = DefaultTranslationEngine(config: c)
    let screen = typeSimPartner ?? ""
    let partner = TypeTranslate.partner(screen: screen, draft: text)
    let known = partner == nil && TypeTranslate.screenIsAllSameLanguage(screen: screen, draft: text)
    let verdict = TypeTranslate.decide(text: text, partner: partner, screenKnown: known, primary: c.primaryLanguage, secondary: c.secondaryLanguage,
                                       explicitlyOn: true, auto: false)
    guard case let .translate(src, dst) = verdict else {
        if case let .silent(why) = verdict { print("(строка не появится: \(why.rawValue))") }
        exit(0)
    }
    let req = TypeTranslate.request(text: text, source: src, target: dst, partner: partner, tone: tone, threadContext: nil)
    timed("type-sim") {
        let t0 = Date()
        var out = ""
        for try await e in eng.translate(req) {
            switch e {
            case let .delta(d): out += d
            case .started: out = ""
            default: break
            }
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[\(TypeTranslate.label(for: dst))] \(out.trimmingCharacters(in: .whitespacesAndNewlines))   — \(TypeTranslate.hint)")
        err("partner=\(partner.map { "\($0.language.rawValue): \($0.message.prefix(60))" } ?? "нет") ms=\(ms)")
    }
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
func timed(_ label: String, _ body: @escaping @Sendable () async throws -> Void) -> Never {
    let t0 = Date(), sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code: Int32 = 0
    Task {
        do { try await body() } catch { err("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"); code = 1 }
        err("[\(label) \(String(format: "%.2fs", Date().timeIntervalSince(t0)))]")
        sem.signal()
    }
    sem.wait(); exit(code)
}
let lsrc = source ?? LanguageDetector.detect(text)
let ldst = target ?? LanguageDetector.defaultTarget(for: lsrc, config: config)
if let maskEval {
    guard let data = FileManager.default.contents(atPath: (maskEval as NSString).expandingTildeInPath),
          let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fail("--mask-eval: JSON [{id,text,tone?}]") }
    let formats = maskFormats.split(separator: ",").compactMap { EntityMasker.Format(rawValue: String($0)) }
    timed("mask-eval") {
        func run(_ r: ResolvedRequest) async throws -> String {
            var out = ""
            for try await c in engine.primary.translate(r) { out += c }
            return out
        }
        var tot: [String: (warn: Int, fail: Int, chars: Int, secs: Double)] = [:]
        var lostTot: [String: Int] = [:]
        var n = 0
        for it in items {
            guard let t = it["text"] as? String, let id = it["id"] as? String else { continue }
            let tn = (it["tone"] as? String).flatMap { Tone(rawValue: $0) } ?? .auto
            let req = TranslationRequest(text: t, source: source, target: target, tone: tn)
            let base = LanguageDetector.resolve(req, config: engine.config)
            let ents = EntityMasker.mask(t, format: formats.first).entities.count
            if ents == 0 { err("\(id): сущностей нет, пропуск"); continue }
            n += 1
            func rec(_ k: String, _ w: Int, _ f: Int, _ ch: Int, _ s: Double) { let o = tot[k] ?? (0, 0, 0, 0); tot[k] = (o.warn + w, o.fail + f, o.chars + ch, o.secs + s) }
            let t0 = Date()
            let plain = try await run(base)
            let wb = TranslationCheck.warnings(source: t, translation: plain, from: base.source, to: base.target)
            rec("без маскировки", wb.count, 0, t.count + engine.debugSystemPrompt(for: req).count, Date().timeIntervalSince(t0))
            let lostBase = EntityMasker.mask(t, format: formats.first).entities.filter { !plain.contains($0.original) }
            lostTot["без маскировки", default: 0] += lostBase.count
            print("[\(id)] сущностей \(ents), дословно не сохранилось без маскировки: \(lostBase.count) \(lostBase.map(\.original))\n  БЕЗ: \(wb.isEmpty ? "ок" : wb.joined(separator: "; "))\n      \(plain.replacingOccurrences(of: "\n", with: " ").prefix(2000))")
            for f in formats {
                let m = EntityMasker.mask(t, format: f)
                var mr = base; mr.text = m.text; mr.protectedExample = f.token(1)
                var qr = req; qr.text = m.text
                let t1 = Date()
                let out = try await run(mr)
                let dt = Date().timeIntervalSince(t1)
                let sysLen = engine.debugSystemPrompt(for: qr).count + EntityMasker.promptNote(example: f.token(1)).count
                if let restored = m.restore(out) {
                    let w = TranslationCheck.warnings(source: t, translation: restored, from: base.source, to: base.target)
                    rec(f.rawValue, w.count, 0, m.text.count + sysLen, dt)
                    print("  \(f.rawValue): \(w.isEmpty ? "ок" : w.joined(separator: "; "))\n      \(restored.replacingOccurrences(of: "\n", with: " ").prefix(2000))")
                } else {
                    rec(f.rawValue, wb.count, 1, m.text.count + sysLen, dt)
                    print("  \(f.rawValue): ПОТЕРЯ/ДУБЛЬ ЗАГЛУШКИ → запасной путь\n      \(out.replacingOccurrences(of: "\n", with: " ").prefix(220))")
                }
            }
        }
        print("\n=== итого по \(n) текстам с сущностями ===")
        for (k, v) in tot.sorted(by: { $0.key < $1.key }) {
            print("\(k.padding(toLength: 16, withPad: " ", startingAt: 0)) предупреждений проверки: \(v.warn)  сбоев заглушек: \(v.fail)  символов промпта (всего): \(v.chars)  дословно потеряно сущностей: \(lostTot[k] ?? 0)  время: \(String(format: "%.0f", v.secs)) с")
        }
    }
}
if let trapCorpusPath {
    guard let items = TrapCorpus.load(path: trapCorpusPath) else { fail("--trap-corpus: cannot read \(trapCorpusPath)") }
    let only = trapOnly.map { Set($0.split(separator: ",").map { String($0) }) }
    let run = items.filter { only == nil || only!.contains($0.id) || only!.contains($0.trap) }
    let cfg = config   // includes --model
    let store = RulesStore(path: rulesPath ?? cfg.effectiveRulesPath)
    let eng = DefaultTranslationEngine(config: cfg, rules: store, primary: OllamaProvider(config: cfg, rules: store), fallback: nil)
    timed("trap-corpus") {
        var results: [(item: TrapItem, passed: Bool)] = []
        var json: [[String: Any]] = []
        var totalSecs = 0.0
        for it in run {   // strictly sequential
            var out = ""
            let t0 = Date()
            for try await e in eng.translate(TranslationRequest(text: it.text, source: it.from, target: it.to, tone: it.tone)) {
                if case let .delta(d) = e { out += d }
            }
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let secs = Date().timeIntervalSince(t0); totalSecs += secs
            var f = TrapCorpus.failures(it, translation: out)
            var backText = "", backIssues: [String] = []
            if trapBack, !out.isEmpty {
                for try await e in eng.translate(TranslationRequest(text: out, source: it.to, target: it.from, tone: .auto)) {
                    if case let .delta(d) = e { backText += d }
                }
                backText = backText.trimmingCharacters(in: .whitespacesAndNewlines)
                backIssues = BackCheck.compare(source: it.text, back: backText, lang: it.from)
            }
            let rulesOK = f.isEmpty
            f += backIssues.map { "↩︎ " + $0 }
            results.append((it, f.isEmpty))
            print("[\(it.id) \(it.trap)] \(f.isEmpty ? "ок" : "ПРОВАЛ")\n  \(it.text)\n  → \(out.replacingOccurrences(of: "\n", with: " "))")
            if trapBack { print("  ↩︎ \(backText.replacingOccurrences(of: "\n", with: " "))") }
            for x in f { print("  ✗ \(x)") }
            json.append(["id": it.id, "trap": it.trap, "text": it.text, "translation": out, "passed": f.isEmpty, "rules_ok": rulesOK, "back_ok": backIssues.isEmpty,
                         "back": backText, "failures": f, "secs": secs])
        }
        print("\n=== сводка (верно по автопроверке) ===")
        for s in TrapCorpus.summary(results) { print("\(s.trap.padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.passed)/\(s.total)") }
        if trapBack {
            let ro = json.filter { ($0["rules_ok"] as? Bool) == true }.count, bo = json.filter { ($0["back_ok"] as? Bool) == true }.count
            let both = json.filter { ($0["rules_ok"] as? Bool) == true && ($0["back_ok"] as? Bool) == true }.count
            print("правила: \(ro)/\(results.count), обратный перевод: \(bo)/\(results.count), оба сигнала: \(both)/\(results.count), спорных (сигналы расходятся): \(json.filter { ($0["rules_ok"] as? Bool) != ($0["back_ok"] as? Bool) }.count)")
        }
        print("всего \(results.filter(\.passed).count)/\(results.count), в среднем \(String(format: "%.1f", totalSecs / Double(max(1, results.count)))) с на текст")
        if let trapOut, let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? d.write(to: URL(fileURLWithPath: (trapOut as NSString).expandingTildeInPath))
        }
    }
}
if let variantsCurrent {
    timed("variants") {
        let vs = try await engine.sentenceVariants(sentence: text, current: variantsCurrent, fullSource: contextSource ?? text,
                                                   fullTranslation: contextTranslation ?? variantsCurrent, from: lsrc, to: ldst, tone: tone)
        for v in vs { print("• [\(v.label)] \(v.text)") }
        if vs.isEmpty { print("(нет вариантов)") }
    }
}
if let variantsAll {
    timed("variants-all") {
        let vs = try await engine.translationVariants(source: text, translation: variantsAll, from: lsrc, to: ldst, tone: tone, replyTo: replyTo)
        for v in vs { print("• [\(v.label)] \(v.reason)\n    \(v.text.replacingOccurrences(of: "\n", with: "\n    "))") }
        if vs.isEmpty { print("(нет вариантов)") }
    }
}
if let rewriteMode, let rewriteTranslation {
    timed("rewrite \(rewriteMode.rawValue)") {
        let r = try await engine.rewrite(translation: rewriteTranslation, source: text, from: lsrc, to: ldst, mode: rewriteMode)
        print(r.text)
        if !r.accepted { err("⚠️ отклонено: \(r.rejection ?? "?") — оставлен исходный текст") }
        else if !r.changed { err("(без изменений)") }
        if r.pronounsChecked { err("(местоимения проверены)") }
    }
}
if let composeTone {
    timed("compose \(composeTone.rawValue)") {
        let r = try await engine.compose(points: text, tone: composeTone, to: ldst, partnerMessage: replyTo)
        print(r.text)
        if ProcessInfo.processInfo.environment["TOLK_NO_BACK"] == nil, let b = await engine.composeBackTranslation(of: r, userLanguage: lsrc) { err("↩︎ \(b)") }
        for w in r.warnings { err("⚠️ \(w)") }
    }
}
if wantExplain {
    timed("explain") {
        let e = try await engine.explain(message: text)
        print("Смысл: \(e.meaning)\nТон: \(e.tone)")
        for t in e.terms { print("  • \(t.term) — \(t.meaning)") }
    }
}
var context: TranslationContext?
if let contextSource, let contextTranslation { context = TranslationContext(source: contextSource, translation: contextTranslation) }
else if contextSource != nil || contextTranslation != nil { fail("--context-source and --context-translation go together") }
var request = TranslationRequest(text: text, source: source, target: target, tone: tone, mode: mode, replyTo: replyTo, context: context)
if !prevTurns.isEmpty { request.threadContext = prevTurns.map { $0.replacingOccurrences(of: " => ", with: " ⇒ ") }.joined(separator: "\n") }
// A reply answers the partner: the target is the language of THEIR message unless --to is given.
if let replyTo, target == nil, mode == .translate {
    let r = engine.replyRequest(message: replyTo, reply: text, tone: tone)
    request.target = r.target
    if source == nil { request.source = r.source }
}
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
                // Google and Apple here go the way they go in the app as the fallback: with the glossary (TOLK_PLAIN_FALLBACK=1 = without).
                let plain = ProcessInfo.processInfo.environment["TOLK_PLAIN_FALLBACK"] != nil
                let s = (p is GoogleProvider || p is AppleTranslationProvider) ? FallbackGlossary.stream(r, provider: p, rules: engine.rules, enabled: !plain) : p.translate(r)
                for try await d in s { c.yield(.delta(d)) }
                c.yield(.finished); c.finish()
            } catch { c.finish(throwing: error) }
        }
        c.onTermination = { _ in t.cancel() }
    }
}

if twice {
    timed("twice") {
        for n in 1...2 {
            let t0 = Date()
            var out = "", cached = false
            for try await e in engine.translate(request) {
                if case let .delta(d) = e { out += d }
                if case let .stats(st) = e { cached = st.fromCache }
            }
            err("[перевод \(n): \(String(format: "%.3f", Date().timeIntervalSince(t0))) с\(cached ? " · из кеша" : "")] \(out)")
        }
    }
}
let stream: AsyncThrowingStream<TranslationEvent, Error>
switch providerName {
case "auto": stream = engine.translate(request)
case "ollama", "qwen": stream = direct(engine.primary)
case "google": stream = direct(GoogleProvider())
case "apple": stream = direct(AppleTranslationProvider())   // on-device; needs the language packs
default: fail("--provider: auto|ollama|google|apple")
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
// Apple's translation service answers only while the main run loop turns; a blocked main thread makes it time out.
if providerName == "apple" {
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
} else {
    done.wait()
}
exit(status)
