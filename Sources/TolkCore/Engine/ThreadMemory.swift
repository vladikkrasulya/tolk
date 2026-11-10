// Short-term memory of a conversation: the last few translations per source app (bundle id), memory only, expiring.
// A short new text from the same app soon after the previous one gets those lines as "context, do not translate":
// «Can we raise the floor on them?» only translates well when the model knows who «them» are.
//
// App wiring (see report): after a popup translation finishes `memory.record(...)`; when the popup builds its
// TranslationRequest: `request.threadContext = memory.context(for: text, app: bundleID)`.
import Foundation

public final class ThreadMemory: @unchecked Sendable {
    public struct Turn: Sendable, Equatable {
        public let source: String
        public let translation: String
        public let from: Language
        public let to: Language
        public let at: Date
    }

    public let capacity: Int
    public let expiry: TimeInterval
    public let window: TimeInterval
    public let maxWords: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var turns: [String: [Turn]] = [:]

    public init(capacity: Int = 3, expiry: TimeInterval = 15 * 60, window: TimeInterval = 5 * 60, maxWords: Int = 20,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = capacity; self.expiry = expiry; self.window = window; self.maxWords = maxWords; self.now = now
    }

    /// Shared instance for the app.
    public static let shared = ThreadMemory()

    public func record(source: String, translation: String, from: Language, to: Language, app: String?) {
        guard let app, !app.isEmpty else { return }
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines), t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        purge()
        var list = (turns[app] ?? []).filter { $0.source != s } // a repeat moves to the end instead of doubling
        list.append(Turn(source: s, translation: t, from: from, to: to, at: now()))
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        turns[app] = list
    }

    /// Previous turns to use as context for `text`, or [] (long text, other app, last turn older than `window`).
    public func turns(for text: String, app: String?) -> [Turn] {
        guard let app, Self.wordCount(text) <= maxWords else { return [] }
        lock.lock(); defer { lock.unlock() }
        purge()
        // The same text again (e.g. copied a second time after the popup closed) is not its own context:
        // otherwise the prompt changes and the translation cache misses exactly in that case.
        let me = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let all = turns[app] else { return [] }
        let list = all.filter { $0.source != me }
        guard let last = list.last, now().timeIntervalSince(last.at) <= window else { return [] }
        return list
    }

    /// Ready text for `TranslationRequest.threadContext`; nil when there is no context.
    public func context(for text: String, app: String?) -> String? {
        let t = turns(for: text, app: app)
        return t.isEmpty ? nil : Self.render(t)
    }

    public func clear(app: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let app { turns[app] = nil } else { turns.removeAll() }
    }

    private func purge() {
        let cutoff = now().addingTimeInterval(-expiry)
        for (k, v) in turns {
            let kept = v.filter { $0.at >= cutoff }
            turns[k] = kept.isEmpty ? nil : kept
        }
    }

    public static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    /// «source ⇒ translation» lines, oldest first, each cut to 300 characters.
    public static func render(_ turns: [Turn]) -> String {
        turns.map { "\($0.source.prefix(300)) ⇒ \($0.translation.prefix(300))" }.joined(separator: "\n")
    }

    /// System-prompt section for a rendered context.
    static func promptSection(_ rendered: String) -> String {
        """
        # Earlier messages of this conversation (context only)
        The user translated these just before (source ⇒ translation). Use them ONLY to resolve pronouns, who or what is meant, gender, terms and form of address in the new text. Do NOT translate or repeat them: translate only the user's new text.
        \"\"\"
        \(rendered)
        \"\"\"
        """
    }
}
