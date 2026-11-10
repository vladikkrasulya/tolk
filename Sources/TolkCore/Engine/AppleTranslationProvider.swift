import Foundation
#if canImport(Translation)
import Translation
#endif

/// Apple's on-device translation as the fallback (no network, nothing leaves the Mac).
/// Needs macOS 26+ and the language pair downloaded in System Settings → General → Language & Region →
/// Translation Languages. Plain translation only: no glossary, tone or slang.
public final class AppleTranslationProvider: TranslationProvider, @unchecked Sendable {
    public let name = "Apple"
    public init() {}

    /// Can this Mac use it at all (OS version)? Language packs are checked per request.
    public static var isSupportedOnThisMac: Bool {
        #if canImport(Translation)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    public func isAvailable() async -> Bool { Self.isSupportedOnThisMac }

    static func localeLanguage(_ l: Language) -> Locale.Language {
        Locale.Language(identifier: l == .chinese ? "zh-Hans" : l.rawValue)
    }

    public func translate(_ request: ResolvedRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(Translation)
                    if #available(macOS 26.0, *) {
                        let src = Self.localeLanguage(request.source), dst = Self.localeLanguage(request.target)
                        // LanguageAvailability can also hang without a run loop / without Translation services.
                        let status: LanguageAvailability.Status = try await Self.race(seconds: 5, what: "Проверка языков Apple не ответила за 5 с") { await LanguageAvailability().status(from: src, to: dst) }
                        guard status == .installed else {
                            throw TolkError.unavailable(status == .unsupported
                                ? "Apple не умеет переводить \(request.source.label) → \(request.target.label)"
                                : "не скачаны языки (\(request.source.label) → \(request.target.label)): Системные настройки → Основные → Язык и регион → Языки перевода → Скачать")
                        }
                        let session = TranslationSession(installedSource: src, target: dst)
                        let text = request.text
                        // Never hang: Apple's service can stall (e.g. without a main run loop).
                        let response: TranslationSession.Response = try await Self.race(seconds: 15, what: "Перевод Apple не ответил за 15 с") { try await session.translate(text) }
                        try Task.checkCancellation()
                        continuation.yield(response.targetText)
                        continuation.finish()
                        return
                    }
                    #endif
                    throw TolkError.unavailable("Перевод Apple работает на macOS 26 и новее")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Result or timeout, whichever first. Not a task group: a group would wait for the stuck call too.
    static func race<T: Sendable>(seconds: Double, what: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = NSLock(); var done = false
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            func finish(_ r: Result<T, Error>) { once.lock(); defer { once.unlock() }; if !done { done = true; c.resume(with: r) } }
            Task { do { finish(.success(try await work())) } catch { finish(.failure(error)) } }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); finish(.failure(TolkError.unavailable(what))) }
        }
    }
}
