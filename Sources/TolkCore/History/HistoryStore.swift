// Local translation history — stored only on this Mac, never sent anywhere.
//
// File: `~/Library/Application Support/Tolk/history.jsonl`, one JSON entry per line (mode 0600).
// Appends are cheap; a line whose `id` repeats an earlier one REPLACES it (live typing updates the same entry).
// Removal, clearing and trimming rewrite the file atomically. At most `maxEntries` (3000) are kept.
import Foundation

public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    /// Where it came from: "popup", "reply", "quick", "page", "image", "document".
    public var origin: String
    /// Display name of the app the text came from, if known ("Telegram").
    public var app: String?
    public var source: String
    public var translation: String
    public var sourceLanguage: Language
    public var targetLanguage: Language
    public var provider: String
    public var mode: TextMode
    /// Bundle id of that app (for its icon), if known.
    public var appBundleID: String?

    public init(id: UUID = UUID(), date: Date = Date(), origin: String, app: String?, source: String, translation: String,
                sourceLanguage: Language, targetLanguage: Language, provider: String, mode: TextMode,
                appBundleID: String? = nil) {
        self.id = id; self.date = date; self.origin = origin; self.app = app; self.source = source
        self.translation = translation; self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage
        self.provider = provider; self.mode = mode; self.appBundleID = appBundleID
    }
}

public final class HistoryStore: @unchecked Sendable {
    /// Posted on the main queue after any change (entries or `isEnabled`).
    public static let didChange = Notification.Name("TolkHistoryDidChange")
    public static let defaultPath = "~/Library/Application Support/Tolk/history.jsonl"
    public static let enabledKey = "tolk.history.enabled"

    /// Junk filters used by `record(_:requestedAt:)`.
    public struct Policy: Sendable {
        /// Live typing: a new entry of the same origin within this window that edits the previous source replaces it.
        public var liveTypingWindow: TimeInterval = 30
        public var liveTypingOrigins: Set<String> = ["page", "reply"]
        /// Same source translated again (tone/language change) within this window replaces the previous entry.
        public var repeatWindow: TimeInterval = 60
        /// Back-translation (source == translation of the latest entry) within this window is not recorded.
        public var backTranslationWindow: TimeInterval = 60
        /// Long OCR text is translated in parts, one right after another: parts merge into one entry.
        public var chunkOrigins: Set<String> = ["image"]
        public var chunkGap: TimeInterval = 3
        public var minLength = 2
        public init() {}
    }

    public enum RecordResult: Equatable, Sendable {
        case added(UUID)
        case replaced(UUID)
        case skipped(String)
    }

    public let path: String
    public let maxEntries: Int
    public var policy = Policy()
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var loaded = false
    /// Newest first.
    private var entries: [HistoryEntry] = []
    /// Lines in the file (incl. superseded ones) — the file is compacted when it grows well past `entries`.
    private var fileLines = 0

    public init(path: String = HistoryStore.defaultPath, maxEntries: Int = 3000, defaults: UserDefaults = .standard) {
        self.path = expandPath(path)
        self.maxEntries = max(1, maxEntries)
        self.defaults = defaults
    }

    // MARK: - Settings

    /// Persisted in UserDefaults (`tolk.history.enabled`, default true). Off = nothing new is recorded.
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: Self.enabledKey)
            notify()
        }
    }

    // MARK: - Reading

    /// All entries, newest first.
    public func all() -> [HistoryEntry] { locked { entries } }

    public var count: Int { locked { entries.count } }

    public func entry(id: UUID) -> HistoryEntry? { locked { entries.first { $0.id == id } } }

    /// Entries whose source, translation or app contain every word of `query` (case- and diacritic-insensitive),
    /// newest first. Empty query = all.
    public func search(_ query: String) -> [HistoryEntry] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let list = all()
        guard !words.isEmpty else { return list }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return list.filter { e in
            words.allSatisfy { w in
                e.source.range(of: w, options: opts) != nil || e.translation.range(of: w, options: opts) != nil
                    || (e.app?.range(of: w, options: opts) != nil)
            }
        }
    }

    // MARK: - Writing

    /// Adds an entry as is (no junk filtering). Ignored while `isEnabled` is off.
    public func add(_ entry: HistoryEntry) {
        guard isEnabled else { return }
        locked { insert(entry) }
        notify()
    }

    /// Adds a finished translation, filtering junk (see `Policy`):
    /// too short → skipped; back-translation of the latest entry → skipped; same text again, live typing
    /// edits, OCR parts → the previous entry is replaced/extended instead of adding a new one.
    /// `requestedAt`: when the request started (for merging OCR parts); default = `entry.date`.
    @discardableResult
    public func record(_ entry: HistoryEntry, requestedAt: Date? = nil) -> RecordResult {
        guard isEnabled else { return .skipped("disabled") }
        let src = Self.normalized(entry.source), dst = Self.normalized(entry.translation)
        guard src.count >= policy.minLength, !dst.isEmpty else { return .skipped("too short") }
        let p = policy
        let result: RecordResult = locked {
            if let last = entries.first, entry.date.timeIntervalSince(last.date) <= p.backTranslationWindow,
               src == Self.normalized(last.translation) {
                return .skipped("back-translation")
            }
            // The same text re-opened elsewhere (popup «развернуть», «Открыть в переводе») within 10 min:
            // keep the first entry, don't add a duplicate from another origin.
            if entries.prefix(20).contains(where: { $0.origin != entry.origin && entry.date.timeIntervalSince($0.date) <= 600
                                                     && Self.normalized($0.source) == src }) {
                return .skipped("duplicate of a recent entry")
            }
            if let prev = entries.first(where: { $0.origin == entry.origin }) {
                let age = entry.date.timeIntervalSince(prev.date)
                var merged: HistoryEntry?
                if age <= p.repeatWindow, src == Self.normalized(prev.source) {
                    merged = entry
                } else if p.liveTypingOrigins.contains(entry.origin), age <= p.liveTypingWindow,
                          Self.isEdit(of: prev.source, to: entry.source) {
                    merged = entry
                } else if p.chunkOrigins.contains(entry.origin),
                          (requestedAt ?? entry.date).timeIntervalSince(prev.date) <= p.chunkGap,
                          prev.targetLanguage == entry.targetLanguage {
                    var m = entry
                    m.source = prev.source + "\n\n" + entry.source
                    m.translation = prev.translation + "\n\n" + entry.translation
                    m.sourceLanguage = prev.sourceLanguage
                    m.app = prev.app; m.appBundleID = prev.appBundleID
                    merged = m
                }
                if var m = merged {
                    m.id = prev.id
                    entries.removeAll { $0.id == prev.id }
                    insert(m)
                    return .replaced(prev.id)
                }
            }
            insert(entry)
            return .added(entry.id)
        }
        notify()
        return result
    }

    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let changed: Bool = locked {
            let before = entries.count
            entries.removeAll { ids.contains($0.id) }
            guard entries.count != before else { return false }
            rewrite()
            return true
        }
        if changed { notify() }
    }

    /// Deletes every entry and the file itself.
    public func clear() {
        locked {
            ensureLoaded()
            entries = []
            fileLines = 0
            try? FileManager.default.removeItem(atPath: path)
        }
        notify()
    }

    // MARK: - Text helpers (public for tests)

    static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when `new` looks like the same text being typed/edited: one is a prefix of the other, or they
    /// share a long common prefix + suffix (≥ 60 % of the shorter text and ≥ 4 characters).
    public static func isEdit(of old: String, to new: String) -> Bool {
        let a = Array(normalized(old)), b = Array(normalized(new))
        let shorter = min(a.count, b.count)
        guard shorter > 0 else { return false }
        var p = 0
        while p < shorter, a[p] == b[p] { p += 1 }
        if p == shorter { return true }
        var s = 0
        while s < shorter - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let common = p + s
        return common >= 4 && Double(common) >= 0.6 * Double(shorter)
    }

    // MARK: - Private (call with the lock held)

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return body()
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: HistoryStore.didChange, object: self) }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let dec = Self.decoder()
        var byID: [UUID: HistoryEntry] = [:]
        var lines = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            lines += 1
            if let e = try? dec.decode(HistoryEntry.self, from: Data(line)) { byID[e.id] = e }
        }
        entries = byID.values.sorted { $0.date > $1.date }
        fileLines = lines
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        if fileLines > entries.count + compactionSlack { rewrite() }
    }

    private var compactionSlack: Int { max(50, maxEntries / 10) }

    private func insert(_ entry: HistoryEntry) {
        var entry = entry
        entry.date = Self.date(milliseconds: Self.milliseconds(entry.date))
        // Newest first; entries normally arrive in order, so this is O(1) in practice.
        let i = entries.firstIndex { $0.date <= entry.date } ?? entries.count
        entries.insert(entry, at: i)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        if fileLines + 1 > entries.count + compactionSlack { rewrite(); return }
        append(entry)
    }

    private func append(_ entry: HistoryEntry) {
        guard var line = try? Self.encoder().encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            createDirectory()
            fm.createFile(atPath: path, contents: line, attributes: [.posixPermissions: 0o600])
            fileLines = 1
            return
        }
        guard let h = FileHandle(forWritingAtPath: path) else { rewrite(); return }
        defer { try? h.close() }
        do {
            let end = try h.seekToEnd()
            if end > 0 {
                // A crash mid-append can leave a last line without "\n": don't glue the new entry to it.
                try h.seek(toOffset: end - 1)
                if try h.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) { line.insert(UInt8(ascii: "\n"), at: 0) }
                try h.seekToEnd()
            }
            try h.write(contentsOf: line)
            fileLines += 1
        } catch { rewrite() }
    }

    /// Writes `entries` (oldest first) atomically.
    private func rewrite() {
        let enc = Self.encoder()
        var data = Data()
        for e in entries.reversed() {
            guard let line = try? enc.encode(e) else { continue }
            data.append(line); data.append(UInt8(ascii: "\n"))
        }
        createDirectory()
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            fileLines = entries.count
        } catch {
            NSLog("Tolk history: cannot write \(path): \(error)")
        }
    }

    private func createDirectory() {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
    }

    /// Dates are stored as whole milliseconds; in-memory entries are rounded the same way, so a reload is identical.
    private static func milliseconds(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(milliseconds ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(milliseconds(d))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let ms = try? c.decode(Int64.self) { return date(milliseconds: ms) }
            let d = try c.decode(Double.self).rounded()
            guard let ms = Int64(exactly: d) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "date out of range") } // a corrupt line is skipped, not a crash
            return date(milliseconds: ms)
        }
        return d
    }
}
