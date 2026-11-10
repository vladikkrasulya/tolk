// Checks for AutocompleteStats.swift: counting, aggregation, log import, retention, store. Files only in a temp dir.
import Foundation

extension SelfTest {
    static func acStats(_ check: Check) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-06
        func day(_ off: Int) -> String { ACStats.dayKey(cal.date(byAdding: .day, value: off, to: now)!, calendar: cal) }

        // Counting.
        var b = ACBucket()
        b.tabEvents = 3; b.tabWords = 3; b.tabChars = 15
        b.allEvents = 1; b.allWords = 4; b.allChars = 24
        b.instantAccepted = 1; b.instantChars = 2
        b.shown = 10; b.instantShown = 2
        check(b.acceptedEvents == 5 && b.acceptedWords == 7, "acstats: accepted events/words")
        check(b.insertedChars == 41 && b.savedKeystrokes == 36, "acstats: saved keystrokes = chars - accept presses", "\(b.savedKeystrokes)")
        check(abs(b.acceptRate - 5.0 / 12) < 1e-9, "acstats: accept rate over shown model+instant")
        check(ACBucket().acceptRate == 0 && ACBucket().savedKeystrokes == 0 && ACBucket().medianLatency == nil, "acstats: empty bucket safe")
        var l = ACBucket()
        for ms in [100, 200, 210, 220, 900] { l.addLatency(ms) }
        check(l.medianLatency == 215, "acstats: median latency from histogram", "\(String(describing: l.medianLatency))")
        check(ACStats.wordCount("  привет  мир\nтут ") == 3 && ACStats.wordCount("") == 0, "acstats: word count")
        check(ACStats.estimateWords(chars: 0) == 0 && ACStats.estimateWords(chars: 2) == 1 && ACStats.estimateWords(chars: 30) == 5, "acstats: word estimate")
        check(ACStats.wordsForm(1) == "слово" && ACStats.wordsForm(17) == "слов" && ACStats.wordsForm(22) == "слова" && ACStats.wordsForm(11) == "слов", "acstats: Russian plural")

        // Aggregation by day / model / app.
        var d = ACStatsData()
        d.update(day: day(0), model: "A.gguf", app: "x") { $0.shown = 4; $0.tabEvents = 1; $0.tabWords = 1; $0.tabChars = 6 }
        d.update(day: day(0), model: "B.gguf", app: "y") { $0.shown = 6; $0.tabEvents = 2; $0.tabWords = 2; $0.tabChars = 10; $0.addLatency(300) }
        d.update(day: day(-3), model: "A.gguf", app: "x") { $0.shown = 10; $0.allEvents = 1; $0.allWords = 3; $0.allChars = 18 }
        d.update(day: day(-20), model: "A.gguf", app: "z") { $0.shown = 20 }
        check(d.summary(last: 1, now: now, calendar: cal).total.shown == 10, "acstats: today")
        check(d.summary(last: 7, now: now, calendar: cal).total.shown == 20, "acstats: 7 days")
        check(d.summary(last: 30, now: now, calendar: cal).total.shown == 40, "acstats: 30 days")
        check(d.summary(last: nil, now: now, calendar: cal).days == 3, "acstats: all time, days with data")
        let models = d.byModel(now: now, calendar: cal)
        check(models.map(\.name) == ["A.gguf", "B.gguf"] && models[0].bucket.shown == 34, "acstats: by model", "\(models.map(\.name))")
        let apps = d.byApp(now: now, calendar: cal)
        check(apps.first?.name == "x" && apps.count == 3, "acstats: by app sorted by accepted")
        let rows = d.dayRows(last: nil, now: now, calendar: cal)
        check(rows.count == 3 && rows[0].day == day(-20) && rows[2].models == ["B.gguf", "A.gguf"], "acstats: day rows, oldest first")
        check(d.modelChanges(rows) == [day(0): "B.gguf"], "acstats: model change marked on the first day of the new model")

        // Retention.
        var old = ACStatsData()
        old.update(day: day(-400), model: "A", app: "x") { $0.shown = 1 }
        old.update(day: day(-364), model: "A", app: "x") { $0.shown = 1 }
        old.update(day: day(0), model: "A", app: "x") { $0.shown = 1 }
        old.prune(now: now, calendar: cal)
        check(old.days.count == 2 && old.days[day(-400)] == nil, "acstats: older than 365 days dropped")

        // Log parsing: known, unknown, broken lines.
        let log = [
            "2026-11-09T10:00:00Z launch dev (-), args: --background",
            "2026-11-09T10:00:01Z autocomplete: shown len=12 ms=212 ctx=5 app=com.x fs=15/10",   // before any model line
            "2026-11-09T10:00:02Z autocomplete: starting llama-server with m1.gguf",
            "2026-11-09T10:00:03Z autocomplete: shown len=12 ms=200 ctx=5 app=com.a fs=15/10",
            "2026-11-09T10:00:04Z autocomplete: accepted word len=4",
            "2026-11-09T10:00:05Z autocomplete: shown len=30 ms=400 ctx=5 app=com.b fs=15/10",
            "2026-11-09T10:00:06Z autocomplete: accepted all len=30",
            "2026-11-09T10:00:07Z autocomplete: hidden reason=typed",
            "2026-11-09T10:00:08Z autocomplete: hidden reason=esc",
            "2026-11-09T10:00:09Z autocomplete: hidden reason=key",
            "2026-11-09T10:00:10Z autocomplete: instant replace=2 app=com.c",
            "2026-11-09T10:00:11Z autocomplete: accepted instant replace=2 len=1",
            "2026-11-09T10:00:12Z autocomplete: shown len=abc ms=1 app=q",          // broken number
            "2026-11-09T10:00:13Z autocomplete: accepted word",                      // no len
            "autocomplete: shown len=5 ms=5 app=zzz",                                // no timestamp
            "garbage",
            "",
            "2026-11-09T10:00:14Z autocomplete: something new len=7",               // unknown event
            "2026-11-10T09:00:00Z autocomplete: starting llama-server with m2.gguf",
            "2026-11-10T09:00:01Z autocomplete: shown len=6 ms=100 ctx=0 app=com.a fs=-/10",
        ]
        let p = ACStats.parseLog(log, calendar: cal)
        let d9 = p.summary(last: nil, calendar: cal)
        check(p.importedFromLog && d9.days == 2, "acstats log: two days")
        check(p.days["2026-11-09"]?["m1.gguf"]?["com.a"]?.shown == 1, "acstats log: model = last 'starting' line")
        check(p.days["2026-11-09"]?[ACStats.unknownModel]?["com.x"]?.shown == 1, "acstats log: event before any model line → unknown model")
        let m1 = p.byModel(calendar: cal).first { $0.name == "m1.gguf" }?.bucket ?? ACBucket()
        check(m1.shown == 2 && m1.tabEvents == 1 && m1.tabWords == 1 && m1.tabChars == 4, "acstats log: shown / accepted word")
        check(m1.allEvents == 1 && m1.allWords == 5 && m1.allChars == 30, "acstats log: accepted all, words estimated from chars")
        check(m1.typedOn == 1 && m1.esc == 1, "acstats log: typed / esc, other hide reasons ignored")
        check(m1.instantShown == 1 && m1.instantAccepted == 1 && m1.instantChars == 1, "acstats log: instant")
        check(p.days["2026-11-09"]?["m1.gguf"]?["com.b"]?.allEvents == 1, "acstats log: accept attributed to the app of the last shown")
        check(p.days["2026-11-09"]?["m1.gguf"]?["com.c"]?.instantAccepted == 1, "acstats log: instant accept attributed to the instant's app")
        check(m1.approx && d9.total.shown == 4, "acstats log: broken and unknown lines skipped, days marked approximate", "\(d9.total.shown)")
        check(ACStats.parseLog([], calendar: cal).isEmpty, "acstats log: empty input")

        // Local day from a UTC timestamp.
        var msk = Calendar(identifier: .gregorian); msk.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        let q = ACStats.parseLog(["2026-11-09T23:30:00Z autocomplete: shown len=6 ms=100 app=a"], calendar: msk)
        check(q.days.keys.first == "2026-11-10", "acstats log: day is the local one")

        // Store: JSON round-trip, throttle, import-once, reset, privacy.
        let dir = NSTemporaryDirectory() + "tolk-acstats-\(UUID().uuidString)"
        let jsonPath = dir + "/s.json", logPath = dir + "/t.log"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try? log.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        let s1 = ACStatsStore(path: jsonPath, logPath: logPath, calendar: cal)
        check(FileManager.default.fileExists(atPath: jsonPath) && s1.data.summary(last: nil, calendar: cal).total.shown == 4, "acstats store: first launch imports the log and writes the JSON")
        let t0 = Date()
        s1.shown(model: "m3.gguf", app: "com.q", text: "секретный текст тут", ms: 120, now: t0)
        s1.acceptedWord(model: "m3.gguf", app: "com.q", word: " секретный", now: t0)
        let size1 = (try? Data(contentsOf: URL(fileURLWithPath: jsonPath)).count) ?? 0
        s1.shown(model: "m3.gguf", app: "com.q", text: "ещё", ms: 120, now: t0.addingTimeInterval(5))
        let size2 = (try? Data(contentsOf: URL(fileURLWithPath: jsonPath)).count) ?? 0
        check(size1 == size2, "acstats store: no write within 30 s")
        s1.shown(model: "m3.gguf", app: "com.q", text: "ещё", ms: 120, now: t0.addingTimeInterval(31))
        let size3 = (try? Data(contentsOf: URL(fileURLWithPath: jsonPath)).count) ?? 0
        check(size3 > size2, "acstats store: written again after 30 s")
        s1.flush()
        let raw = (try? String(contentsOfFile: jsonPath, encoding: .utf8)) ?? ""
        check(!raw.contains("секрет") && !raw.contains("ещё"), "acstats store: JSON holds no text")
        let s2 = ACStatsStore(path: jsonPath, logPath: logPath, calendar: cal)
        check(s2.data.summary(last: nil, calendar: cal).total.shown == s1.data.summary(last: nil, calendar: cal).total.shown && s2.data.summary(last: nil, calendar: cal).total.shown >= 6,
              "acstats store: reload from JSON, log not imported twice")
        let live = s2.data.byModel(calendar: cal).first { $0.name == "m3.gguf" }?.bucket
        check(live?.shown == 3 && live?.tabWords == 1 && live?.tabChars == 10 && live?.medianLatency == 125, "acstats store: live counters (words counted, text dropped)")
        s2.reset()
        check(ACStatsStore(path: jsonPath, logPath: logPath, calendar: cal).data.isEmpty, "acstats store: reset empties it and the log is not re-imported")
        try? "{ broken".write(toFile: jsonPath, atomically: true, encoding: .utf8)
        check(ACStatsStore(path: jsonPath, logPath: nil, calendar: cal).data.isEmpty, "acstats store: broken JSON → empty, no crash")
        check(ACStats.loadReadOnly(path: dir + "/none.json", logPath: logPath, calendar: cal).summary(last: nil, calendar: cal).total.shown == 4
              && !FileManager.default.fileExists(atPath: dir + "/none.json"), "acstats: read-only load falls back to the log without writing")
        check(ACStats.menuLine(ACStatsData(), now: now, calendar: cal) == nil, "acstats: no menu line without data today")
        var md = ACStatsData()
        md.update(day: day(0), model: "A", app: "x") { $0.shown = 7; $0.tabEvents = 2; $0.tabWords = 2 }
        check(ACStats.menuLine(md, now: now, calendar: cal) == "Сегодня: принято 2 слова (29 %)", "acstats: menu line", ACStats.menuLine(md, now: now, calendar: cal) ?? "nil")
        check(ACStats.report(ACStatsData()).contains("пока нет") && ACStats.report(p, now: now, calendar: cal).contains("приблизительно"), "acstats: report text")
    }
}
