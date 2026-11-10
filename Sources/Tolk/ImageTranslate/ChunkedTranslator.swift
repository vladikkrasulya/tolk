// Translates long OCR text in paragraph-sized parts, one after another,
// streaming every part into one growing text (keeps requests within the model's limits).
import Foundation
import TolkCore

@MainActor
final class ChunkedTranslator {
    enum Update {
        case started(provider: String, source: Language, target: Language)
        /// Whole translation so far (all finished parts + the streaming one).
        case text(String)
        /// Part `index` (0-based) of `total` is being translated.
        case progress(index: Int, total: Int)
        case fellBack(from: String, reason: String)
        case finished
        case failed(String)
    }

    /// Max characters per request. Paragraphs are packed up to this size; longer ones are split by sentences.
    nonisolated static let chunkLimit = 1500

    var onUpdate: ((Update) -> Void)?
    private(set) var isRunning = false
    private(set) var translation = ""

    private let runner: TranslationRunner
    private var chunks: [String] = []
    private var index = 0
    private var done = ""
    private var current = ""
    private var target: Language?

    init(engine: TranslationEngine) {
        runner = TranslationRunner(engine: engine)
        runner.onUpdate = { [weak self] in self?.handle($0) }
    }

    func start(text: String, target: Language?) {
        cancel()
        chunks = Self.chunks(of: text)
        guard !chunks.isEmpty else { return }
        index = 0; done = ""; current = ""; translation = ""
        self.target = target
        isRunning = true
        runCurrent()
    }

    func cancel() {
        runner.cancel()
        isRunning = false
    }

    private func runCurrent() {
        // A part already written in the target language is kept as is (a Russian page with an English
        // quote, translated "to Russian", must not be turned into English by the engine's auto-swap).
        while index < chunks.count, let target, Self.isWritten(chunks[index], in: target) {
            done = done.isEmpty ? chunks[index] : done + "\n\n" + chunks[index]
            index += 1
            publish()
        }
        guard index < chunks.count else {
            isRunning = false
            onUpdate?(.finished)
            return
        }
        onUpdate?(.progress(index: index, total: chunks.count))
        // The target of the first part is reused for all parts, so an auto direction stays consistent;
        // the source is detected per part (a page may mix languages).
        runner.start(TranslationRequest(text: chunks[index], source: nil, target: target, tone: .auto))
    }

    /// nil for pieces without words (numbers, symbols): those never start a new part.
    nonisolated private static func detectLanguage(_ text: String) -> Language? {
        text.filter(\.isLetter).count >= 3 ? LanguageDetector.detect(text) : nil
    }

    nonisolated private static func isWritten(_ text: String, in language: Language) -> Bool {
        detectLanguage(text) == language
    }

    private func handle(_ update: TranslationRunner.Update) {
        guard isRunning else { return }
        switch update {
        case let .started(provider, source, target):
            if self.target == nil { self.target = target }
            onUpdate?(.started(provider: provider, source: source, target: target))
        case let .delta(s):
            current += s
            publish()
        case let .fellBack(from, reason):
            current = ""
            publish()
            onUpdate?(.fellBack(from: from, reason: reason))
        case .finished:
            let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { done = done.isEmpty ? part : done + "\n\n" + part }
            current = ""
            publish()
            index += 1
            runCurrent()
        case let .failed(message):
            isRunning = false
            onUpdate?(.failed(message))
        }
    }

    private func publish() {
        let cur = current.trimmingCharacters(in: .newlines)
        translation = cur.isEmpty ? done : (done.isEmpty ? cur : done + "\n\n" + cur)
        onUpdate?(.text(translation))
    }

    // MARK: - Splitting

    /// Packs paragraphs (separated by blank lines) into parts of at most `limit` characters.
    nonisolated static func chunks(of text: String, limit: Int = chunkLimit) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var pieces: [String] = []
        for p in paragraphs {
            if p.count <= limit { pieces.append(p) } else { pieces += splitLong(p, limit: limit) }
        }
        // Parts never mix languages: the engine detects one source language per request.
        var result: [String] = []
        var acc = ""
        var accLanguage: Language?
        for piece in pieces {
            let lang = detectLanguage(piece)
            let sameLanguage = lang == nil || accLanguage == nil || lang == accLanguage
            if acc.isEmpty { acc = piece; accLanguage = lang }
            else if sameLanguage, acc.count + 2 + piece.count <= limit { acc += "\n\n" + piece; accLanguage = accLanguage ?? lang }
            else { result.append(acc); acc = piece; accLanguage = lang }
        }
        if !acc.isEmpty { result.append(acc) }
        return result
    }

    /// Splits one long paragraph at sentence ends (or, failing that, at spaces).
    nonisolated private static func splitLong(_ p: String, limit: Int) -> [String] {
        var sentences: [String] = []
        p.enumerateSubstrings(in: p.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { sentences.append(s) }
        }
        if sentences.isEmpty { sentences = [p] }
        var out: [String] = []
        var acc = ""
        for var s in sentences {
            while s.count > limit { // a "sentence" longer than the limit: cut at the last space
                let cut = s.index(s.startIndex, offsetBy: limit)
                let at = s[..<cut].lastIndex(of: " ") ?? cut
                if !acc.isEmpty { out.append(acc.trimmingCharacters(in: .whitespaces)); acc = "" }
                out.append(String(s[..<at]).trimmingCharacters(in: .whitespaces))
                s = String(s[at...])
            }
            if acc.count + s.count > limit, !acc.isEmpty {
                out.append(acc.trimmingCharacters(in: .whitespaces)); acc = ""
            }
            acc += s
        }
        if !acc.trimmingCharacters(in: .whitespaces).isEmpty { out.append(acc.trimmingCharacters(in: .whitespaces)) }
        return out
    }
}
