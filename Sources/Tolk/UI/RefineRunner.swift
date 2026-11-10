import Foundation
import TolkCore

/// Second pass over a finished translation. Not automatic; one click undoes it.
@MainActor
final class RefineRunner {
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var isRunning = false

    func cancel() { task?.cancel(); task = nil; generation += 1; isRunning = false }

    func start(engine: TranslationEngine, source: String, translation: String, from: Language, to: Language,
               tone: Tone, onDelta: @escaping (String) -> Void, onDone: @escaping () -> Void,
               onFail: @escaping (String) -> Void) {
        cancel()
        let gen = generation
        isRunning = true
        // The history decorator does not forward `refine`; ask the real engine.
        let real = (engine as? HistoryRecordingEngine)?.base ?? engine
        let stream = real.refine(source: source, translation: translation, from: from, to: to, tone: tone)
        task = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    onDelta(chunk)
                }
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.isRunning = false
                onDone()
            } catch {
                guard let self, self.generation == gen, !Task.isCancelled, !(error is CancellationError) else { return }
                self.isRunning = false
                onFail(UIText.errorMessage(error))
            }
        }
    }
}
