// Usage statistics of the translator and the reasons a suggestion did not appear: counters per day.
// Pure Foundation. PRIVACY: only numbers, origins, language pairs, provider names and app names — never any text.
//
// File: ~/Library/Application Support/Tolk/usage-stats.json. Kept for a year.
import Foundation

/// Counters of one local day.
public struct UsageDay: Codable, Equatable, Sendable {
    public var translations = 0
    public var chars = 0                    // characters of source text
    public var cached = 0                   // answered from the cache
    public var fallback = 0                 // the spare translator answered (Google / Apple)
    public var failed = 0                   // ended with an error
    public var byOrigin: [String: Int] = [:]    // popup, reply, quick, page, image, document, type
    public var byPair: [String: Int] = [:]      // "ru→en"
    public var byProvider: [String: Int] = [:]
    public var byApp: [String: Int] = [:]       // app display name
    public var latency: [Int: Int] = [:]        // total time, 100 ms buckets (cache hits excluded)
    public var firstChunk: [Int: Int] = [:]     // time to the first words, 100 ms buckets
    /// Why autocomplete stayed silent: reason key → times.
    public var acMisses: [String: Int] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case translations, chars, cached, fallback, failed, byOrigin, byPair, byProvider, byApp, latency, firstChunk, acMisses
    }

    /// Every key is optional, so a file written by an older version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ k: CodingKeys) -> Int { ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) ?? 0 }
        func map(_ k: CodingKeys) -> [String: Int] { ((try? c.decodeIfPresent([String: Int].self, forKey: k)) ?? nil) ?? [:] }
        func hist(_ k: CodingKeys) -> [Int: Int] { ((try? c.decodeIfPresent([Int: Int].self, forKey: k)) ?? nil) ?? [:] }
        translations = int(.translations); chars = int(.chars); cached = int(.cached); fallback = int(.fallback); failed = int(.failed)
        byOrigin = map(.byOrigin); byPair = map(.byPair); byProvider = map(.byProvider); byApp = map(.byApp)
        latency = hist(.latency); firstChunk = hist(.firstChunk); acMisses = map(.acMisses)
    }

    public mutating func add(_ o: UsageDay) {
        translations += o.translations; chars += o.chars; cached += o.cached; fallback += o.fallback; failed += o.failed
        for (k, v) in o.byOrigin { byOrigin[k, default: 0] += v }
        for (k, v) in o.byPair { byPair[k, default: 0] += v }
        for (k, v) in o.byProvider { byProvider[k, default: 0] += v }
        for (k, v) in o.byApp { byApp[k, default: 0] += v }
        for (k, v) in o.latency { latency[k, default: 0] += v }
        for (k, v) in o.firstChunk { firstChunk[k, default: 0] += v }
        for (k, v) in o.acMisses { acMisses[k, default: 0] += v }
    }

    public static func median(_ h: [Int: Int], bucket: Int = 100) -> Int? {
        let total = h.values.reduce(0, +)
        guard total > 0 else { return nil }
        var seen = 0
        for k in h.keys.sorted() {
            seen += h[k]!
            if seen * 2 >= total { return k + bucket / 2 }
        }
        return nil
    }

    /// Median time of a finished translation, ms (nil without data).
    public var medianLatency: Int? { Self.median(latency) }
    public var medianFirstChunk: Int? { Self.median(firstChunk) }
    public var isEmpty: Bool { self == UsageDay() }
}

/// One finished (or failed) translation, as the statistics see it.
public struct UsageEvent: Sendable, Equatable {
    public var origin: String
    public var pair: String
    public var provider: String
    public var app: String?
    public var chars: Int
    public var totalMs: Int?
    public var firstChunkMs: Int?
    public var cached = false
    public var fallback = false
    public var failed = false

    public init(origin: String, pair: String = "", provider: String = "", app: String? = nil, chars: Int = 0,
                totalMs: Int? = nil, firstChunkMs: Int? = nil, cached: Bool = false, fallback: Bool = false, failed: Bool = false) {
        self.origin = origin; self.pair = pair; self.provider = provider; self.app = app; self.chars = chars
        self.totalMs = totalMs; self.firstChunkMs = firstChunkMs; self.cached = cached; self.fallback = fallback; self.failed = failed
    }
}

public struct UsageData: Codable, Equatable, Sendable {
    public static let retentionDays = 365
    public var version = 1
    /// "yyyy-MM-dd" (local day) → counters.
    public var days: [String: UsageDay] = [:]
    /// True once the translation history was counted in (it is never read again).
    public var importedHistory = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, days, importedHistory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
        days = ((try? c.decodeIfPresent([String: UsageDay].self, forKey: .days)) ?? nil) ?? [:]
        importedHistory = ((try? c.decodeIfPresent(Bool.self, forKey: .importedHistory)) ?? nil) ?? false
    }

    public mutating func record(_ e: UsageEvent, day: String) {
        var d = days[day] ?? UsageDay()
        if e.failed {
            d.failed += 1
        } else {
            d.translations += 1
            d.chars += e.chars
            if e.cached { d.cached += 1 }
            if e.fallback { d.fallback += 1 }
            d.byOrigin[e.origin, default: 0] += 1
            if !e.pair.isEmpty { d.byPair[e.pair, default: 0] += 1 }
            if !e.provider.isEmpty { d.byProvider[e.provider, default: 0] += 1 }
            if let a = e.app, !a.isEmpty { d.byApp[a, default: 0] += 1 }
            if !e.cached, let ms = e.totalMs { d.latency[max(0, ms) / 100 * 100, default: 0] += 1 }
            if !e.cached, let ms = e.firstChunkMs { d.firstChunk[max(0, ms) / 100 * 100, default: 0] += 1 }
        }
        days[day] = d
    }

    public mutating func recordMiss(_ reason: String, day: String) {
        days[day, default: UsageDay()].acMisses[reason, default: 0] += 1
    }

    public mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        guard let cut = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) else { return }
        let key = ACStats.dayKey(cut, calendar: calendar)
        days = days.filter { $0.key >= key }
    }

    /// `last` = nil → all time; 1 → today; 7, 30 → the last 7/30 calendar days including today.
    public func total(last n: Int?, now: Date = Date(), calendar: Calendar = .current) -> UsageDay {
        var out = UsageDay()
        for (k, d) in days where Self.inRange(k, last: n, now: now, calendar: calendar) { out.add(d) }
        return out
    }

    static func inRange(_ key: String, last n: Int?, now: Date, calendar: Calendar) -> Bool {
        guard let n else { return true }
        let start = calendar.date(byAdding: .day, value: -(n - 1), to: now) ?? now
        return key >= ACStats.dayKey(start, calendar: calendar) && key <= ACStats.dayKey(now, calendar: calendar)
    }

    /// Translations per day for the last `count` days, oldest first (days without activity = 0).
    public func series(days count: Int, now: Date = Date(), calendar: Calendar = .current) -> [(day: String, value: Int)] {
        (0..<count).map { i in
            let key = ACStats.dayKey(calendar.date(byAdding: .day, value: i - (count - 1), to: now) ?? now, calendar: calendar)
            return (key, days[key]?.translations ?? 0)
        }
    }

    public var isEmpty: Bool { days.values.allSatisfy(\.isEmpty) }
}

public enum UsageText {
    /// Russian names of the places a translation starts from.
    public static func origin(_ key: String) -> String {
        switch key {
        case "popup": "Двойное ⌘C"
        case "reply": "Ответ собеседнику"
        case "quick": "Быстрые действия"
        case "page": "Окно Tolk"
        case "image": "Фото и скриншоты"
        case "document": "Документы"
        case "type": "Перевод при наборе"
        default: key
        }
    }

    /// Russian explanation of why no suggestion appeared.
    public static func miss(_ key: String) -> String {
        switch key {
        case "unsure": "Модель не уверена в продолжении"
        case "nothing": "Модель ничего не предложила"
        case "short": "Мало текста или начало строки"
        case "unread": "Программа не отдала текст поля"
        case "moved": "Текст или фокус изменились, пока модель думала"
        case "esc": "Пауза после Esc"
        case "type-translate": "Работает «Перевод при наборе»"
        case "not-ready": "Модель ещё загружается или не запущена"
        case "secure": "Поле для пароля"
        case "small-field": "Поле поиска, адреса или слишком маленькое"
        case "not-inserted": "Нажали Tab, но поле изменилось — подсказка не вставлена"
        default: key
        }
    }

    /// What the user can do about it (nil = nothing to do, this is how it works).
    public static func missAdvice(_ key: String) -> String? {
        switch key {
        case "unsure": "Чаще показывать: «Частота подсказок → Чаще» и «Показывать после паузы»."
        case "unread": "Включите «Контекст со снимка экрана» и разрешение «Запись экрана»."
        case "not-ready": "Проверьте вкладку «Модели»: модель должна быть скачана и выбрана."
        case "esc": "Пауза снимается после Tab, Enter или перехода в другое поле."
        default: nil
        }
    }

    /// Log reason (see `AutocompleteController.skip`) → key of `miss`.
    public static func missKey(forSkipReason r: String) -> String {
        if r.hasPrefix("too little") { return "short" }
        if r.hasPrefix("field not read") { return "unread" }
        if r.hasPrefix("field changed") || r.hasPrefix("focus moved") { return "moved" }
        if r.hasPrefix("paused by Esc") { return "esc" }
        if r.hasPrefix("«Перевод при наборе»") { return "type-translate" }
        if r.hasPrefix("model not ready") { return "not-ready" }
        if r.hasPrefix("secure") { return "secure" }
        return r
    }

    public static func ms(_ v: Int?) -> String {
        guard let v else { return "—" }
        return v >= 1000 ? String(format: "%.1f с", Double(v) / 1000).replacingOccurrences(of: ".", with: ",") : "\(v) мс"
    }

    /// 12 345 → «12 345», 1 250 000 → «1,3 млн».
    public static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f млн", Double(n) / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        var s = String(n), out = ""
        while s.count > 3 { out = " " + s.suffix(3) + out; s.removeLast(3) }
        return s + out
    }

    /// Bytes → «3,4 ГБ» / «512 МБ» / «14 КБ».
    public static func bytes(_ n: Int64) -> String {
        let d = Double(n)
        func f(_ v: Double, _ unit: String, _ digits: Int) -> String {
            String(format: "%.\(digits)f %@", v, unit).replacingOccurrences(of: ".", with: ",")
        }
        if d >= 1e9 { return f(d / 1e9, "ГБ", 1) }
        if d >= 1e6 { return f(d / 1e6, "МБ", 0) }
        if d >= 1e3 { return f(d / 1e3, "КБ", 0) }
        return "\(n) Б"
    }
}

/// Thread-safe store of `UsageData` with a debounced save.
public final class UsageStore: @unchecked Sendable {
    public static let shared = UsageStore()
    public static var defaultPath: String { NSHomeDirectory() + "/Library/Application Support/Tolk/usage-stats.json" }
    public static let didChange = Notification.Name("TolkUsageStatsDidChange")

    private let path: String
    private let lock = NSLock()
    private var value = UsageData()
    private var loaded = false
    private var dirty = false
    private var saveScheduled = false
    private let queue = DispatchQueue(label: "tolk.usage", qos: .utility)

    public init(path: String = UsageStore.defaultPath) { self.path = path }

    public var data: UsageData {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return value
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let raw = FileManager.default.contents(atPath: path), let d = try? JSONDecoder().decode(UsageData.self, from: raw) { value = d }
        value.prune()
    }

    public func record(_ e: UsageEvent, at date: Date = Date()) {
        mutate { $0.record(e, day: ACStats.dayKey(date)) }
    }

    public func recordMiss(_ reason: String, at date: Date = Date()) {
        mutate { $0.recordMiss(reason, day: ACStats.dayKey(date)) }
    }

    /// One-time: count the translations already in the history (no timings there).
    public func importHistoryIfNeeded(_ entries: [HistoryEntry]) {
        mutate { d in
            guard !d.importedHistory else { return }
            d.importedHistory = true
            for e in entries {
                d.record(UsageEvent(origin: e.origin, pair: "\(e.sourceLanguage.rawValue)→\(e.targetLanguage.rawValue)", provider: e.provider,
                                    app: e.app, chars: e.source.count), day: ACStats.dayKey(e.date))
            }
        }
    }

    public func reset() {
        mutate { d in let imported = d.importedHistory; d = UsageData(); d.importedHistory = imported }
        flush()
    }

    private func mutate(_ body: (inout UsageData) -> Void) {
        lock.lock()
        loadIfNeeded()
        body(&value)
        dirty = true
        let schedule = !saveScheduled
        saveScheduled = true
        lock.unlock()
        if schedule { queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.flush() } }
    }

    /// Writes now (also called on quit).
    public func flush() {
        lock.lock()
        saveScheduled = false
        guard dirty else { lock.unlock(); return }
        dirty = false
        let snapshot = value
        lock.unlock()
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

extension SelfTest {
    static func usageStats(_ check: Check) {
        var d = UsageData()
        d.record(UsageEvent(origin: "popup", pair: "en→ru", provider: "Gemma", app: "Slack", chars: 120, totalMs: 840, firstChunkMs: 310), day: "2026-11-10")
        d.record(UsageEvent(origin: "popup", pair: "en→ru", provider: "Gemma", chars: 40, totalMs: 3, cached: true), day: "2026-11-10")
        d.record(UsageEvent(origin: "reply", pair: "ru→en", provider: "Google", chars: 60, totalMs: 1250, fallback: true), day: "2026-11-11")
        d.record(UsageEvent(origin: "page", failed: true), day: "2026-11-11")
        d.recordMiss("unsure", day: "2026-11-11"); d.recordMiss("unsure", day: "2026-11-11"); d.recordMiss("short", day: "2026-11-11")
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        let all = d.total(last: nil, now: now, calendar: cal), today = d.total(last: 1, now: now, calendar: cal)
        check(all.translations == 3 && all.chars == 220 && all.cached == 1 && all.fallback == 1 && all.failed == 1, "usage: totals", "\(all)")
        check(today.translations == 1 && today.failed == 1 && today.byOrigin == ["reply": 1], "usage: today only")
        check(all.byOrigin["popup"] == 2 && all.byPair["en→ru"] == 2 && all.byApp == ["Slack": 1], "usage: breakdowns")
        check(all.medianLatency == 850 && all.latency.values.reduce(0, +) == 2, "usage: cache hits are not timed", "\(all.latency)")
        check(all.acMisses == ["unsure": 2, "short": 1], "usage: autocomplete misses")
        let s = d.series(days: 3, now: now, calendar: cal)
        check(s.map(\.value) == [0, 2, 1] && s.last?.day == "2026-11-11", "usage: series by day", "\(s)")
        // An old file without the new keys still loads.
        let old = #"{"days":{"2026-11-01":{"translations":4}},"version":1}"#
        let loaded = try? JSONDecoder().decode(UsageData.self, from: Data(old.utf8))
        check(loaded?.days["2026-11-01"]?.translations == 4 && loaded?.days["2026-11-01"]?.acMisses.isEmpty == true, "usage: old file loads")
        if let round = try? JSONDecoder().decode(UsageData.self, from: JSONEncoder().encode(d)) { check(round == d, "usage: round trip") } else { check(false, "usage: round trip") }
        check(UsageText.missKey(forSkipReason: "too little text or line start") == "short" && UsageText.missKey(forSkipReason: "field not read after the answer") == "unread"
              && UsageText.missKey(forSkipReason: "model not ready (starting)") == "not-ready", "usage: skip reason keys")
        check(AutocompleteSafety.tailShape("ab1. я") == "6:[L L 9 U+002E U+0020 L]" && AutocompleteSafety.tailShape("") == "0:[]", "usage: tail shape hides the text",
              AutocompleteSafety.tailShape("ab1. я"))
        check(UsageText.ms(840) == "840 мс" && UsageText.ms(1300) == "1,3 с" && UsageText.ms(nil) == "—", "usage: time text")
        check(UsageText.count(12345) == "12 345" && UsageText.count(999) == "999" && UsageText.bytes(3_416_118_240) == "3,4 ГБ" && UsageText.bytes(512_000_000) == "512 МБ", "usage: number text",
              "\(UsageText.count(12345)) \(UsageText.bytes(3_416_118_240))")
        var pruned = d
        pruned.days["2024-01-01"] = UsageDay()
        pruned.prune(now: now, calendar: cal)
        check(pruned.days["2024-01-01"] == nil && pruned.days.count == 2, "usage: prune after a year")
        check(AutocompleteTuning.patientThresholds(frequency: "often", enabled: false) == nil && AutocompleteTuning.patientDelayMs(seconds: 1) == 1000
              && AutocompleteTuning.patientDelayMs(seconds: 99) == 3000, "usage: patient switch and delay")
        var custom = TolkConfig()
        custom.autocompleteFrequency = "rare"; custom.autocompleteCustomConfidence = true
        custom.autocompleteFirstProb = 0.2; custom.autocompleteNextProb = 0.6
        let own = AutocompleteTuning.thresholds(config: custom, frequency: "rare")
        check(own.first == 0.2 && own.next == 0.2, "tuning: own bars replace the preset, later words never above the first", "\(own)")
        custom.autocompleteCustomConfidence = false
        check(AutocompleteTuning.thresholds(config: custom, frequency: "rare").first == 0.6, "tuning: preset when own bars are off")
        check(AutocompleteTuning.patientThresholds(frequency: "often", first: 0.15)?.first == 0.15 && AutocompleteTuning.patientThresholds(frequency: "rare", first: 0.15) == nil,
              "tuning: patient bar from settings")
        check(AutocompleteTuning.expectedAccuracy(firstBar: 0.3) == 53 && AutocompleteTuning.expectedAccuracy(firstBar: 0.6) == 63
              && AutocompleteTuning.expectedAccuracy(firstBar: 0.05) == 50 && AutocompleteTuning.expectedAccuracy(firstBar: 0.95) == 70, "tuning: expected accuracy curve")
        let tuned = try? JSONDecoder().decode(TolkConfig.self, from: Data(#"{"translateTemperature": 7, "autocompleteContextSize": 5000, "autocompleteMinChars": 99, "autocompleteFirstProb": 0}"#.utf8))
        check(tuned?.translateTemperature == 1 && tuned?.autocompleteContextSize == 4096 && tuned?.autocompleteMinChars == 20 && tuned?.autocompleteFirstProb == 0.05
              && tuned?.translateFixedSeed == true && tuned?.translateCache == true, "tuning: fine-tuning keys are clamped and default")
        let hot = OllamaProvider(config: { var c = TolkConfig(); c.translateTemperature = 0.4; c.translateFixedSeed = false; return c }(), rules: RulesStore(path: "/nonexistent/rules.md"))
        if let req = try? hot.makeChatRequest(system: "s", user: "u"), let body = req.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            check(json["temperature"] as? Double == 0.4 && json["seed"] == nil, "tuning: translation request uses the settings", "\(json["temperature"] ?? "-")")
        } else { check(false, "tuning: translation request uses the settings") }
        check(Array(Language.allCases.prefix(4)) == Language.main && Language.main == [.ukrainian, .english, .russian, .polish]
              && Language.others.count == Language.allCases.count - 4 && !Language.others.contains(.polish), "languages: the four main ones lead every list")
        let cfg = try? JSONDecoder().decode(TolkConfig.self, from: Data(#"{"autocompletePatientDelay": 50, "keepWarmMinutes": -3}"#.utf8))
        check(cfg?.autocompletePatientDelay == 3 && cfg?.keepWarmMinutes == 0 && cfg?.autocompletePatient == true && cfg?.verboseLog == false, "usage: new config keys are clamped and default")
    }
}
