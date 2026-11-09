// STUB — owned by the "history" helper. Local translation history (only on this Mac).
import Foundation

public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    /// Where it came from: "popup", "reply", "quick", "page", "image", "document".
    public var origin: String
    /// Bundle id / name of the app the text came from, if known.
    public var app: String?
    public var source: String
    public var translation: String
    public var sourceLanguage: Language
    public var targetLanguage: Language
    public var provider: String
    public var mode: TextMode

    public init(id: UUID = UUID(), date: Date = Date(), origin: String, app: String?, source: String, translation: String,
                sourceLanguage: Language, targetLanguage: Language, provider: String, mode: TextMode) {
        self.id = id; self.date = date; self.origin = origin; self.app = app; self.source = source
        self.translation = translation; self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
        self.provider = provider; self.mode = mode
    }
}

public final class HistoryStore: @unchecked Sendable {
    public static let didChange = Notification.Name("TolkHistoryDidChange")
    public init(path: String = "~/Library/Application Support/Tolk/history.jsonl") {}
    public var isEnabled: Bool = true
    public func add(_ entry: HistoryEntry) {}
    public func all() -> [HistoryEntry] { [] }
    public func remove(ids: Set<UUID>) {}
    public func clear() {}
}
