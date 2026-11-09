// Dev tool for the engine.
// swift run tolk-cli [--from ru|uk|en] [--to ru|uk|en] [--tone auto|chat|formal]
//                    [--provider auto|ollama|google] [--show-rules] "text"
// Translation goes to stdout, service info to stderr. Text can also come from stdin.
import Foundation
import TolkCore

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never { err(s); exit(2) }

var source: Language?, target: Language?, tone = Tone.auto
var providerName = "auto", showRules = false
var cancelAfter: Double?, addTerm: String?
var words: [String] = []
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    func value() -> String {
        guard let v = args.next() else { fail("missing value for \(a)") }
        return v
    }
    switch a {
    case "--from":
        guard let l = Language(rawValue: value()) else { fail("--from: ru|uk|en") }
        source = l
    case "--to":
        guard let l = Language(rawValue: value()) else { fail("--to: ru|uk|en") }
        target = l
    case "--tone":
        guard let t = Tone(rawValue: value()) else { fail("--tone: auto|chat|formal") }
        tone = t
    case "--provider": providerName = value()
    case "--show-rules": showRules = true
    case "--cancel-after": cancelAfter = Double(value())   // dev: test consumer cancellation
    case "--add-term": addTerm = value()                    // "source => translation"
    case "-h", "--help":
        err("usage: tolk-cli [--from L] [--to L] [--tone auto|chat|formal] [--provider auto|ollama|google] [--show-rules] [--cancel-after SEC] text\n       tolk-cli --add-term 'source => translation'")
        exit(0)
    default: words.append(a)
    }
}
if let addTerm {
    let parts = addTerm.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2 else { fail("--add-term 'source => translation'") }
    do { try DefaultTranslationEngine(config: TolkConfig.load()).addGlossaryTerm(source: parts[0], translation: parts[1]) }
    catch { fail("add-term: \(error)") }
    err("added: - \(parts[0]) → \(parts[1])")
    exit(0)
}
var text = words.joined(separator: " ")
if text.isEmpty, isatty(0) == 0 {
    text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}
if text.isEmpty { fail("no text; see --help") }

let config = TolkConfig.load()
let engine = DefaultTranslationEngine(config: config)
let request = TranslationRequest(text: text, source: source, target: target, tone: tone)
if showRules { err("--- rules block ---\n" + engine.rules.promptBlock(for: text) + "\n-------------------") }

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
func ms() -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }
let done = DispatchSemaphore(value: 0)
var status: Int32 = 0
let consumer = Task {
    var first = true
    do {
        for try await e in stream {
            switch e {
            case let .started(p, s, t): err("[\(p) \(s.label)->\(t.label)] \(ms())"); first = true
            case let .delta(d):
                if first { err("[first chunk \(ms())]"); first = false }
                print(d, terminator: ""); fflush(stdout)
            case let .fellBack(from, reason): err("[fallback from \(from): \(reason)] \(ms())")
            case .finished: print(); fflush(stdout); err("[done \(ms())]")
            }
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
