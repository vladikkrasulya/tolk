// Owned by the "history" helper. Decorator that records finished translations into `HistoryStore`.
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
    var appProvider: @Sendable () -> (name: String, bundleID: String?)?

    init(_ base: TranslationEngine, origin: String, store: HistoryStore,
         appProvider: (@Sendable () -> (name: String, bundleID: String?)?)? = nil) {
        self.base = base
        self.origin = origin
        self.store = store
        if let appProvider {
            self.appProvider = appProvider
        } else if origin == "page" || origin == "image" || origin == "document" {
            self.appProvider = { nil }
        } else {
            ExternalAppTracker.shared.start()
            self.appProvider = { ExternalAppTracker.shared.current }
        }
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error> {
        let inner = base.translate(request)
        guard store.isEnabled else { return inner }
        let app = appProvider()
        let requestedAt = Date()
        let origin = self.origin, store = self.store, mode = request.mode
        return AsyncThrowingStream { continuation in
            let task = Task {
                var provider = "", source = Language.english, target = Language.english
                var started = false, text = ""
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
                        case .stats:
                            break
                        case .finished:
                            guard started, !Task.isCancelled else { break }
                            store.record(HistoryEntry(origin: origin, app: app?.name, source: request.text,
                                                      translation: text, sourceLanguage: source,
                                                      targetLanguage: target, provider: provider, mode: mode,
                                                      appBundleID: app?.bundleID),
                                         requestedAt: requestedAt)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func addGlossaryTerm(source: String, translation: String) throws {
        try base.addGlossaryTerm(source: source, translation: translation)
    }

    func notes(source: String, translation: String, from: Language, to: Language) async -> [TranslationNote] {
        await base.notes(source: source, translation: translation, from: from, to: to)
    }

    func alternatives(for fragment: String, in translation: String, source: String, from: Language, to: Language) async -> [String] {
        await base.alternatives(for: fragment, in: translation, source: source, from: from, to: to)
    }
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
