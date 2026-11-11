// Decorator that records finished translations into `HistoryStore`.
//
//   let popupEngine = HistoryRecordingEngine(engine, origin: "popup", store: history)
//
// Everything is forwarded to the wrapped engine; the event stream passes through unchanged. On `.finished`
// the collected text is handed to `HistoryStore.record`, which filters junk (live typing, back-translation,
// short texts). Failed or cancelled streams are never recorded. Nothing leaves the Mac.
import AppKit
import TolkCore

final class HistoryRecordingEngine: TranslationEngine, @unchecked Sendable {
    let base: TranslationEngine
    let origin: String
    let store: HistoryStore
    /// App the text came from, read when the request starts. Default: the last active app other than Tolk
    /// (for "page"/"image" nil — the text was typed or captured in Tolk itself).
    let appProvider: @Sendable () -> (name: String, bundleID: String?)?

    init(_ base: TranslationEngine, origin: String, store: HistoryStore) {
        self.base = base
        self.origin = origin
        self.store = store
        if origin == "page" || origin == "image" || origin == "document" {
            self.appProvider = { nil }
        } else {
            ExternalAppTracker.shared.start()
            self.appProvider = { ExternalAppTracker.shared.current }
        }
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        let inner = base.translate(request)
        let keepHistory = store.isEnabled
        let app = appProvider()
        let requestedAt = Date()
        let origin = self.origin, store = self.store, mode = request.mode
        let chars = request.text.count
        return AsyncThrowingStream { continuation in
            let task = Task {
                var provider = "", source = Language.english, target = Language.english
                var started = false, text = ""
                var stats: TranslationStats?
                do {
                    for try await event in inner {
                        continuation.yield(event)
                        switch event {
                        case let .started(p, s, t):
                            provider = p; source = s; target = t; started = true; text = ""
                        case let .delta(chunk):
                            text += chunk
                        case .fellBack:
                            text = ""
                        case let .stats(s):
                            stats = s
                        case .finished:
                            guard started, !Task.isCancelled else { break }
                            // Numbers for «Статистика» and one line for the log — never the text itself.
                            let ms = stats.map { Int($0.total * 1000) }
                            let first = stats?.firstChunk.map { Int($0 * 1000) }
                            let cached = stats?.fromCache ?? false, fallback = stats?.fallbackReason != nil
                            UsageStore.shared.record(UsageEvent(
                                origin: origin, pair: "\(source.rawValue)→\(target.rawValue)", provider: stats?.provider ?? provider,
                                app: app?.name, chars: chars, totalMs: ms, firstChunkMs: first, cached: cached, fallback: fallback))
                            Diagnostics.log("translate: \(origin) \(source.rawValue)→\(target.rawValue) in=\(chars) out=\(text.count) "
                                + "provider=\(stats?.provider ?? provider) route=\(stats?.route.rawValue ?? "?") ms=\(ms.map(String.init) ?? "?")"
                                + (cached ? " cache" : "") + (stats?.fallbackReason.map { " fallback(\($0))" } ?? "")
                                + ((stats?.warnings.isEmpty ?? true) ? "" : " warnings=\(stats!.warnings.count)"))
                            guard keepHistory else { break }
                            // Live typing sends only the changed tail; history keeps the whole message.
                            let ctx = request.context
                            store.record(HistoryEntry(origin: origin, app: app?.name,
                                                      source: (ctx?.source ?? "") + request.text,
                                                      translation: (ctx?.translation ?? "") + text, sourceLanguage: source,
                                                      targetLanguage: target, provider: provider, mode: mode,
                                                      appBundleID: app?.bundleID),
                                         requestedAt: requestedAt)
                        }
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError), !Task.isCancelled {
                        UsageStore.shared.record(UsageEvent(origin: origin, failed: true))
                        Diagnostics.log("translate: \(origin) FAILED in=\(chars) after \(Int(Date().timeIntervalSince(requestedAt) * 1000)) ms: \(error.localizedDescription)")
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func addGlossaryTerm(source: String, translation: String) throws {
        try base.addGlossaryTerm(source: source, translation: translation)
    }

    func refine(source: String, translation: String, from: Language, to: Language, tone: Tone) -> AsyncThrowingStream<String, Error> {
        base.refine(source: source, translation: translation, from: from, to: to, tone: tone)
    }

    func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote] {
        await base.notes(source: source, translation: translation, from: from, to: to)
    }

    func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String] {
        await base.alternatives(for: fragment, in: translation, source: source, from: from, to: to)
    }

    func sentenceVariants(sentence: String, current: String, fullSource: String, fullTranslation: String,
                          from: Language, to: Language, tone: Tone) async throws -> [SentenceVariant] {
        try await base.sentenceVariants(sentence: sentence, current: current, fullSource: fullSource,
                                        fullTranslation: fullTranslation, from: from, to: to, tone: tone)
    }

    func rewrite(translation: String, source: String, from: Language, to: Language, mode: RewriteMode) async throws -> RewriteResult {
        try await base.rewrite(translation: translation, source: source, from: from, to: to, mode: mode)
    }

    func translationVariants(source: String, translation: String, from: Language, to: Language, tone: Tone, replyTo: String?) async throws -> [TranslationVariant] {
        try await base.translationVariants(source: source, translation: translation, from: from, to: to, tone: tone, replyTo: replyTo)
    }

    func explain(message: String) async throws -> MessageExplanation { try await base.explain(message: message) }

    func compose(points: String, tone: ComposeTone, to: Language, partnerMessage: String?, threadContext: String?) async throws -> ComposeResult {
        try await base.compose(points: points, tone: tone, to: to, partnerMessage: partnerMessage, threadContext: threadContext)
    }

    func replyRequest(message: String, reply: String, tone: Tone) -> TranslationRequest {
        base.replyRequest(message: message, reply: reply, tone: tone)
    }

    func glossaryHits(in text: String, target: Language) -> [GlossaryHit] { base.glossaryHits(in: text, target: target) }
}

/// Remembers the last active app that is not Tolk (the app a popup / reply / quick action text came from).
/// Event-driven (workspace activation notifications), no polling.
final class ExternalAppTracker: @unchecked Sendable {
    static let shared = ExternalAppTracker()
    private let lock = NSLock()
    private var value: (name: String, bundleID: String?)?
    private var observer: NSObjectProtocol?
    private var started = false

    var current: (name: String, bundleID: String?)? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func start() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        update(NSWorkspace.shared.frontmostApplication)
        let o = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            self?.update(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        lock.lock(); observer = o; lock.unlock()
    }

    private func update(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? ""
        guard !name.isEmpty else { return }
        lock.lock(); value = (name, app.bundleIdentifier); lock.unlock()
    }
}
