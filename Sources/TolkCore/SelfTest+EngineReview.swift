// Self-tests of the engine-review additions: EntityMasker, ThreadMemory, CalqueDetector + editor «OK», RulesFingerprint,
// TimezoneConverter. No model, no network.
import Foundation

extension SelfTest {
    static func engineReview(_ check: Check) {
        masker(check); threadMemory(check); calques(check); fingerprint(check); timezones(check)
    }

    private static func masker(_ check: Check) {
        func kinds(_ s: String) -> [String] { EntityMasker.mask(s).entities.map { "\($0.kind.rawValue):\($0.original)" } }
        let url = "https://t.example.com/c?cid={click_id}&p=${AUCTION_PRICE}"
        check(kinds("Open \(url), then go.") == ["link:\(url)"], "mask: url with macros, trailing comma stays outside", "\(kinds("Open \(url), then go."))")
        check(kinds("see (https://a.com/x_(1)).") == ["link:https://a.com/x_(1)"], "mask: balanced paren in url", "\(kinds("see (https://a.com/x_(1))."))")
        check(kinds("write to a.b@x.com now") == ["email:a.b@x.com"], "mask: email")
        for m in ["{click_id}", "${AUCTION_PRICE}", "[cb]", "%%MACRO%%", "{{var}}", "%CLICKID%", "__CB__"] {
            check(kinds("macro \(m) here") == ["macro:\(m)"], "mask: macro \(m)", "\(kinds("macro \(m) here"))")
        }
        check(kinds("run `kubectl get pods` now") == ["code:`kubectl get pods`"], "mask: inline code")
        check(kinds("fix RTB-1420 today") == ["ticket:RTB-1420"], "mask: ticket")
        check(kinds("Net-30 terms").isEmpty, "mask: Net-30 is not a ticket")
        check(kinds("field imp.banner.w is 0") == ["field:imp.banner.w"], "mask: dotted field")
        check(kinds("seatbid is empty") == ["field:seatbid"], "mask: seatbid")
        check(kinds("param click_id missing") == ["field:click_id"], "mask: snake_case")
        check(kinds("e.g. this, i.e. that").isEmpty, "mask: e.g./i.e. untouched", "\(kinds("e.g. this, i.e. that"))")
        check(kinds("ping @channel and <@U123> and @vlad_k") == ["mention:@channel", "mention:<@U123>", "mention:@vlad_k"], "mask: mentions", "\(kinds("ping @channel and <@U123> and @vlad_k"))")
        check(kinds("log /var/log/rtb/bidder.log ok") == ["path:/var/log/rtb/bidder.log"], "mask: path")
        check(kinds("id 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b done") == ["id:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"], "mask: hex hash")
        check(kinds("Hello, how are you? Расскажи, как дела.").isEmpty, "mask: plain text untouched")
        for f in EntityMasker.Format.allCases {
            let src = "Check \(url), RTB-1420, @channel and `x` [cb]"
            let m = EntityMasker.mask(src, format: f)
            check(m.entities.count == 5 && m.restore(m.text) == src, "mask: roundtrip \(f.rawValue)", m.text)
            let t1 = f.token(1), t2 = f.token(2)
            check(m.restore(m.text.replacingOccurrences(of: t1, with: "")) == nil, "mask: lost placeholder → nil (\(f.rawValue))")
            check(m.restore(m.text + " " + t2) == nil, "mask: duplicated placeholder → nil (\(f.rawValue))")
            check(m.restore(m.text + " " + f.token(9)) == nil, "mask: invented placeholder → nil (\(f.rawValue))")
            check(m.restore("Проверь " + (1...5).map { f.token($0) }.joined(separator: ", ")) == "Проверь " + m.entities.map(\.original).joined(separator: ", "),
                  "mask: restore in new order (\(f.rawValue))")
        }
        check(EntityMasker.mask("plain").restore("простой") == "простой", "mask: no entities → pass-through")
        let r = ResolvedRequest(text: "x", source: .english, target: .russian, tone: .auto)
        var masked = r; masked.protectedExample = "⟦1⟧"
        check(!Prompt.system(for: r, rules: "").contains("Protected placeholders"), "mask: prompt without note")
        check(Prompt.system(for: masked, rules: "").contains("⟦1⟧"), "mask: prompt has note")
    }

    private static func threadMemory(_ check: Check) {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000_000) }
        let clock = Clock()
        let mem = ThreadMemory(now: { clock.t })
        let app = "com.tinyspeck.slackmacgap"
        mem.record(source: "Our DSP drops requests", translation: "Наш DSP теряет запросы", from: .english, to: .russian, app: app)
        check(mem.context(for: "They are still dropping requests on timeout", app: app) != nil, "thread: short text, same app → context")
        check(mem.context(for: "They are still dropping requests on timeout", app: "ru.keepcoder.Telegram") == nil, "thread: other app → none")
        check(mem.context(for: Array(repeating: "word", count: 21).joined(separator: " "), app: app) == nil, "thread: 21 words → none")
        check(mem.context(for: Array(repeating: "word", count: 20).joined(separator: " "), app: app) != nil, "thread: 20 words → context")
        check(mem.context(for: "ok", app: nil) == nil, "thread: no app id → none")
        clock.t.addTimeInterval(4 * 60)
        check(mem.context(for: "Can we raise the floor on them?", app: app) != nil, "thread: 4 min → context")
        clock.t.addTimeInterval(2 * 60)
        check(mem.context(for: "Can we raise the floor on them?", app: app) == nil, "thread: 6 min → none")
        for i in 1...4 { mem.record(source: "s\(i)", translation: "t\(i)", from: .english, to: .russian, app: app) }
        let ctx = mem.context(for: "and them?", app: app) ?? ""
        check(!ctx.contains("s1 ⇒") && ctx.contains("s2 ⇒") && ctx.contains("s4 ⇒"), "thread: ring buffer keeps last 3", ctx)
        clock.t.addTimeInterval(16 * 60)
        check(mem.context(for: "and them?", app: app) == nil, "thread: expired after 15 min")
        mem.record(source: "Is it live?", translation: "Оно уже работает?", from: .english, to: .russian, app: app)
        check(mem.context(for: "Is it live?", app: app) == nil, "thread: the same text is not its own context (cache key stays)")
        mem.record(source: "Is it live?", translation: "Оно уже работает?", from: .english, to: .russian, app: app)
        mem.record(source: "Ping", translation: "Пинг", from: .english, to: .russian, app: app)
        let rep = mem.context(for: "and now?", app: app) ?? ""
        check(rep.components(separatedBy: "Is it live?").count == 2, "thread: a repeated line is kept once", rep)
        mem.record(source: "a", translation: "b", from: .english, to: .russian, app: app)
        mem.clear(app: app)
        check(mem.context(for: "x", app: app) == nil, "thread: clear")
        var r = ResolvedRequest(text: "x", source: .english, target: .russian, tone: .auto)
        check(!Prompt.system(for: r, rules: "").contains("Earlier messages"), "thread: prompt without context")
        r.threadContext = "s1 ⇒ t1"
        check(Prompt.system(for: r, rules: "").contains("s1 ⇒ t1"), "thread: prompt has context")
        var req = TranslationRequest(text: "x"); req.threadContext = "a ⇒ b"
        check(LanguageDetector.resolve(req, config: TolkConfig()).threadContext == "a ⇒ b", "thread: resolve keeps context")
    }

    private static func calques(_ check: Check) {
        check(CalqueDetector.count >= 40, "calque: 40+ entries", "\(CalqueDetector.count)")
        func ids(_ s: String, _ l: Language) -> [String] { CalqueDetector.detect(in: s, language: l).map(\.id) }
        check(ids("Наперед дякую за допомогу!", .ukrainian) == ["uk-napered-dyakuyu"], "calque: наперед дякую")
        check(ids("Я приймаю участь у зустрічі", .ukrainian) == ["uk-pryymaty-uchast"], "calque: приймаю участь")
        check(ids("По крайній мірі спробуйте", .ukrainian) == ["uk-po-krainiy-miri"], "calque: по крайній мірі")
        check(ids("На даний момент це не працює", .ukrainian) == ["uk-na-danyy-moment"], "calque: на даний момент")
        check(ids("Вибачаюсь за затримку", .ukrainian) == ["uk-vybachayus"], "calque: вибачаюсь")
        check(ids("Прошу вас решить вопрос", .russian) == ["ru-proshu-vas"], "calque: прошу вас решить")
        check(ids("Это имеет смысл", .russian) == ["ru-imeet-smysl"], "calque: имеет смысл")
        check(ids("I kindly ask you to check", .english) == ["en-kindly-ask"], "calque: I kindly ask you")
        check(ids("Please be advised that the feed is down", .english) == ["en-be-advised"], "calque: please be advised")
        check(ids("As per our conversation, I sent it", .english) == ["en-as-per-conv"], "calque: as per our conversation", "\(ids("As per our conversation, I sent it", .english))")
        check(ids("As per the contract it is due", .english) == ["en-as-per"], "calque: as per")
        check(ids("We will revert back soon", .english) == ["en-revert-back"], "calque: revert back")
        check(ids("Заздалегідь дякую, візьміть участь, принаймні зараз", .ukrainian).isEmpty, "calque: clean Ukrainian")
        check(ids("Сейчас это логично, сообщите, пожалуйста", .russian).isEmpty, "calque: clean Russian")
        check(ids("Could you please check it? I look forward to hearing from you.", .english).isEmpty, "calque: clean English")
        check(ids("наперед дякую", .english).isEmpty, "calque: language-specific")
        let w = CalqueDetector.warnings(in: "Наперед дякую", language: .ukrainian)
        check(w.count == 1 && CalqueDetector.isCalque(w[0]) && w[0] == "калька: «Наперед дякую» → «заздалегідь дякую»", "calque: warning format", "\(w)")
        check(!CalqueDetector.isCalque("потерян e-mail a@b.c"), "calque: isCalque false for check warning")
        check(CalqueDetector.promptHint(for: []).isEmpty && CalqueDetector.promptHint(for: CalqueDetector.detect(in: "вибачаюсь", language: .ukrainian)).contains("вибачаюсь"), "calque: prompt hint")
        // Editor «OK» exit.
        check(RefineGuard.isOK("OK") && RefineGuard.isOK(" ok.\n") && RefineGuard.isOK("\"OK\"") && !RefineGuard.isOK("OK, thanks for the help"), "refine: OK detection")
        let plain = RefinePrompt.system(from: .english, to: .russian, tone: .auto, rules: "")
        check(plain.contains("exactly: OK") && plain.contains("reply with exactly the two letters OK"), "refine: no calques → OK prompt")
        let hit = RefinePrompt.system(from: .english, to: .ukrainian, tone: .auto, rules: "", calques: CalqueDetector.detect(in: "вибачаюсь", language: .ukrainian))
        check(!hit.contains("exactly: OK") && hit.contains("Known calques"), "refine: calques → hint, no OK")
    }

    private static func fingerprint(_ check: Check) {
        let dir = NSTemporaryDirectory() + "tolk-fp-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/rules.md"
        check(RulesFingerprint.of(path: path) == "none", "fingerprint: missing file")
        try? "# Rules\n\n## Глоссарий\n- floor → флор\n".write(toFile: path, atomically: true, encoding: .utf8)
        let a = RulesFingerprint.of(path: path)
        check(a.count == 16 && a == RulesFingerprint.of(path: path), "fingerprint: stable", a)
        let store = RulesStore(path: path)
        check(store.rulesFingerprint == a, "fingerprint: store")
        try? store.addTerm(source: "bidfloor", translation: "минимальная ставка")
        let b = store.rulesFingerprint
        check(b != a, "fingerprint: changes after «add to glossary»")
        try? "# Rules\n\n## Глоссарий\n- floor → пол\n".write(toFile: path, atomically: true, encoding: .utf8)
        check(RulesFingerprint.of(path: path) != b && RulesFingerprint.of(path: path) != a, "fingerprint: changes after file edit")
        let c = RulesFingerprint.of(path: path)
        try? "# Rules\n\n## Глоссарий\n- floor → пол\n".write(toFile: path, atomically: true, encoding: .utf8)
        check(RulesFingerprint.of(path: path) == c, "fingerprint: same content → same hash")
    }

    private static func timezones(_ check: Check) {
        let iso = ISO8601DateFormatter()
        let nov = iso.date(from: "2026-11-10T09:00:00Z")!, jul = iso.date(from: "2026-07-15T09:00:00Z")!
        let kyiv = TimeZone(identifier: "Europe/Kyiv")!, ny = TimeZone(identifier: "America/New_York")!
        func one(_ s: String, now: Date = nov, zone: TimeZone = kyiv) -> String {
            let r = TimezoneConverter.convert(in: s, now: now, localZone: zone)
            return r.count == 1 ? r[0].display : "[\(r.count) results: \(r.map(\.display))]"
        }
        let cases: [(String, Date, TimeZone, String)] = [
            ("Call at 10 AM EST", nov, kyiv, "10 AM EST → 17:00"),
            ("10:00 AM EDT please", nov, kyiv, "10:00 AM EDT → 16:00"),
            ("sync at 9:30 PT", nov, kyiv, "9:30 PT → 19:30"),
            ("window 14:00–16:00 UTC", nov, kyiv, "14:00–16:00 UTC → 16:00–18:00"),
            ("at 15:00 GMT+3", nov, kyiv, "15:00 GMT+3 → 14:00"),
            ("10 AM CET", nov, kyiv, "10 AM CET → 11:00"),
            ("созвон в 15:00 по Киеву", nov, kyiv, "15:00 по Киеву → 15:00"),
            ("созвон в 15:00 по МСК", nov, kyiv, "15:00 по МСК → 14:00"),
            ("в 15 по Киеву", nov, kyiv, "15 по Киеву → 15:00"),
            ("3 PM ET", nov, kyiv, "3 PM ET → 22:00"),
            ("11pm PST", nov, kyiv, "11pm PST → 09:00 (завтра)"),
            ("23:30 UTC", nov, kyiv, "23:30 UTC → 01:30 (завтра)"),
            ("12 AM UTC", nov, kyiv, "12 AM UTC → 02:00"),
            ("12 PM UTC", nov, kyiv, "12 PM UTC → 14:00"),
            ("9am-5pm EST", nov, kyiv, "9am-5pm EST → 16:00–00:00"),
            ("10-11 AM PST", nov, kyiv, "10-11 AM PST → 20:00–21:00"),
            ("10:00 UTC+5:30", nov, kyiv, "10:00 UTC+5:30 → 06:30"),
            ("10 AM PT", jul, kyiv, "10 AM PT → 20:00"),            // PDT in July
            ("10 AM EST", jul, kyiv, "10 AM EST → 18:00"),           // EST is literal: UTC-5 even in summer
            ("10 AM ET", jul, kyiv, "10 AM ET → 17:00"),             // ET follows daylight saving
            ("3 PM PT on Nov 12", nov, kyiv, "3 PM PT → 13 нояб, 01:00"),
            ("Jul 20 10 AM PT", nov, kyiv, "10 AM PT → 20 июл, 20:00"),
            ("14.11 10:00 PT", nov, kyiv, "10:00 PT → 14 нояб, 20:00"),
            ("9:30 PT", nov, ny, "9:30 PT → 12:30"),
            ("10 AM IST", nov, kyiv, "10 AM IST → IST — неоднозначный пояс (Индия / Израиль / Ирландия), пропущено"),
            ("9:30 CST", nov, kyiv, "9:30 CST → CST — неоднозначный пояс (США Central / Китай / Куба), пропущено"),
            ("5 pm BST", nov, kyiv, "5 pm BST → BST — неоднозначный пояс (Британия летом / Бангладеш), пропущено"),
        ]
        for (s, now, zone, want) in cases { let got = one(s, now: now, zone: zone); check(got == want, "tz: \(s)", got) }
        for s in ["meet at 15:00", "version 2.14 is out", "we have 100-200 UTC servers", "10 pt font", "в 15:00 по расписанию", "about 3 am"] {
            check(TimezoneConverter.convert(in: s, now: nov, localZone: kyiv).isEmpty, "tz: no match «\(s)»")
        }
        let two = TimezoneConverter.convert(in: "Mon 10 AM PT, Tue 11:00 CET", now: nov, localZone: kyiv)
        check(two.count == 2 && two.allSatisfy { !$0.ambiguous }, "tz: two in one text", "\(two.map(\.display))")
        let same = TimezoneConverter.convert(in: "в 15:00 по Киеву", now: nov, localZone: kyiv)
        check(same.first?.sameAsLocal == true, "tz: sameAsLocal")
        let at = TimezoneConverter.convert(in: "Call at 10 AM EST", now: nov, localZone: kyiv).first
        check(at?.range.length == 9 && at?.found == "10 AM EST", "tz: found excludes «at»")
    }
}
