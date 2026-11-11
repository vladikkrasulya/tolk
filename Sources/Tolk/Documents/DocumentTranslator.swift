// Translates a document paragraph by paragraph, in order, one request at a time.
import Foundation
import TolkCore

@MainActor
final class DocumentTranslator {
    enum Event {
        case provider(String)
        case fellBack(from: String, reason: String)
        /// Paragraph `index` started; streaming text arrives with `.partial`.
        case began(Int)
        case partial(Int, String)
        /// Paragraph finished (translated, or kept as is).
        case done(Int)
        case finished
        /// Stopped by an error; the paragraphs done so far are kept.
        case failed(String)
    }

    /// Paragraphs longer than this are sent in several requests (split at sentence ends).
    static let requestLimit = 1500

    var engine: TranslationEngine
    var onEvent: ((Event) -> Void)?

    private(set) var paragraphs: [DocParagraph] = []
    /// Translation per paragraph; nil = not translated yet.
    private(set) var translations: [String?] = []
    /// Paragraphs kept as is (already in the target language, or no words).
    private(set) var kept: Set<Int> = []
    private(set) var current: Int?
    private(set) var partial = ""
    private(set) var target: Language?
    private(set) var tone: Tone = .formal

    private var task: Task<Void, Never>?
    /// «Редактор после перевода» for this run and whether the document reads as an official one.
    private var editorMode = "off"
    private var official = false
    /// Paragraphs the editor changed in this document (for the log and the status line).
    private(set) var editedCount = 0
    private var activeSince: Date?
    private var activeTime: TimeInterval = 0
    /// Characters sent to the model while active (for the measured speed).
    private var measuredChars = 0
    private var measuredTime: TimeInterval = 0

    var isRunning: Bool { task != nil }
    var doneCount: Int { translations.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    var isComplete: Bool { !translations.isEmpty && doneCount == translations.count }
    var hasAnyTranslation: Bool { translations.contains { $0 != nil } }

    init(engine: TranslationEngine) { self.engine = engine }

    /// New document: forgets all translations.
    func load(_ paragraphs: [DocParagraph]) {
        stop()
        self.paragraphs = paragraphs
        translations = Array(repeating: nil, count: paragraphs.count)
        kept = []
        current = nil; partial = ""
        activeTime = 0; measuredChars = 0; measuredTime = 0
        editedCount = 0
        target = nil
    }

    /// Clears translations (e.g. another target language was chosen).
    func reset() {
        stop()
        translations = Array(repeating: nil, count: paragraphs.count)
        kept = []
        activeTime = 0; measuredChars = 0; measuredTime = 0
    }

    /// Continues from the first untranslated paragraph. A different target/tone starts over.
    func start(target: Language, tone: Tone) {
        stop()
        if hasAnyTranslation, self.target != target || self.tone != tone { reset() }
        self.target = target
        self.tone = tone
        guard let first = translations.firstIndex(where: { $0 == nil }) else { onEvent?(.finished); return }
        activeSince = Date()
        // Decided once per run: is this an official document, and does the editor read its paragraphs?
        editorMode = TolkConfig.load().autoEditor
        official = AutoEditor.isOfficial(paragraphs.map(\.text).joined(separator: "\n"))
        if editorMode != "off" { Diagnostics.log("documents: editor=\(editorMode) official=\(official) paragraphs=\(paragraphs.count)") }
        let formal = official
        task = Task { @MainActor [weak self] in
            await FormalContext.$forced.withValue(formal) { await self?.run(from: first) }
        }
    }

    /// Pause / cancel: stops the running request; the unfinished paragraph will be translated again.
    func stop() {
        task?.cancel()
        task = nil
        stopClock()
        current = nil
        partial = ""
    }

    private func stopClock() {
        guard let since = activeSince else { return }
        activeTime += Date().timeIntervalSince(since)
        activeSince = nil
    }

    /// Active (not paused) translation time.
    var elapsed: TimeInterval { activeTime + (activeSince.map { Date().timeIntervalSince($0) } ?? 0) }

    /// Characters left to translate.
    var remainingChars: Int {
        max(0, pending.reduce(0) { $0 + $1.text.count } - partial.count)
    }

    /// Untranslated paragraphs that will be sent to the model.
    private var pending: [DocParagraph] {
        paragraphs.indices.filter { translations[$0] == nil && paragraphs[$0].translatable }.map { paragraphs[$0] }
    }

    /// Seconds left: measured speed (characters per second incl. request overhead) once a few paragraphs are
    /// done; before that `speed` characters/s plus `perRequest` seconds per paragraph.
    func remainingEstimate(speed: Double, perRequest: Double) -> TimeInterval {
        let chars = Double(remainingChars)
        if measuredChars >= 300, measuredTime > 1 { return chars / (Double(measuredChars) / measuredTime) }
        return chars / speed + Double(pending.count) * perRequest
    }

    // MARK: - Loop

    private func run(from start: Int) async {
        guard let target else { return }
        for i in start..<paragraphs.count {
            if Task.isCancelled { return }
            guard translations[i] == nil else { continue }
            let p = paragraphs[i]
            if !p.translatable || Self.isWritten(p.text, in: target) {
                translations[i] = p.text
                kept.insert(i)
                onEvent?(.done(i))
                continue
            }
            current = i
            partial = ""
            onEvent?(.began(i))
            let began = Date()
            let pieces = p.text.count > Self.requestLimit ? ChunkedTranslator.chunks(of: p.text, limit: Self.requestLimit) : [p.text]
            var finished = ""
            do {
                for piece in pieces {
                    var chunk = ""
                    var fellBack = false
                    var sourceLanguage: Language?
                    let stream = engine.translate(TranslationRequest(text: piece, source: nil, target: target, tone: tone))
                    for try await event in stream {
                        if Task.isCancelled { return }
                        switch event {
                        case let .started(provider, from, _):
                            sourceLanguage = from
                            onEvent?(.provider(provider))
                        case let .delta(s):
                            chunk += s
                            partial = Self.join(finished, chunk)
                            onEvent?(.partial(i, partial))
                        case let .fellBack(from, reason):
                            chunk = ""
                            fellBack = true
                            onEvent?(.fellBack(from: from, reason: reason))
                        case .stats, .finished: break
                        }
                    }
                    if Task.isCancelled { return }
                    var piecedone = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Second look by the editor: fixes case agreement and calques the first pass leaves in long
                    // sentences. Only with the home model (after a fallback there is nobody to ask).
                    if !fellBack, let from = sourceLanguage, !piecedone.isEmpty,
                       AutoEditor.wantedForParagraph(mode: editorMode, paragraph: piece, documentIsOfficial: official) {
                        let real = (engine as? HistoryRecordingEngine)?.base ?? engine
                        var edited = ""
                        for try await part in real.refine(source: piece, translation: piecedone, from: from, to: target, tone: tone) {
                            if Task.isCancelled { return }
                            edited += part
                        }
                        edited = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !edited.isEmpty, edited != piecedone {
                            piecedone = edited
                            editedCount += 1
                            partial = Self.join(finished, piecedone)
                            onEvent?(.partial(i, partial))
                        }
                    }
                    finished = Self.join(finished, piecedone)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                stop()
                onEvent?(.failed(UIText.errorMessage(error)))
                return
            }
            if Task.isCancelled { return }
            measuredChars += p.text.count
            measuredTime += Date().timeIntervalSince(began)
            // An empty answer would lose the paragraph: keep the original instead.
            translations[i] = finished.isEmpty ? p.text : finished
            if finished.isEmpty { kept.insert(i) }
            current = nil
            partial = ""
            onEvent?(.done(i))
        }
        if Task.isCancelled { return }
        task = nil
        stopClock()
        if editorMode != "off" { Diagnostics.log("documents: finished, editor changed \(editedCount) paragraph(s)") }
        onEvent?(.finished)
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : (b.isEmpty ? a : a + " " + b)
    }

    /// A paragraph already written in the target language is kept (the engine would otherwise swap direction).
    static func isWritten(_ text: String, in language: Language) -> Bool {
        text.filter(\.isLetter).count >= 3 && LanguageDetector.detect(text) == language
    }
}

#if DEBUG
extension DocumentTranslator {
    /// Dev: `TOLK_DOC_TEST=file.txt [TOLK_DOC_TO=ru]` translates the file's paragraphs (blank-line separated) through
    /// this class with the real engine, prints the result and quits.
    static func runTestIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TOLK_DOC_TEST"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { DocParagraph(text: $0) }
        let t = DocumentTranslator(engine: DefaultTranslationEngine(config: TolkConfig.load()))
        keepAlive = t
        t.load(paragraphs)
        let started = Date()
        t.onEvent = { event in
            switch event {
            case .finished:
                for (i, tr) in t.translations.enumerated() { print("[\(i)] " + (tr ?? "—")) }
                print("[doc-test] edited=\(t.editedCount) seconds=\(Int(Date().timeIntervalSince(started)))")
                exit(0)
            case let .failed(m): print("[doc-test] failed: \(m)"); exit(1)
            default: break
            }
        }
        t.start(target: Language(rawValue: env["TOLK_DOC_TO"] ?? "ru") ?? .russian, tone: .formal)
        return true
    }
    private static var keepAlive: DocumentTranslator?
}
#endif
