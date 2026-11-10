// Autocomplete statistics: counters per day × model × app, a JSON store and a parser for the old tolk.log.
// Pure Foundation (no AppKit). PRIVACY: only numbers, bundle ids and model file names are kept — never any text.
import Foundation

/// Counters of one (day, model, app) cell. Latencies are a histogram (10 ms buckets) so cells can be merged
/// and a median still computed.
public struct ACBucket: Codable, Equatable, Sendable {
    public var shown = 0            // model suggestions shown
    public var shownWords = 0
    public var tabEvents = 0        // Tab presses that accepted a word
    public var tabWords = 0
    public var tabChars = 0
    public var allEvents = 0        // → presses that accepted everything
    public var allWords = 0
    public var allChars = 0
    public var instantShown = 0     // autocorrect / emoji
    public var instantAccepted = 0
    public var instantChars = 0
    public var typedOn = 0          // user kept typing (hidden reason=typed)
    public var esc = 0              // hidden with Esc
    public var latency: [Int: Int] = [:]   // bucket start (ms) → count
    /// Part of this cell was restored from tolk.log: words are estimated from characters.
    public var approx = false

    public init() {}

    public var acceptedEvents: Int { tabEvents + allEvents + instantAccepted }
    public var acceptedWords: Int { tabWords + allWords }
    public var insertedChars: Int { tabChars + allChars + instantChars }
    /// Key presses spent on accepting: one per Tab / → / instant Tab.
    public var acceptPresses: Int { acceptedEvents }
    public var savedKeystrokes: Int { max(0, insertedChars - acceptPresses) }
    /// Share of shown suggestions (model + instant) that were accepted, 0…1.
    public var acceptRate: Double {
        let s = shown + instantShown
        return s == 0 ? 0 : Double(acceptedEvents) / Double(s)
    }
    public var isEmpty: Bool { self == ACBucket() }

    public mutating func add(_ o: ACBucket) {
        shown += o.shown; shownWords += o.shownWords
        tabEvents += o.tabEvents; tabWords += o.tabWords; tabChars += o.tabChars
        allEvents += o.allEvents; allWords += o.allWords; allChars += o.allChars
        instantShown += o.instantShown; instantAccepted += o.instantAccepted; instantChars += o.instantChars
        typedOn += o.typedOn; esc += o.esc
        for (k, v) in o.latency { latency[k, default: 0] += v }
        approx = approx || o.approx
    }

    public mutating func addLatency(_ ms: Int) {
        latency[max(0, ms) / 10 * 10, default: 0] += 1
    }

    /// Median latency in ms (bucket midpoint), nil without data.
    public var medianLatency: Int? {
        let total = latency.values.reduce(0, +)
        guard total > 0 else { return nil }
        var seen = 0
        for k in latency.keys.sorted() {
            seen += latency[k]!
            if seen * 2 >= total { return k + 5 }
        }
        return nil
    }
}

public typealias ACDay = [String: [String: ACBucket]]   // model → app → bucket

public struct ACSummary: Equatable, Sendable {
    public var total = ACBucket()
    public var days = 0
}

public struct ACDayRow: Equatable, Sendable {
    public var day: String
    public var bucket: ACBucket
    public var models: [String]     // models seen that day, most used first
}

public struct ACRow: Equatable, Sendable {
    public var name: String
    public var bucket: ACBucket
}

/// Everything the statistics hold. Codable → autocomplete-stats.json.
public struct ACStatsData: Codable, Equatable, Sendable {
    public static let retentionDays = 365
    public var version = 1
    /// "yyyy-MM-dd" (local day) → model file name → bundle id → counters.
    public var days: [String: ACDay] = [:]
    /// True once the old tolk.log was imported (it is never read again).
    public var importedFromLog = false
    /// Last model seen by the importer, so a model change on the border of two imports is not lost.
    public init() {}

    // MARK: Adding

    public mutating func update(day: String, model: String, app: String, _ body: (inout ACBucket) -> Void) {
        var b = days[day]?[model]?[app] ?? ACBucket()
        body(&b)
        days[day, default: [:]][model, default: [:]][app] = b
    }

    /// Drops days older than the retention period.
    public mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        guard let cut = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) else { return }
        let key = ACStats.dayKey(cut, calendar: calendar)
        days = days.filter { $0.key >= key }
    }

    // MARK: Aggregation

    private func dayKeys(last n: Int?, now: Date, calendar: Calendar) -> [String] {
        guard let n else { return days.keys.sorted() }
        let start = calendar.date(byAdding: .day, value: -(n - 1), to: now) ?? now
        let from = ACStats.dayKey(start, calendar: calendar)
        let to = ACStats.dayKey(now, calendar: calendar)
        return days.keys.filter { $0 >= from && $0 <= to }.sorted()
    }

    /// `last` = nil → all time; 1 → today; 7, 30 → the last 7/30 calendar days including today.
    public func summary(last n: Int?, now: Date = Date(), calendar: Calendar = .current) -> ACSummary {
        var s = ACSummary()
        for k in dayKeys(last: n, now: now, calendar: calendar) {
            s.days += 1
            for (_, apps) in days[k]! { for (_, b) in apps { s.total.add(b) } }
        }
        return s
    }

    public func byModel(last n: Int? = nil, now: Date = Date(), calendar: Calendar = .current) -> [ACRow] {
        var m: [String: ACBucket] = [:]
        for k in dayKeys(last: n, now: now, calendar: calendar) {
            for (model, apps) in days[k]! { for (_, b) in apps { m[model, default: ACBucket()].add(b) } }
        }
        return m.map { ACRow(name: $0.key, bucket: $0.value) }
            .sorted { ($0.bucket.shown + $0.bucket.instantShown, $1.name) > ($1.bucket.shown + $1.bucket.instantShown, $0.name) }
    }

    public func byApp(last n: Int? = nil, now: Date = Date(), calendar: Calendar = .current) -> [ACRow] {
        var m: [String: ACBucket] = [:]
        for k in dayKeys(last: n, now: now, calendar: calendar) {
            for (_, apps) in days[k]! { for (app, b) in apps { m[app, default: ACBucket()].add(b) } }
        }
        return m.map { ACRow(name: $0.key, bucket: $0.value) }
            .sorted { ($0.bucket.acceptedEvents, $0.bucket.shown, $1.name) > ($1.bucket.acceptedEvents, $1.bucket.shown, $0.name) }
    }

    /// One row per day with any activity, oldest first.
    public func dayRows(last n: Int?, now: Date = Date(), calendar: Calendar = .current) -> [ACDayRow] {
        dayKeys(last: n, now: now, calendar: calendar).map { k in
            var total = ACBucket()
            var perModel: [String: Int] = [:]
            for (model, apps) in days[k]! {
                for (_, b) in apps { total.add(b); perModel[model, default: 0] += b.shown + b.instantShown + b.acceptedEvents }
            }
            return ACDayRow(day: k, bucket: total, models: perModel.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key))
        }
    }

    /// Days where the main model differs from the previous active day (day → new model).
    public func modelChanges(_ rows: [ACDayRow]) -> [String: String] {
        var out: [String: String] = [:]
        var prev: String?
        for r in rows {
            guard let m = r.models.first else { continue }
            if let p = prev, p != m { out[r.day] = m }
            prev = m
        }
        return out
    }

    public var isEmpty: Bool { days.isEmpty }
}

public enum ACStats {
    public static let unknownModel = "неизвестная модель"
    public static let unknownApp = "?"

    public static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Words in a piece of text (never stored; only the count is).
    public static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Words guessed from a length when the text is not known (old log lines): ~6 characters per word with a space.
    public static func estimateWords(chars: Int) -> Int { chars <= 0 ? 0 : max(1, Int((Double(chars) / 6).rounded())) }

    public static func shortModel(_ file: String) -> String {
        var s = file
        if s.hasSuffix(".gguf") { s.removeLast(5) }
        return s
    }

    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/Tolk/autocomplete-stats.json"
    }
    public static var defaultLogPath: String { NSHomeDirectory() + "/Library/Logs/Tolk/tolk.log" }

    // MARK: Old log

    /// Restores history from tolk.log lines. Unknown and broken lines are skipped. The model is the last
    /// `starting llama-server with X` line before an event; the app of accept/hide events is the app of the last
    /// shown suggestion (old lines do not carry it). Words are estimated from characters, so every cell is `approx`.
    public static func parseLog(_ lines: [String], calendar: Calendar = .current) -> ACStatsData {
        var data = ACStatsData()
        var model = unknownModel
        var lastApp = unknownApp, lastInstantApp = unknownApp
        let iso = ISO8601DateFormatter()
        func intAfter(_ key: String, in s: Substring) -> Int? {
            guard let r = s.range(of: key) else { return nil }
            let digits = s[r.upperBound...].prefix { $0.isNumber }
            return Int(digits)
        }
        func wordAfter(_ key: String, in s: Substring) -> String? {
            guard let r = s.range(of: key) else { return nil }
            let w = s[r.upperBound...].prefix { !$0.isWhitespace }
            return w.isEmpty ? nil : String(w)
        }
        for line in lines {
            guard let sp = line.firstIndex(of: " "), let date = iso.date(from: String(line[..<sp])) else { continue }
            let rest = line[line.index(after: sp)...]
            guard rest.hasPrefix("autocomplete: ") else { continue }
            let msg = rest.dropFirst("autocomplete: ".count)
            let day = dayKey(date, calendar: calendar)
            if msg.hasPrefix("starting llama-server with ") {
                let name = msg.dropFirst("starting llama-server with ".count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model = name }
            } else if msg.hasPrefix("shown ") {
                guard let len = intAfter("len=", in: msg), let ms = intAfter("ms=", in: msg) else { continue }
                lastApp = wordAfter("app=", in: msg) ?? unknownApp
                data.update(day: day, model: model, app: lastApp) { b in
                    b.shown += 1; b.shownWords += estimateWords(chars: len); b.addLatency(ms); b.approx = true
                }
            } else if msg.hasPrefix("accepted word ") {
                guard let len = intAfter("len=", in: msg) else { continue }
                data.update(day: day, model: model, app: lastApp) { b in
                    b.tabEvents += 1; b.tabWords += 1; b.tabChars += len; b.approx = true
                }
            } else if msg.hasPrefix("accepted all ") {
                guard let len = intAfter("len=", in: msg) else { continue }
                data.update(day: day, model: model, app: lastApp) { b in
                    b.allEvents += 1; b.allWords += estimateWords(chars: len); b.allChars += len; b.approx = true
                }
            } else if msg.hasPrefix("accepted instant ") {
                guard let len = intAfter("len=", in: msg) else { continue }
                data.update(day: day, model: model, app: lastInstantApp) { b in
                    b.instantAccepted += 1; b.instantChars += len; b.approx = true
                }
            } else if msg.hasPrefix("instant ") {
                lastInstantApp = wordAfter("app=", in: msg) ?? unknownApp
                data.update(day: day, model: model, app: lastInstantApp) { b in b.instantShown += 1; b.approx = true }
            } else if msg.hasPrefix("hidden reason=") {
                let reason = msg.dropFirst("hidden reason=".count).prefix { !$0.isWhitespace }
                if reason == "typed" {
                    data.update(day: day, model: model, app: lastApp) { b in b.typedOn += 1; b.approx = true }
                } else if reason == "esc" {
                    data.update(day: day, model: model, app: lastApp) { b in b.esc += 1; b.approx = true }
                }
            }
        }
        data.importedFromLog = true
        return data
    }

    /// Read-only load for the CLI: the JSON if there is one, else a parse of the log. Nothing is written.
    public static func loadReadOnly(path: String = defaultPath, logPath: String = defaultLogPath, calendar: Calendar = .current) -> ACStatsData {
        if let raw = FileManager.default.contents(atPath: path), let d = try? JSONDecoder().decode(ACStatsData.self, from: raw) { return d }
        if let text = try? String(contentsOfFile: logPath, encoding: .utf8) { return parseLog(text.components(separatedBy: "\n"), calendar: calendar) }
        return ACStatsData()
    }

    // MARK: Report (CLI)

    public static func report(_ d: ACStatsData, now: Date = Date(), calendar: Calendar = .current) -> String {
        var out: [String] = []
        if d.isEmpty { return "Статистики автодополнения пока нет." }
        func pct(_ x: Double) -> String { String(format: "%.0f %%", x * 100) }
        func line(_ title: String, _ s: ACSummary) -> String {
            let b = s.total
            let med = b.medianLatency.map { "\($0) мс" } ?? "—"
            return "\(title): показано \(b.shown + b.instantShown), принято \(b.acceptedEvents) (\(pct(b.acceptRate))), слов \(b.acceptedWords), " +
                "сэкономлено нажатий \(b.savedKeystrokes), задержка \(med)"
        }
        out.append("Сводка")
        out.append("  " + line("Сегодня", d.summary(last: 1, now: now, calendar: calendar)))
        out.append("  " + line("7 дней", d.summary(last: 7, now: now, calendar: calendar)))
        out.append("  " + line("30 дней", d.summary(last: 30, now: now, calendar: calendar)))
        out.append("  " + line("Всё время", d.summary(last: nil, now: now, calendar: calendar)))
        out.append("По дням (подсказки показано/принято Tab, → целиком; мгновенные показано/принято; печатал дальше; Esc; слов принято)")
        let rows = d.dayRows(last: nil, now: now, calendar: calendar)
        let changes = d.modelChanges(rows)
        for r in rows {
            let b = r.bucket
            let mark = b.approx ? " ~из лога, приблизительно" : ""
            let chg = changes[r.day].map { " ← модель: \(shortModel($0))" } ?? ""
            out.append("  \(r.day)  показано \(b.shown), слов \(b.shownWords); Tab \(b.tabEvents) (\(b.tabWords) сл., \(b.tabChars) зн.); " +
                "→ \(b.allEvents) (\(b.allWords) сл., \(b.allChars) зн.); мгновенные \(b.instantShown)/\(b.instantAccepted); " +
                "печатал дальше \(b.typedOn); Esc \(b.esc); принято всего \(b.acceptedEvents) (\(pct(b.acceptRate)))\(mark)\(chg)")
        }
        out.append("По моделям")
        for r in d.byModel(now: now, calendar: calendar) {
            let b = r.bucket
            out.append("  \(shortModel(r.name)): показано \(b.shown + b.instantShown), принято \(b.acceptedEvents) (\(pct(b.acceptRate))), " +
                "модельных показано \(b.shown), принято слов \(b.tabEvents + b.allEvents) (\(pct(b.shown == 0 ? 0 : Double(b.tabEvents + b.allEvents) / Double(b.shown))))")
        }
        out.append("Топ приложений")
        for r in d.byApp(now: now, calendar: calendar).prefix(5) {
            let b = r.bucket
            out.append("  \(r.name): показано \(b.shown + b.instantShown), принято \(b.acceptedEvents) (\(pct(b.acceptRate)))")
        }
        if rows.contains(where: { $0.bucket.approx }) {
            out.append("~ Дни «из лога»: слова оценены по символам (≈6 зн. на слово), приложение принятых — приложение последней показанной подсказки.")
        }
        return out.joined(separator: "\n")
    }

    /// «Сегодня: принято 17 слов (29 %)» for the menu; nil while there is nothing today.
    public static func menuLine(_ d: ACStatsData, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let b = d.summary(last: 1, now: now, calendar: calendar).total
        guard b.shown + b.instantShown > 0 else { return nil }
        return "Сегодня: принято \(b.acceptedWords) \(wordsForm(b.acceptedWords)) (\(Int((b.acceptRate * 100).rounded())) %)"
    }

    public static func wordsForm(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "слов" }
        switch m10 { case 1: return "слово"; case 2, 3, 4: return "слова"; default: return "слов" }
    }
}

/// The JSON file with write throttling (at most once per 30 s, plus `flush()` on quit). Not tied to AppKit.
public final class ACStatsStore: @unchecked Sendable {
    public static let shared = ACStatsStore()
    public static let writeInterval: TimeInterval = 30

    private let lock = NSLock()
    private var _data = ACStatsData()
    private let path: String
    private let logPath: String?
    private var dirty = false
    private var lastWrite = Date.distantPast
    private let calendar: Calendar

    public init(path: String = ACStats.defaultPath, logPath: String? = ACStats.defaultLogPath, calendar: Calendar = .current) {
        self.path = path
        self.logPath = logPath
        self.calendar = calendar
        load()
    }

    public var data: ACStatsData { lock.lock(); defer { lock.unlock() }; return _data }

    /// Reads the JSON; if the file does not exist yet, imports tolk.log once.
    private func load() {
        lock.lock(); defer { lock.unlock() }
        if let raw = FileManager.default.contents(atPath: path) {
            if let d = try? JSONDecoder().decode(ACStatsData.self, from: raw) {
                _data = d
                _data.prune(calendar: calendar)
            }
            // Broken file: start over, the next write replaces it.
            return
        }
        if let logPath, let text = try? String(contentsOfFile: logPath, encoding: .utf8) {
            _data = ACStats.parseLog(text.components(separatedBy: "\n"), calendar: calendar)
            _data.prune(calendar: calendar)
            dirty = true
            writeLocked(now: Date(), force: true)
        }
    }

    public func record(now: Date = Date(), model: String, app: String?, _ body: (inout ACBucket) -> Void) {
        let name = model.isEmpty ? ACStats.unknownModel : model
        lock.lock()
        _data.update(day: ACStats.dayKey(now, calendar: calendar), model: name, app: app ?? ACStats.unknownApp, body)
        dirty = true
        writeLocked(now: now, force: false)
        lock.unlock()
    }

    // Convenience recorders (numbers only; the text is dropped right here).
    public func shown(model: String, app: String?, text: String, ms: Int, now: Date = Date()) {
        let w = ACStats.wordCount(text)
        record(now: now, model: model, app: app) { $0.shown += 1; $0.shownWords += w; $0.addLatency(ms) }
    }
    public func acceptedWord(model: String, app: String?, word: String, now: Date = Date()) {
        let w = ACStats.wordCount(word), c = word.count
        record(now: now, model: model, app: app) { $0.tabEvents += 1; $0.tabWords += w; $0.tabChars += c }
    }
    public func acceptedAll(model: String, app: String?, text: String, now: Date = Date()) {
        let w = ACStats.wordCount(text), c = text.count
        record(now: now, model: model, app: app) { $0.allEvents += 1; $0.allWords += w; $0.allChars += c }
    }
    public func instantShown(model: String, app: String?, now: Date = Date()) {
        record(now: now, model: model, app: app) { $0.instantShown += 1 }
    }
    public func instantAccepted(model: String, app: String?, chars: Int, now: Date = Date()) {
        record(now: now, model: model, app: app) { $0.instantAccepted += 1; $0.instantChars += chars }
    }
    public func typedOn(model: String, app: String?, now: Date = Date()) { record(now: now, model: model, app: app) { $0.typedOn += 1 } }
    public func escaped(model: String, app: String?, now: Date = Date()) { record(now: now, model: model, app: app) { $0.esc += 1 } }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        _data = ACStatsData()
        _data.importedFromLog = true // an empty file stays; the log is not imported again
        dirty = true
        writeLocked(now: Date(), force: true)
    }

    /// Writes now if there is anything unsaved (quit, reset).
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        writeLocked(now: Date(), force: true)
    }

    private func writeLocked(now: Date, force: Bool) {
        guard dirty, force || now.timeIntervalSince(lastWrite) >= Self.writeInterval else { return }
        _data.prune(now: now, calendar: calendar)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let raw = try? enc.encode(_data) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? raw.write(to: url, options: .atomic)) != nil { dirty = false; lastWrite = now }
    }
}
