// Tiny log hook for the engine: TolkCore has no logger of its own. The app sets `sink` to its Diagnostics.log
// (e.g. `EngineLog.sink = { Diagnostics.log($0) }` at launch); the CLI prints to stderr.
import Foundation

public enum EngineLog {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?
    public static func write(_ message: String) { sink?(message) }
}
