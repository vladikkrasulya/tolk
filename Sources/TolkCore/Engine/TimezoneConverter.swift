// Time with a time zone in a text -> the user's local time. No model, no network.
//
// API: `TimezoneConverter.convert(in: text, now:, localZone:) -> [TimezoneConversion]`.
// Each result: `found` (the text as written), `range` (NSRange in the text), `local` (e.g. "17:00–18:00" or
// "02:00 (завтра)" or "13 нояб, 02:00"), `ambiguous` + `note` for zones that must not be guessed (IST, CST, BST, AST),
// `display` («found → local» or «found → неоднозначный пояс …») ready for a hint line, `sameAsLocal`.
// Rules: PT/ET/CT/MT/CET/EET/МСК-style «region» names follow daylight saving on the given date; EST/EDT/PST/…/CEST are
// taken literally (fixed offsets); UTC±N / GMT±N are fixed. No explicit date → today (in the source zone, relative to `now`).
import Foundation

public struct TimezoneConversion: Sendable, Equatable {
    public let found: String
    public let range: NSRange
    public let local: String
    public let ambiguous: Bool
    public let note: String?
    public let sameAsLocal: Bool
    public var display: String {
        ambiguous ? "\(found) → \(note ?? "неоднозначный пояс")" : "\(found) → \(local)"
    }
}

public enum TimezoneConverter {
    private enum Zone {
        case region(String)     // follows daylight saving
        case fixed(Int)         // seconds from GMT
        case ambiguous(String)  // note
    }

    private static let abbreviations: [String: Zone] = [
        "UTC": .fixed(0), "GMT": .fixed(0), "Z": .fixed(0),
        "EST": .fixed(-5 * 3600), "EDT": .fixed(-4 * 3600), "CDT": .fixed(-5 * 3600),
        "MST": .fixed(-7 * 3600), "MDT": .fixed(-6 * 3600), "PST": .fixed(-8 * 3600), "PDT": .fixed(-7 * 3600),
        "AKST": .fixed(-9 * 3600), "HST": .fixed(-10 * 3600),
        "ET": .region("America/New_York"), "CT": .region("America/Chicago"),
        "MT": .region("America/Denver"), "PT": .region("America/Los_Angeles"),
        "CET": .region("Europe/Paris"), "CEST": .fixed(2 * 3600), "EET": .region("Europe/Kyiv"), "EEST": .fixed(3 * 3600),
        "WET": .region("Europe/Lisbon"), "MSK": .region("Europe/Moscow"), "МСК": .region("Europe/Moscow"),
        "JST": .fixed(9 * 3600), "KST": .fixed(9 * 3600), "SGT": .fixed(8 * 3600), "HKT": .fixed(8 * 3600),
        "AEST": .fixed(10 * 3600), "AEDT": .fixed(11 * 3600),
        "IST": .ambiguous("IST — неоднозначный пояс (Индия / Израиль / Ирландия), пропущено"),
        "CST": .ambiguous("CST — неоднозначный пояс (США Central / Китай / Куба), пропущено"),
        "BST": .ambiguous("BST — неоднозначный пояс (Британия летом / Бангладеш), пропущено"),
        "AST": .ambiguous("AST — неоднозначный пояс (Атлантика / Саудовская Аравия), пропущено"),
    ]
    private static let phrases: [(String, String)] = [
        ("киеву", "Europe/Kyiv"), ("киевскому\\s+времени", "Europe/Kyiv"), ("київським\\s+часом", "Europe/Kyiv"), ("києву", "Europe/Kyiv"),
        ("москве", "Europe/Moscow"), ("московскому\\s+времени", "Europe/Moscow"), ("мск", "Europe/Moscow"),
        ("лондону", "Europe/London"), ("берлину", "Europe/Berlin"), ("варшаве", "Europe/Warsaw"), ("парижу", "Europe/Paris"),
        ("нью-йорку", "America/New_York"), ("лос-анджелесу", "America/Los_Angeles"),
    ]

    private static let timePart = "([0-9]{1,2})(?:[:.]([0-9]{2}))?\\s*([ap]\\.?m\\.?)?"
    private static let zonePart: String = {
        let abbr = abbreviations.keys.filter { $0 != "Z" && $0 != "UTC" && $0 != "GMT" }.sorted { $0.count > $1.count }.joined(separator: "|")
        let ph = phrases.map { $0.0 }.joined(separator: "|")
        return "(?:(?:UTC|GMT)(?:\\s?[+\\-−]\\s?[0-9]{1,2}(?::?[0-9]{2})?)?|\(abbr)|по\\s+(?:\(ph)))"
    }()
    private static let regex = try! NSRegularExpression(
        pattern: "(?<![\\w:.])(?:(в|at|@|к|from|с)\\s+)?\(timePart)(?:\\s*(?:[-–—]|to|до)\\s*\(timePart))?\\s*(\(zonePart))(?![\\p{L}0-9])",
        options: [.caseInsensitive])

    private static let monthNames: [(String, Int)] = [
        ("jan(?:uary)?|січ(?:ня)?|янв(?:аря)?", 1), ("feb(?:ruary)?|лют(?:ого)?|фев(?:раля)?", 2), ("mar(?:ch)?|берез(?:ня)?|мар(?:та)?", 3),
        ("apr(?:il)?|квіт(?:ня)?|апр(?:еля)?", 4), ("may|трав(?:ня)?|ма[яй]", 5), ("jun(?:e)?|черв(?:ня)?|июн(?:я)?", 6),
        ("jul(?:y)?|лип(?:ня)?|июл(?:я)?", 7), ("aug(?:ust)?|серп(?:ня)?|авг(?:уста)?", 8), ("sep(?:t(?:ember)?)?|вер(?:есня)?|сен(?:тября)?", 9),
        ("oct(?:ober)?|жовт(?:ня)?|окт(?:ября)?", 10), ("nov(?:ember)?|листоп(?:ада)?|ноя(?:бря)?", 11), ("dec(?:ember)?|груд(?:ня)?|дек(?:абря)?", 12),
    ]
    private static let monthAlt = monthNames.map { "(?:\($0.0))" }.joined(separator: "|")
    private static let dateRegexes: [NSRegularExpression] = [
        "([0-9]{4})-([0-9]{2})-([0-9]{2})",
        "(?<![0-9.])([0-9]{1,2})\\.([0-9]{1,2})(?:\\.([0-9]{2,4}))?(?![0-9:])",
        "([0-9]{1,2})(?:st|nd|rd|th)?\\s+(\(monthAlt))\\p{L}*\\.?(?:\\s+([0-9]{4}))?",
        "(\(monthAlt))\\p{L}*\\.?\\s+([0-9]{1,2})(?:st|nd|rd|th)?(?:,?\\s+([0-9]{4}))?",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func month(_ s: String) -> Int? {
        let l = s.lowercased()
        for (p, n) in monthNames where l.range(of: "^(?:\(p))", options: .regularExpression) != nil { return n }
        return nil
    }

    /// Dates written in the text: (range, y?, m, d).
    private static func dates(in text: String) -> [(NSRange, Int?, Int, Int)] {
        let ns = text as NSString
        var out: [(NSRange, Int?, Int, Int)] = []
        let full = NSRange(location: 0, length: ns.length)
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        for (i, re) in dateRegexes.enumerated() {
            for m in re.matches(in: text, range: full) {
                switch i {
                case 0: if let y = Int(g(m, 1)!), let mo = Int(g(m, 2)!), let d = Int(g(m, 3)!) { out.append((m.range, y, mo, d)) }
                case 1:
                    if let d = Int(g(m, 1)!), let mo = Int(g(m, 2)!), (1...31).contains(d), (1...12).contains(mo) {
                        var y = g(m, 3).flatMap { Int($0) }; if let yy = y, yy < 100 { y = 2000 + yy }
                        out.append((m.range, y, mo, d))
                    }
                case 2: if let d = Int(g(m, 1)!), let mo = month(g(m, 2)!) { out.append((m.range, g(m, 3).flatMap { Int($0) }, mo, d)) }
                default: if let mo = month(g(m, 1)!), let d = Int(g(m, 2)!) { out.append((m.range, g(m, 3).flatMap { Int($0) }, mo, d)) }
                }
            }
        }
        return out
    }

    private static func zone(from token: String) -> Zone? {
        let t = token.trimmingCharacters(in: .whitespaces)
        let up = t.uppercased()
        if up.hasPrefix("UTC") || up.hasPrefix("GMT") {
            let rest = String(up.dropFirst(3)).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "−", with: "-")
            if rest.isEmpty { return .fixed(0) }
            guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
            let digits = rest.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let v = Int(digits) else { return nil }
            let (h, m) = digits.count <= 2 ? (v, 0) : (v / 100, v % 100)
            guard h <= 14, m < 60 else { return nil }
            return .fixed((sign == "-" ? -1 : 1) * (h * 3600 + m * 60))
        }
        if up.hasPrefix("ПО") {
            let tail = t.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
            for (p, id) in phrases where tail.range(of: "^(?:\(p))$", options: .regularExpression) != nil { return .region(id) }
            return nil
        }
        return abbreviations[up] ?? abbreviations[t]
    }

    public static func convert(in text: String, now: Date = Date(), localZone: TimeZone = .current) -> [TimezoneConversion] {
        let ns = text as NSString
        let found = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !found.isEmpty else { return [] }
        let dateList = dates(in: text)
        var out: [TimezoneConversion] = []
        for m in found {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            let prefix = g(1)
            let ap1 = g(4)?.lowercased().replacingOccurrences(of: ".", with: ""), ap2 = g(7)?.lowercased().replacingOccurrences(of: ".", with: "")
            let hasRange = g(5) != nil
            let min1 = g(3), min2 = g(6)
            // A bare number («14 UTC», «at 3 CET») needs a hint that it is a time: am/pm, minutes, a range or «в/at».
            let h1raw = Int(g(2)!)!
            if min1 == nil, ap1 == nil, ap2 == nil, !hasRange, prefix == nil { continue }
            guard let zone = zone(from: g(8)!) else { continue }
            // The «в / at» hint is not part of the found text.
            let r = NSRange(location: m.range(at: 2).location, length: m.range.location + m.range.length - m.range(at: 2).location)
            let foundText = ns.substring(with: r)
            if case let .ambiguous(note) = zone {
                out.append(TimezoneConversion(found: foundText, range: r, local: "", ambiguous: true, note: note, sameAsLocal: false))
                continue
            }
            func hour24(_ h: Int, _ ap: String?) -> Int? {
                if let ap {
                    guard (1...12).contains(h) else { return nil }
                    return ap.hasPrefix("p") ? (h == 12 ? 12 : h + 12) : (h == 12 ? 0 : h)
                }
                return (0...24).contains(h) ? h : nil
            }
            var effAP1 = ap1
            if ap1 == nil, let ap2, hasRange, let h2 = Int(g(5)!), h1raw <= 12 {
                // «10–11 AM»: the first inherits the second's am/pm unless it would run backwards («11–1 PM» -> 11 AM).
                let a = hour24(h1raw, ap2), b = hour24(h2, ap2)
                effAP1 = (a != nil && b != nil && a! > b!) ? "am" : ap2
            }
            let mi1 = min1.flatMap { Int($0) } ?? 0
            guard let h1 = hour24(h1raw, effAP1), mi1 < 60 else { continue }
            var endH: Int?, endM = 0
            if hasRange {
                guard let h2raw = g(5).flatMap({ Int($0) }), let h2 = hour24(h2raw, ap2 ?? effAP1) else { continue }
                endH = h2; endM = min2.flatMap { Int($0) } ?? 0
                guard endM < 60 else { continue }
            }
            // Time zone object for the date.
            var date: (y: Int?, m: Int, d: Int)?
            let nearest = dateList.filter {
                let r = $0.0
                // A date separated from this time by another time-with-zone belongs to that one.
                let lo = min(r.location, m.range.location), hi = max(r.location + r.length, m.range.location + m.range.length)
                func gap(_ a: NSRange) -> Int { r.location >= a.location + a.length ? r.location - (a.location + a.length) : max(0, a.location - (r.location + r.length)) }
                if let owner = found.min(by: { gap($0.range) < gap($1.range) }), owner.range != m.range { return false }
                if found.contains(where: { $0.range != m.range && $0.range.location >= lo && $0.range.location + $0.range.length <= hi }) { return false }
                if r.location + r.length <= m.range.location { return m.range.location - (r.location + r.length) <= 30 }
                if r.location >= m.range.location + m.range.length { return r.location - (m.range.location + m.range.length) <= 30 }
                return false
            }.min { abs($0.0.location - m.range.location) < abs($1.0.location - m.range.location) }
            if let nearest { date = (nearest.1, nearest.2, nearest.3) }

            func tz(on comps: DateComponents) -> TimeZone? {
                switch zone {
                case let .fixed(s): return TimeZone(secondsFromGMT: s)
                case let .region(id): return TimeZone(identifier: id)
                case .ambiguous: return nil
                }
            }
            guard let srcZone = tz(on: DateComponents()) else { continue }
            var srcCal = Calendar(identifier: .gregorian); srcCal.timeZone = srcZone
            var locCal = Calendar(identifier: .gregorian); locCal.timeZone = localZone
            let today = srcCal.dateComponents([.year, .month, .day], from: now)
            var y = date?.y ?? today.year!, mo = date?.m ?? today.month!, d = date?.d ?? today.day!
            if let date, date.y == nil {
                // No year written: the nearest such date, not more than ~6 months in the past.
                var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = 12
                if let dd = srcCal.date(from: c), dd.timeIntervalSince(now) < -180 * 86400 { y += 1 }
            }
            func instant(_ h: Int, _ mi: Int) -> Date? {
                var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h == 24 ? 0 : h; c.minute = mi
                guard let base = srcCal.date(from: c), srcCal.component(.month, from: base) == mo else { return nil }
                return h == 24 ? srcCal.date(byAdding: .day, value: 1, to: base) : base
            }
            guard let start = instant(h1, mi1) else { continue }
            let end = endH.flatMap { instant($0, endM) }
            let local = formatLocal(start: start, end: end, srcCal: srcCal, locCal: locCal, localZone: localZone, explicitDate: date != nil)
            out.append(TimezoneConversion(found: foundText, range: r, local: local, ambiguous: false, note: nil,
                                          sameAsLocal: srcZone.secondsFromGMT(for: start) == localZone.secondsFromGMT(for: start)))
        }
        return out
    }

    private static func formatLocal(start: Date, end: Date?, srcCal: Calendar, locCal: Calendar, localZone: TimeZone, explicitDate: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU"); f.timeZone = localZone; f.dateFormat = "HH:mm"
        var s = f.string(from: start)
        if let end { s += "–" + f.string(from: end) }
        let srcDay = srcCal.dateComponents([.year, .month, .day], from: start)
        let locDay = locCal.dateComponents([.year, .month, .day], from: start)
        var shift = 0
        if srcCal.date(from: srcDay) != nil, locCal.date(from: locDay) != nil {
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            var ac = utc.dateComponents([.year, .month, .day], from: Date()); ac.year = srcDay.year; ac.month = srcDay.month; ac.day = srcDay.day
            var bc = ac; bc.year = locDay.year; bc.month = locDay.month; bc.day = locDay.day
            if let da = utc.date(from: ac), let db = utc.date(from: bc) { shift = utc.dateComponents([.day], from: da, to: db).day ?? 0 }
        }
        if explicitDate {
            var lc = Calendar(identifier: .gregorian); lc.timeZone = localZone
            let c = lc.dateComponents([.month, .day], from: start)
            let names = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "нояб", "дек"]
            return "\(c.day!) \(names[c.month! - 1]), " + s
        }
        switch shift {
        case 0: break
        case 1: s += " (завтра)"
        case -1: s += " (вчера)"
        default: s += " (\(shift > 0 ? "+" : "")\(shift) дн.)"
        }
        return s
    }
}

/// «10:00 EST → 16:00 у вас»: one line per found time for the windows (popup line, hints panel). Only certain
/// conversions: ambiguous zones («CST», «IST») and times that equal the local time are not shown.
public enum TimezoneLine {
    public static func lines(for conversions: [TimezoneConversion], limit: Int = 3) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for c in conversions where !c.ambiguous && !c.sameAsLocal {
            let line = "\(c.found) → \(c.local) у вас"
            if seen.insert(line).inserted { out.append(line) }
        }
        return Array(out.prefix(limit))
    }

    public static func lines(in text: String, now: Date = Date(), localZone: TimeZone = .current, limit: Int = 3) -> [String] {
        // Cheap guard: a time needs a digit — most texts have none, skip the regexes.
        guard text.contains(where: \.isNumber) else { return [] }
        return lines(for: TimezoneConverter.convert(in: text, now: now, localZone: localZone), limit: limit)
    }
}
