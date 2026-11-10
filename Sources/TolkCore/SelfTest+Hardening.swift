// Regression checks for crashes / data-loss found in the reliability audit (pure logic only).
import Foundation

extension SelfTest {
    static func hardening(_ check: Check) {
        // Language detection: a text whose every word is dropped as an «ID» used to recurse forever.
        for t in ["ключ=значение", "путь/файл", "ид_запрос", "҂", "a=b", "12/34"] {
            let l = LanguageDetector.detect(t)
            check(Language.allCases.contains(l), "detect: no endless recursion on «\(t)»")
        }

        // Model garbage with the closing brace first must not trap.
        check(OllamaProvider.jsonObjectText("} garbage {") == "} garbage {", "json extract: } before { is left alone")
        check(OllamaProvider.jsonObjectText("x {\"a\":1} y") == "{\"a\":1}", "json extract: object cut out")
        check(OllamaProvider.parseNotes("}{", source: "s").isEmpty, "notes: garbage braces → no notes, no crash")

        // Config: one bad value loses only that value.
        let bad = #"{"model": "keep-me", "primaryLanguage": "klingon", "fallback": 42, "toneByApp": "oops", "autocomplete": true}"#
        if let c = try? JSONDecoder().decode(TolkConfig.self, from: Data(bad.utf8)) {
            check(c.model == "keep-me" && c.autocomplete, "config: good values survive a bad neighbour")
            check(c.primaryLanguage == TolkConfig().primaryLanguage, "config: unknown language → default")
        } else { check(false, "config: a bad value must not fail the whole decode") }
        let dir = NSTemporaryDirectory() + "tolk-selftest-cfg-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cfgPath = dir + "/tolk.json"
        try? Data("{ not json".utf8).write(to: URL(fileURLWithPath: cfgPath))
        _ = TolkConfig.load(from: cfgPath)
        check(FileManager.default.fileExists(atPath: cfgPath + ".corrupt"), "config: an unparsable file is backed up before defaults take over")

        // CRLF CSV (Excel, our own export): separator detected from the first line only.
        let csv = "term;translation\r\nfoo, bar;baz\r\n"
        check(GlossaryCSV.parse(Data(csv.utf8)).first?.term == "foo, bar", "csv: CRLF file, semicolon separator")

        // Rules file that exists but cannot be read as UTF-8 is never overwritten by the built-in text.
        let rulesPath = dir + "/rules.md"
        let latin1: [UInt8] = [0x2D, 0x20, 0xFF, 0xFE, 0x0A] // invalid UTF-8
        try? Data(latin1).write(to: URL(fileURLWithPath: rulesPath))
        let store = RulesStore(path: rulesPath, builtIn: "# built-in\n")
        let threw = (try? store.addTerm(source: "a", translation: "b")) == nil
        check(threw && (try? Data(contentsOf: URL(fileURLWithPath: rulesPath))) == Data(latin1), "rules: unreadable file is left untouched, addTerm throws")

        // History: a corrupt date (out of Int64 range) is a skipped line, not a crash at launch.
        let hp = dir + "/history.jsonl"
        let line = #"{"id":"11111111-1111-1111-1111-111111111111","date":9.9e30,"origin":"page","source":"a","translation":"b","sourceLanguage":"en","targetLanguage":"ru","provider":"t","mode":"translate"}"#
        try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: hp))
        let hs = HistoryStore(path: hp, defaults: UserDefaults(suiteName: "tolk-selftest-hardening") ?? .standard)
        check(hs.count == 0, "history: out-of-range date line skipped")

        // Time zones: non-ASCII digits (ICU \d matches them) used to trap on Int(...)!.
        _ = TimezoneLine.lines(in: "١٠:٣٠ UTC и 10:30 UTC, ١٢.٠٣.٢٠٢٥")
        check(true, "timezone: Arabic-Indic digits do not crash")
    }
}
