// Glue between EntityMasker and a provider: translate the masked text, put the fragments back, and fall back to the
// unmasked text when the model lost or duplicated a placeholder. A text with protected fragments is buffered (the
// answer is checked before anything is shown); texts without any go through untouched and still stream.
import Foundation

public enum EntityMasking {
    /// Master switch, OFF by default: on 24 adtech texts gemma-translate kept every fragment itself and masking only
    /// cost prompt length and some phrasing quality (see report). CLI `--mask-on`; a settings toggle can drive it.
    nonisolated(unsafe) public static var enabled = false

    public static func stream(_ r: ResolvedRequest, provider: TranslationProvider) -> AsyncThrowingStream<String, Error> {
        guard enabled, r.mode == .translate else { return provider.translate(r) }
        let m = EntityMasker.mask(r.text)
        guard !m.entities.isEmpty else { return provider.translate(r) }
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    var masked = r
                    masked.text = m.text
                    masked.protectedExample = m.format.token(1)
                    var out = ""
                    for try await chunk in provider.translate(masked) {
                        try Task.checkCancellation()
                        out += chunk
                    }
                    if let restored = m.restore(out) {
                        c.yield(restored); c.finish(); return
                    }
                    EngineLog.write("mask: placeholder lost/duplicated, retry without masking (\(m.entities.count) entities: \(m.summary))")
                    for try await chunk in provider.translate(r) { try Task.checkCancellation(); c.yield(chunk) }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}
