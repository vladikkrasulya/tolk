// Owned by the "documents" helper. Translates a document paragraph by paragraph, in order, one request at a time.
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
        task = Task { @MainActor [weak self] in await self?.run(from: first) }
    }

    /// Pause / cancel: stops the running request; the unfinished paragraph will be translated again.
    func stop() {
        task?.cancel()
        task = nil
        if let since = activeSince { activeTime += Date().timeIntervalSince(since); activeSince = nil }
        current = nil
        partial = ""
    }

    /// Active (not paused) translation time.
    var elapsed: TimeInterval { activeTime + (activeSince.map { Date().timeIntervalSince($0) } ?? 0) }

    /// Characters left to translate.
    var remainingChars: Int {
        var n = 0
        for (i, p) in paragraphs.enumerated() where translations[i] == nil && p.translatable { n += p.text.count }
        return max(0, n - partial.count)
    }

    /// Seconds left: measured speed (characters per second incl. request overhead) once a few paragraphs are
    /// done; before that `speed` characters/s plus `perRequest` seconds per paragraph.
    func remainingEstimate(speed: Double, perRequest: Double) -> TimeInterval {
        let chars = Double(remainingChars)
        if measuredChars >= 300, measuredTime > 1 { return chars / (Double(measuredChars) / measuredTime) }
        var requests = 0
        for (i, p) in paragraphs.enumerated() where translations[i] == nil && p.translatable { requests += 1 }
        return chars / speed + Double(requests) * perRequest
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
                    let stream = engine.translate(TranslationRequest(text: piece, source: nil, target: target, tone: tone))
                    for try await event in stream {
                        if Task.isCancelled { return }
                        switch event {
                        case let .started(provider, _, _): onEvent?(.provider(provider))
                        case let .delta(s):
                            chunk += s
                            partial = Self.join(finished, chunk)
                            onEvent?(.partial(i, partial))
                        case let .fellBack(from, reason):
                            chunk = ""
                            onEvent?(.fellBack(from: from, reason: reason))
                        case .stats, .finished: break
                        }
                    }
                    if Task.isCancelled { return }
                    finished = Self.join(finished, chunk.trimmingCharacters(in: .whitespacesAndNewlines))
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
        if let since = activeSince { activeTime += Date().timeIntervalSince(since); activeSince = nil }
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
