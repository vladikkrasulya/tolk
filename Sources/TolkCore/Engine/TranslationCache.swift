import Foundation
import CryptoKit

/// In-memory LRU cache with a time limit. Thread-safe; nothing is ever written to disk (message texts are private).
/// Keys are SHA-256 digests of everything that affects the result, so no source text is kept in the keys.
public final class ResultCache<Value: Sendable>: @unchecked Sendable {
    public static var defaultMaxEntries: Int { 200 }
    public static var defaultMaxBytes: Int { 2_000_000 }
    public static var defaultTTL: TimeInterval { 24 * 3600 }

    private struct Entry { var value: Value; var cost: Int; var storedAt: Date; var tick: UInt64 }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var tick: UInt64 = 0
    private let maxEntries: Int, maxBytes: Int, ttl: TimeInterval
    private let now: @Sendable () -> Date

    public init(maxEntries: Int = ResultCache.defaultMaxEntries, maxBytes: Int = ResultCache.defaultMaxBytes,
                ttl: TimeInterval = ResultCache.defaultTTL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxEntries = maxEntries; self.maxBytes = maxBytes; self.ttl = ttl; self.now = now
    }

    public var count: Int { lock.withLock { entries.count } }

    public func get(_ key: String) -> Value? {
        lock.withLock {
            guard var e = entries[key] else { return nil }
            if now().timeIntervalSince(e.storedAt) > ttl { bytes -= e.cost; entries[key] = nil; return nil }
            tick += 1; e.tick = tick; entries[key] = e
            return e.value
        }
    }

    /// `cost` = approximate size in bytes (the text length). A single value bigger than the whole budget is not stored.
    public func set(_ key: String, _ value: Value, cost: Int) {
        lock.withLock {
            guard cost <= maxBytes else { return }
            if let old = entries[key] { bytes -= old.cost }
            tick += 1
            entries[key] = Entry(value: value, cost: cost, storedAt: now(), tick: tick)
            bytes += cost
            let t = now()
            for (k, e) in entries where t.timeIntervalSince(e.storedAt) > ttl { bytes -= e.cost; entries[k] = nil }
            while entries.count > maxEntries || bytes > maxBytes,
                  let oldest = entries.min(by: { $0.value.tick < $1.value.tick }) {
                bytes -= oldest.value.cost; entries[oldest.key] = nil
            }
        }
    }

    public func removeAll() { lock.withLock { entries = [:]; bytes = 0 } }
}

/// A finished translation of the main model, kept to answer an identical request without the model.
struct CachedTranslation: Sendable {
    var text: String
    var provider: String
    var route: TranslationStats.Route
    var warnings: [String]
    var outputTokens: Int?
}

enum TranslationCacheKey {
    /// Line endings and edge whitespace only: case and inner spaces change the translation and stay.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func digest(_ parts: [String]) -> String {
        var h = SHA256()
        for p in parts {
            // Length prefix: ("ab","c") and ("a","bc") must not collide.
            h.update(data: Data("\(p.utf8.count):".utf8)); h.update(data: Data(p.utf8))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `systemPrompt` already holds the rules/glossary block, languages, tone, reply and continuation text;
    /// the rest is repeated explicitly so that nothing depends on the prompt's wording.
    static func translation(_ r: ResolvedRequest, systemPrompt: String, identity: String) -> String {
        digest(["tr", normalize(r.text), r.source.rawValue, r.target.rawValue, r.tone.rawValue, "\(r.mode)",
                r.replyTo.map(normalize) ?? "-", r.context?.source ?? "-", r.context?.translation ?? "-",
                identity, systemPrompt])
    }

    static func notes(source: String, translation: String, from: Language, to: Language, rules: String, identity: String) -> String {
        digest(["notes", normalize(source), normalize(translation), from.rawValue, to.rawValue, identity, rules])
    }
}
