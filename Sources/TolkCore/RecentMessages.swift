// «Что я писал только что»: the user's last few own messages in the same app (last ~15 minutes) go into the
// autocomplete prompt as context, so the suggestion knows what the user is already saying / answering.
// Pure selection and rendering (no AppKit); the records come from StyleMemory (opt-in style learning).
import Foundation

public enum RecentMessages {
    public static let window: TimeInterval = 15 * 60
    public static let limit = 3
    public static let maxChars = 200

    public struct Item: Equatable {
        public var text: String
        public var app: String
        public var at: Date
        public init(text: String, app: String, at: Date) { self.text = text; self.app = app; self.at = at }
    }

    /// Up to `limit` messages of `app` from the last `window` seconds, oldest first, each cut to `maxChars`.
    /// The text being typed right now is not its own context (a just-sent message that is typed again).
    public static func select(_ items: [Item], app: String, now: Date, typing: String = "",
                              window: TimeInterval = RecentMessages.window, limit: Int = RecentMessages.limit) -> [String] {
        let me = typing.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var out: [String] = []
        for it in items.sorted(by: { $0.at > $1.at }) where it.app == app {
            let age = now.timeIntervalSince(it.at)
            guard age >= -5, age <= window else { continue }
            let t = it.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            guard !t.isEmpty, t != me, seen.insert(t).inserted else { continue }
            out.append(t.count > maxChars ? String(t.prefix(maxChars)) + "…" : t)
            if out.count >= limit { break }
        }
        return out.reversed()
    }

    /// Prompt block with a blank line after it; "" when there are no messages.
    public static func block(_ messages: [String]) -> String {
        let m = messages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !m.isEmpty else { return "" }
        return "My previous messages in this chat (just now, oldest first; the new message continues the same conversation):\n"
            + m.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
    }
}

extension SelfTest {
    static func recentMessages(_ check: Check) {
        typealias R = RecentMessages
        let now = Date(timeIntervalSince1970: 1_000_000)
        func item(_ t: String, _ app: String, _ ago: TimeInterval) -> R.Item { .init(text: t, app: app, at: now.addingTimeInterval(-ago)) }
        let items = [item("old one from yesterday", "a", 90_000), item("first", "a", 600), item("other app", "b", 60),
                     item("second", "a", 300), item("third", "a", 120), item("fourth", "a", 30), item("second", "a", 20)]
        let r = R.select(items, app: "a", now: now)
        check(r == ["third", "fourth", "second"], "recent: last 3 of the app, oldest first, deduped")
        check(!r.contains("other app") && !r.contains("old one from yesterday"), "recent: other app and stale are left out")
        check(R.select(items, app: "a", now: now, typing: " fourth ").contains("fourth") == false, "recent: typed text is not its own context")
        check(R.select(items, app: "c", now: now).isEmpty, "recent: unknown app has none")
        check(R.select(items, app: "a", now: now, window: 100) == ["fourth", "second"], "recent: window cuts older")
        check(R.select([item(String(repeating: "x", count: 500), "a", 1)], app: "a", now: now)[0].count == R.maxChars + 1, "recent: long message is cut")
        check(R.select([item("a\nb", "a", 1)], app: "a", now: now) == ["a b"], "recent: newlines flattened")
        check(R.block([]) == "" && R.block(["  "]) == "", "recent: empty block is empty")
        let b = R.block(["hi there", "ok"])
        check(b.hasPrefix("My previous messages") && b.hasSuffix("- hi there\n- ok\n\n"), "recent: block format")
    }
}
