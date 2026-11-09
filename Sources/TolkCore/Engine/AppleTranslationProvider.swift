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
                        let status = await LanguageAvailability().status(from: src, to: dst)
                        guard status == .installed else {
                            throw TolkError.unavailable(status == .unsupported
                                ? "Apple не умеет переводить \(request.source.label) → \(request.target.label)"
                                : "Языки для перевода Apple не скачаны: Системные настройки → Основные → Язык и регион → Языки перевода")
                        }
                        let session = TranslationSession(installedSource: src, target: dst)
                        let text = request.text
                        // Never hang: Apple's service can stall (e.g. without a main run loop).
                        let response = try await withThrowingTaskGroup(of: TranslationSession.Response?.self) { g in
                            g.addTask { try await session.translate(text) }
                            g.addTask { try await Task.sleep(nanoseconds: 15_000_000_000); return nil }
                            defer { g.cancelAll() }
                            guard let first = try await g.next(), let r = first else {
                                throw TolkError.unavailable("Перевод Apple не ответил за 15 с")
                            }
                            return r
                        }
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
}
