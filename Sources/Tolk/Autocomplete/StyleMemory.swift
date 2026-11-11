// Style memory: remembers the user's own sent messages / accepted sentences (opt-in) and
// offers a few similar earlier messages as style examples for the autocomplete prompt.
//
// Storage: ~/Library/Application Support/Tolk/style.db — one line per record, each line is
// base64(AES-GCM combined box) of a JSON record {t,a,d}. The 256-bit key lives in style.key (0600) next to it;
// an older key in the Keychain (service "local.vk.tolk.style") is moved there once. Last ~3000 records are kept.
// Logs contain counts and lengths only, never text.
import Foundation
import CryptoKit
import Security
import TolkCore

struct StyleRecord: Codable {
    var t: String      // text
    var a: String      // bundle id
    var d: Double      // unix time
}

/// Source of the AES key (Keychain in production, in-memory in the DEBUG self-test).
protocol StyleKeyStore: AnyObject, Sendable {
    func loadOrCreate() -> SymmetricKey?
    func delete()
}

final class KeychainKeyStore: StyleKeyStore, @unchecked Sendable {
    private let service = "local.vk.tolk.style"
    private let account = "key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func loadOrCreate() -> SymmetricKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 {
            return SymmetricKey(data: d)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
    }

    func delete() { SecItemDelete(query as CFDictionary) }

    /// Reads an existing key without creating one (nil = no item, or the user denied access).
    func loadExisting() -> SymmetricKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return nil }
        return SymmetricKey(data: d)
    }

    /// Is there an item at all (no data read → no access prompt)?
    var hasItem: Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
}

/// The key in a 0600 file next to style.db (`style.key`). Why not the Keychain: Tolk is signed with a self-made
/// certificate, and the Keychain ties «Always Allow» to the exact build, so every rebuild asked for the password
/// again. The file has the same protection as the rest of Tolk's data (history.jsonl is 0600 too).
/// Migration: an existing Keychain key is read once (one last prompt), written to the file and removed from the
/// Keychain. If that read is denied, the old key is kept untouched and nothing new is created — style.db stays
/// readable once access is allowed (before, a denied prompt silently replaced the key and lost the data).
final class FileKeyStore: StyleKeyStore, @unchecked Sendable {
    private let url: URL
    private let legacy = KeychainKeyStore()

    init(directory: URL) { url = directory.appendingPathComponent("style.key") }

    func loadOrCreate() -> SymmetricKey? {
        if let d = try? Data(contentsOf: url), d.count == 32 { return SymmetricKey(data: d) }
        if FileManager.default.fileExists(atPath: url.path) {
            // A key file that is there but not 32 bytes (truncated, being written): never replace it with a new key —
            // style.db would become undecryptable. Style memory stays paused instead.
            Diagnostics.log("style: style.key exists but is not a valid key — kept, style memory paused")
            return nil
        }
        if legacy.hasItem {
            guard let old = legacy.loadExisting() else {
                Diagnostics.log("style: keychain key not readable (access denied?) — kept, style memory paused")
                return nil
            }
            guard write(old) else { return nil }
            legacy.delete()
            Diagnostics.log("style: key moved from keychain to style.key")
            return old
        }
        let key = SymmetricKey(size: .bits256)
        return write(key) ? key : nil
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
        legacy.delete()
    }

    private func write(_ key: SymmetricKey) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}

@MainActor
final class StyleMemory {
    static let shared = StyleMemory()
    static let deleteAllNotification = Notification.Name("TolkStyleMemoryDeleteAll")

    nonisolated static let maxRecords = 3000
    static let minLength = 15
    static let maxLength = 1000
    static let maxExampleLength = 200

    // In-memory index entry.
    private struct Entry {
        let rec: StyleRecord
        let words: Set<String>
        let tris: Set<UInt32>
        let script: Script
    }
    enum Script { case latin, cyrillic, other }

    private var entries: [Entry] = []
    private var loaded = false
    private let url: URL
    private let keys: StyleKeyStore
    private let io = DispatchQueue(label: "tolk.stylememory")
    private nonisolated(unsafe) var ioKey: SymmetricKey?
    private nonisolated(unsafe) var ioCount = 0
    /// Bumped on every `configure`; closures from older configurations become pass-through.
    var generation = 0
    private var observer: NSObjectProtocol?

    init(url: URL? = nil, keys: StyleKeyStore? = nil) {
        let dbURL = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tolk/style.db")
        self.url = dbURL
        self.keys = keys ?? FileKeyStore(directory: dbURL.deletingLastPathComponent())
    }

    var count: Int { entries.count }

    // MARK: - Public API

    /// Starts loading from disk (idempotent).
    func load(completion: (@MainActor () -> Void)? = nil) {
        guard !loaded else { completion?(); return }
        loaded = true
        let url = url, keys = keys
        io.async { [self] in
            let (recs, bad) = readAll(url: url, keys: keys)
            DispatchQueue.main.async {
                // Records added before loading finished are already in `entries`; put the old ones first.
                let old = recs.map(Self.makeEntry)
                self.entries = Array((old + self.entries).suffix(Self.maxRecords))
                Diagnostics.log("style: loaded \(recs.count) records, unreadable \(bad)")
                completion?()
            }
        }
    }

    /// Texts of all records (for the word list of «Выбор слов»; kept in memory only).
    func allTexts() -> [String] { entries.map(\.rec.t) }

    func handle(_ a: AcceptedText, disabledApps: Set<String>, recordAll: Bool = true) {
        if let id = a.bundleID, disabledApps.contains(id) { return }
        let text: String
        switch a.kind {
        case .sent:
            guard AutocompleteTuning.recordSent(recordAll: recordAll, hadAccepted: a.hadAccepted) else { return }
            text = a.textBefore
        case .all: text = Self.lastSentence(of: a.textBefore + a.accepted)
        case .word: return
        }
        add(text: text, bundleID: a.bundleID ?? "")
    }

    func add(text raw: String, bundleID: String, date: Date = Date()) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minLength, text.count <= Self.maxLength else { return }
        guard !Self.looksSensitive(text) else {
            Diagnostics.log("style: skipped sensitive-looking text len=\(text.count)")
            return
        }
        if let last = entries.last, last.rec.t == text, last.rec.a == bundleID { return }
        let rec = StyleRecord(t: text, a: bundleID, d: date.timeIntervalSince1970)
        entries.append(Self.makeEntry(rec))
        if entries.count > Self.maxRecords + 300 { entries.removeFirst(entries.count - Self.maxRecords) }
        let url = url, keys = keys
        io.async { [self] in append(rec, url: url, keys: keys) }
        Diagnostics.log("style: saved len=\(text.count) total=\(entries.count)")
    }

    /// 2–3 earlier messages from the same app, similar to the text being typed, in the same script.
    func examples(for field: FocusedField, limit: Int = 3) -> [String] {
        guard !entries.isEmpty else { return [] }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let tail = String(field.textBefore.suffix(300))
        let script = Self.script(of: tail)
        let qWords = Self.words(tail)
        let qTris = Self.trigrams(tail)
        let app = field.bundleID ?? ""
        let tailTrim = tail.trimmingCharacters(in: .whitespacesAndNewlines)

        var scored: [(score: Double, idx: Int)] = []
        var recent: [Int] = []
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            let e = entries[i]
            guard e.rec.a == app else { continue }
            if script != .other, e.script != .other, e.script != script { continue }
            if e.rec.t == tailTrim { continue }
            if recent.count < limit { recent.append(i) }
            var s = 0.0
            if !qWords.isEmpty, !e.words.isEmpty {
                let inter = qWords.reduce(0) { $0 + (e.words.contains($1) ? 1 : 0) }
                s += 0.5 * Double(inter) / (Double(qWords.count) * Double(e.words.count)).squareRoot()
            }
            if !qTris.isEmpty, !e.tris.isEmpty {
                let inter = qTris.reduce(0) { $0 + (e.tris.contains($1) ? 1 : 0) }
                s += 0.5 * Double(inter) / (Double(qTris.count) * Double(e.tris.count)).squareRoot()
            }
            if s > 0.02 { scored.append((s, i)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.idx > $1.idx }
        var picked = scored.prefix(limit).map(\.idx)
        // Not enough similar ones: top up with the most recent from the same app.
        for i in recent where picked.count < limit && !picked.contains(i) { picked.append(i) }
        let out = picked.map { Self.snippet(entries[$0].rec.t) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        Diagnostics.debug("style: examples n=\(out.count) pool=\(entries.count) ms=\(String(format: "%.1f", ms))")
        return out
    }

    /// The user's own last messages in this app within `RecentMessages.window` (oldest first): «what I just said».
    func recent(for field: FocusedField, now: Date = Date()) -> [String] {
        let app = field.bundleID ?? ""
        let cutoff = now.timeIntervalSince1970 - RecentMessages.window
        var items: [RecentMessages.Item] = []
        for e in entries.reversed() {            // newest first; stop at the first record older than the window
            if e.rec.d < cutoff { break }
            if e.rec.a == app { items.append(.init(text: e.rec.t, app: app, at: Date(timeIntervalSince1970: e.rec.d))) }
            if items.count >= RecentMessages.limit + 2 { break }
        }
        return RecentMessages.select(items, app: app, now: now, typing: field.textBefore)
    }

    func deleteAll() {
        let url = url, keys = keys
        let n = entries.count
        entries = []
        io.async { [self] in
            try? FileManager.default.removeItem(at: url)
            keys.delete()
            ioKey = nil
            ioCount = 0
        }
        Diagnostics.log("style: deleted all (\(n) records in memory), file and key removed")
    }

    func observeDeleteAll() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: Self.deleteAllNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deleteAll() }
        }
    }

    // MARK: - Text helpers (pure)

    /// The last sentence of `s` (including the one that ends at the very end).
    static func lastSentence(of s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms: Set<Character> = [".", "!", "?", "…", "\n"]
        let chars = Array(t)
        guard !chars.isEmpty else { return "" }
        var end = chars.count - 1
        while end > 0, terms.contains(chars[end]) { end -= 1 }   // skip trailing terminators
        var start = 0
        var i = end
        while i >= 0 {
            if terms.contains(chars[i]) { start = i + 1; break }
            i -= 1
        }
        return String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heuristic: passwords, tokens, keys, card numbers.
    static func looksSensitive(_ s: String) -> Bool {
        let lower = s.lowercased()
        let markers = ["-----begin", "password", "passwd", "пароль", "пароля", "паролем", "api_key", "apikey", "api key", "secret", "секрет", "bearer ", " cvv", " cvc"]
        for m in markers where lower.contains(m) { return true }
        let prefixes = ["sk-", "ghp_", "gho_", "xoxb-", "xoxp-", "akia", "eyj"]
        for w in lower.split(whereSeparator: { $0.isWhitespace }) where w.count >= 16 {
            for p in prefixes where w.hasPrefix(p) { return true }
        }
        var digitRun = 0
        for ch in s {
            if ch.isNumber { digitRun += 1; if digitRun >= 13 { return true } }
            else if ch == " " || ch == "-" { continue }
            else { digitRun = 0 }
        }
        for w in s.split(whereSeparator: { $0.isWhitespace }) {
            let word = w.trimmingCharacters(in: .punctuationCharacters)
            if word.count >= 20 {
                let hasDigit = word.contains { $0.isNumber }
                let hasLetter = word.contains { $0.isLetter }
                if hasDigit && hasLetter { return true }
                if word.allSatisfy({ $0.isHexDigit }) { return true }
                if word.contains("://") == false, word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=_-".contains($0)) }),
                   word.contains(where: \.isUppercase), word.contains(where: \.isLowercase) { return true }
            }
        }
        return false
    }

    static func script(of s: String) -> Script {
        var lat = 0, cyr = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: lat += 1
            case 0x400...0x4FF: cyr += 1
            default: break
            }
        }
        if lat + cyr < 3 { return .other }
        return cyr >= lat ? .cyrillic : .latin
    }

    static func words(_ s: String) -> Set<String> {
        var out = Set<String>()
        for w in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where w.count >= 3 { out.insert(String(w)) }
        return out
    }

    static func trigrams(_ s: String) -> Set<UInt32> {
        let u = Array(s.lowercased().unicodeScalars.map { $0.properties.isAlphabetic || $0.properties.numericType != nil ? $0.value : 32 })
        guard u.count >= 3 else { return [] }
        var out = Set<UInt32>()
        out.reserveCapacity(u.count)
        for i in 0..<(u.count - 2) {
            if u[i] == 32 && u[i + 1] == 32 { continue }
            out.insert((u[i] &* 31 &+ u[i + 1]) &* 31 &+ u[i + 2])
        }
        return out
    }

    /// Text shortened to <= maxExampleLength at a sentence or word boundary.
    static func snippet(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        if t.count <= maxExampleLength { return t }
        let cut = String(t.prefix(maxExampleLength))
        let chars = Array(cut)
        if let i = chars.lastIndex(where: { ".!?…".contains($0) }), i >= 40 { return String(chars[...i]) }
        if let i = chars.lastIndex(of: " "), i >= 40 { return String(chars[..<i]) }
        return cut
    }

    private static func makeEntry(_ r: StyleRecord) -> Entry {
        Entry(rec: r, words: words(r.t), tris: trigrams(r.t), script: script(of: r.t))
    }

    // MARK: - Disk (called on the io queue only)

    private nonisolated func key(_ keys: StyleKeyStore) -> SymmetricKey? {
        if ioKey == nil { ioKey = keys.loadOrCreate() }
        return ioKey
    }

    private nonisolated func seal(_ rec: StyleRecord, key: SymmetricKey) -> String? {
        guard let json = try? JSONEncoder().encode(rec), let box = try? AES.GCM.seal(json, using: key), let c = box.combined else { return nil }
        return c.base64EncodedString()
    }

    private nonisolated func readAll(url: URL, keys: StyleKeyStore) -> ([StyleRecord], Int) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, let key = key(keys) else { return ([], 0) }
        var recs: [StyleRecord] = []
        var bad = 0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let raw = Data(base64Encoded: Data(line)),
                  let box = try? AES.GCM.SealedBox(combined: raw),
                  let plain = try? AES.GCM.open(box, using: key),
                  let rec = try? JSONDecoder().decode(StyleRecord.self, from: plain) else { bad += 1; continue }
            recs.append(rec)
        }
        ioCount = recs.count
        if recs.count > Self.maxRecords { rewrite(Array(recs.suffix(Self.maxRecords)), url: url, key: key) }
        return (Array(recs.suffix(Self.maxRecords)), bad)
    }

    private nonisolated func append(_ rec: StyleRecord, url: URL, keys: StyleKeyStore) {
        guard let key = key(keys), let line = seal(rec, key: key) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        }
        ioCount += 1
        if ioCount > Self.maxRecords + 300 {
            // Compact: keep only the newest records.
            let (recs, _) = readAllNoTrim(url: url, key: key)
            rewrite(Array(recs.suffix(Self.maxRecords)), url: url, key: key)
        }
    }

    private nonisolated func readAllNoTrim(url: URL, key: SymmetricKey) -> ([StyleRecord], Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        var recs: [StyleRecord] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let raw = Data(base64Encoded: Data(line)), let box = try? AES.GCM.SealedBox(combined: raw),
               let plain = try? AES.GCM.open(box, using: key), let rec = try? JSONDecoder().decode(StyleRecord.self, from: plain) {
                recs.append(rec)
            }
        }
        return (recs, 0)
    }

    private nonisolated func rewrite(_ recs: [StyleRecord], url: URL, key: SymmetricKey) {
        let body = recs.compactMap { seal($0, key: key) }.map { $0 + "\n" }.joined()
        let tmp = url.appendingPathExtension("tmp")
        do {
            try Data(body.utf8).write(to: tmp)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            ioCount = recs.count
            Diagnostics.log("style: compacted to \(recs.count) records")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Blocks until queued disk work is done (tests).
    func flush() { io.sync {} }
}

#if DEBUG
private final class MemoryKeyStore: StyleKeyStore, @unchecked Sendable {
    var key: SymmetricKey? = SymmetricKey(size: .bits256)
    func loadOrCreate() -> SymmetricKey? { key }
    func delete() { key = nil }
}

extension StyleMemory {
    /// DEBUG self-test: write/read/encryption round trip and example selection on 20 synthetic messages.
    /// Run with TOLK_STYLE_SELFTEST=1 (see AutocompleteFeatures). Returns failure descriptions.
    static func selfTest() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ m: String) { if !ok { fails.append(m) } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tolk-style-test-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryKeyStore()
        let m = StyleMemory(url: url, keys: keys)
        m.loaded = true

        let ru = [
            "Привет! Завтра созвонимся по поводу релиза, я пришлю ссылку на встречу.",
            "Сегодня не успею доделать отчёт, давай перенесём на понедельник?",
            "Спасибо за быстрый ответ, всё получилось как надо.",
            "Можешь посмотреть мой пулреквест, когда будет время?",
            "Купил билеты на поезд, выезжаем в пятницу вечером.",
            "Договорились, увидимся в офисе около десяти утра.",
            "Я поправил баг с авторизацией и залил фикс в основную ветку.",
            "Напомни, пожалуйста, во сколько начинается встреча с заказчиком.",
        ]
        let en = [
            "Hi John, thanks for the update. I will review the document tomorrow morning.",
            "Could you please send me the latest invoice for the March order?",
            "Sounds good, let's meet at the office around ten and go through the plan.",
            "I fixed the login bug and pushed the change to the main branch.",
            "Thanks a lot for your help, everything works as expected now.",
            "Let me know if the release call tomorrow still works for you.",
        ]
        let other = [
            "Це повідомлення із іншої програми, воно не має потрапити в підказки.",
            "This message belongs to another application and must not be suggested.",
        ]
        for t in ru + en { m.add(text: t, bundleID: "app.chat") }
        for t in other { m.add(text: t, bundleID: "app.mail") }
        // Rejected: too short, password-like, token-like, too long, card number.
        m.add(text: "ok", bundleID: "app.chat")
        m.add(text: "мой пароль от почты qwerty123", bundleID: "app.chat")
        m.add(text: "use this key sk-abcdefghijklmnop1234567890 now please", bundleID: "app.chat")
        m.add(text: "карта 4111 1111 1111 1111 если что", bundleID: "app.chat")
        m.add(text: String(repeating: "слово ", count: 300), bundleID: "app.chat")
        m.add(text: "the token is abcDEF123456ghiJKL789mnoPQR0 ok", bundleID: "app.chat")
        check(m.count == 16, "expected 16 stored records, got \(m.count)")
        m.add(text: other[1], bundleID: "app.mail")   // consecutive duplicate is ignored
        m.flush()

        // Encryption: not readable as text, no plaintext fragments, key is needed.
        let raw = (try? Data(contentsOf: url)) ?? Data()
        check(!raw.isEmpty, "file is empty")
        check(String(data: raw, encoding: .utf8)?.contains("релиз") != true && String(data: raw, encoding: .utf8)?.contains("invoice") != true,
              "plaintext found in file")
        check(raw.range(of: Data("релиз".utf8)) == nil, "utf8 plaintext bytes found in file")
        check(!raw.contains(where: { $0 == UInt8(ascii: "{") }), "JSON braces visible in file")
        let wrong = StyleMemory(url: url, keys: { let k = MemoryKeyStore(); return k }())
        let (bad, badCount) = wrong.io.sync { wrong.readAll(url: url, keys: wrong.keys) }
        check(bad.isEmpty && badCount > 0, "file decrypted with a wrong key")

        // Reload with the right key.
        let m2 = StyleMemory(url: url, keys: keys)
        let (recs, badN) = m2.io.sync { m2.readAll(url: url, keys: keys) }
        check(recs.count == 16 && badN == 0, "reload: \(recs.count) records, \(badN) bad")
        check(recs.first?.a == "app.chat" && recs.first?.t == ru[0], "reload: first record mismatch")
        m2.entries = recs.map(makeEntry)

        // Examples.
        func field(_ text: String, _ app: String) -> FocusedField {
            FocusedField(pid: 1, bundleID: app, textBefore: text, restOfLine: "", caret: .zero, caretInfo: "")
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var ex = m2.examples(for: field("Давай созвонимся завтра по релизу и обсудим", "app.chat"))
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        check(ex.count >= 2 && ex.count <= 3, "ru examples count \(ex.count)")
        check(ex.first == ru[0], "ru best example wrong: \(ex.first ?? "nil")")
        check(ex.allSatisfy { Self.script(of: $0) == .cyrillic }, "ru examples contain other script")
        check(ex.allSatisfy { $0.count <= maxExampleLength }, "example too long")
        check(ms < 5, "examples took \(ms) ms")
        ex = m2.examples(for: field("Could you send the invoice and I will review", "app.chat"))
        check(ex.first == en[1] || ex.first == en[0], "en best example wrong: \(ex.first ?? "nil")")
        check(ex.allSatisfy { Self.script(of: $0) == .latin }, "en examples contain cyrillic")
        ex = m2.examples(for: field("Привет, как дела", "app.mail"))
        check(ex.allSatisfy { $0 == other[0] }, "app isolation broken: \(ex)")
        check(m2.examples(for: field("Привет", "app.unknown")).isEmpty, "unknown app should have no examples")

        // Helpers.
        check(lastSentence(of: "Привет всем. Как у вас дела? Расскажите") == "Расскажите", "lastSentence 1")
        check(lastSentence(of: "Первое. Второе предложение целиком.") == "Второе предложение целиком.", "lastSentence 2")
        check(snippet(String(repeating: "слово ", count: 100)).count <= maxExampleLength, "snippet length")

        // Delete all.
        m2.deleteAll(); m2.flush()
        check(m2.count == 0 && !FileManager.default.fileExists(atPath: url.path) && keys.key == nil, "deleteAll left data")

        Diagnostics.log("style: selftest \(fails.isEmpty ? "PASSED" : "FAILED \(fails.count)") examples_ms=\(String(format: "%.2f", ms))")
        return fails
    }
}
#endif
