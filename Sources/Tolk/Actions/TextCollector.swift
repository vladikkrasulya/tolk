// Owned by the "quick actions" session.
import Foundation
import TolkCore

/// Whole result of one engine stream.
struct CollectedText: Equatable {
    var text: String
    /// Provider that produced `text` (last `.started`).
    var provider: String
    var fellBack: Bool
}

enum TextCollector {
    /// Collects the stream into one string. `.started` after `.fellBack` discards earlier text
    /// (contract: the fallback starts over). Throws `CancellationError` if the task is cancelled —
    /// a cancelled `AsyncThrowingStream` just ends, which must not look like a finished result.
    @MainActor
    static func collect(_ stream: AsyncThrowingStream<TranslationEvent, Error>,
                        onEvent: (TranslationEvent) -> Void = { _ in }) async throws -> CollectedText {
        var result = CollectedText(text: "", provider: "", fellBack: false)
        var finished = false
        for try await event in stream {
            try Task.checkCancellation()
            onEvent(event)
            switch event {
            case let .started(provider, _, _): result.provider = provider; result.text = ""
            case let .delta(chunk): result.text += chunk
            case .fellBack: result.fellBack = true
            case .stats: break
            case .finished: finished = true
            }
        }
        try Task.checkCancellation()
        if !finished { throw CancellationError() } // stream ended without .finished = terminated
        return result
    }

    /// Models trim; the selection often ends with a newline or space. Put the original
    /// leading/trailing whitespace around the result so replacing does not glue lines together.
    static func reapplyWhitespace(of original: String, to result: String) -> String {
        let core = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = original.prefix { $0.isWhitespace }
        let trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        if original.allSatisfy(\.isWhitespace) { return core }
        return lead + core + trail
    }
}
