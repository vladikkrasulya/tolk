// Self-test of the engine's result cache: keys, LRU, expiry, bypass, what is (not) stored. No model, no network.
import Foundation

extension SelfTest {
    final class MockProvider: TranslationProvider, @unchecked Sendable {
        let name: String
        private let lock = NSLock()
        private var _calls = 0
        var available = true
        var failAfterFirstChunk = false
        var hang = false
        var output = "Привет, мир"
        init(name: String = "Mock") { self.name = name }
        var calls: Int { lock.withLock { _calls } }
        func isAvailable() async -> Bool { available }
        func translate(_ r: ResolvedRequest) -> AsyncThrowingStream<String, Error> {
            lock.withLock { _calls += 1 }
            let out = output, fail = failAfterFirstChunk, hang = hang
            return AsyncThrowingStream { c in
                let t = Task {
                    c.yield(String(out.prefix(3)))
                    if fail { c.finish(throwing: TolkError.unavailable("boom")); return }
                    if hang { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                    if Task.isCancelled { c.finish(throwing: CancellationError()); return }
                    c.yield(String(out.dropFirst(3))); c.finish()
                }
                c.onTermination = { _ in t.cancel() }
            }
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    static func drain(_ engine: DefaultTranslationEngine, _ req: TranslationRequest) -> (text: String, stats: TranslationStats?, error: Error?) {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var text = "", stats: TranslationStats?, error: Error?
        Task {
            do {
                for try await e in engine.translate(req) {
                    switch e {
                    case .started: text = ""
                    case let .delta(d): text += d
                    case let .stats(s): stats = s
                    default: break
                    }
                }
            } catch let e { error = e }
            sem.signal()
        }
        sem.wait()
        return (text, stats, error)
    }

    static func resultCache(_ check: Check) {
        let cfg = TolkConfig()
        let rulesText = "## Glossary\n- postback → постбек\n"
        let rules = RulesStore(path: "/nonexistent/rules.md", builtIn: rulesText)
        let clock = Clock()
        func make(_ p: MockProvider, fallback: MockProvider? = nil, rules: RulesStore = rules, max: Int = 200)
            -> DefaultTranslationEngine {
            DefaultTranslationEngine(config: cfg, rules: rules, primary: p, fallback: fallback,
                                     cache: ResultCache(maxEntries: max, now: { clock.now }),
                                     notesCache: ResultCache())
        }
        let base = TranslationRequest(text: "Hello world", source: .english, target: .russian, tone: .auto)

        // Hit / miss and the cached answer.
        let p = MockProvider(); let e = make(p)
        let a = drain(e, base)
        check(a.text == "Привет, мир" && p.calls == 1 && a.stats?.fromCache == false, "cache: first request goes to the model", "\(a)")
        let b = drain(e, base)
        check(b.text == a.text && p.calls == 1, "cache: identical request answered without the model", "calls=\(p.calls)")
        check(b.stats?.fromCache == true && b.stats?.total == 0 && b.stats?.provider == "Mock", "cache: stats marked fromCache, time 0", "\(String(describing: b.stats))")
        var padded = base; padded.text = "\r\n  Hello world \n"
        check(drain(e, padded).stats?.fromCache == true, "cache: edge whitespace and CRLF do not change the key")
        var inner = base; inner.text = "Hello  world"
        check(drain(e, inner).stats?.fromCache == false, "cache: inner spaces change the key")
        var upper = base; upper.text = "hello world"
        check(drain(e, upper).stats?.fromCache == false, "cache: case changes the key")

        // Every parameter changes the key.
        func miss(_ name: String, _ mutate: (inout TranslationRequest) -> Void) {
            var r = base; mutate(&r)
            let s = drain(e, r).stats
            check(s?.fromCache == false, "cache key: \(name) changes the key")
        }
        miss("target") { $0.target = .ukrainian }
        miss("source") { $0.source = .german }
        miss("tone") { $0.tone = .formal }
        miss("mode") { $0.mode = .polish; $0.target = .english }
        miss("replyTo") { $0.replyTo = "How are you?" }
        miss("context") { $0.context = TranslationContext(source: "Hi.", translation: "Привет.") }
        // Different model / provider name -> other key.
        let e2 = DefaultTranslationEngine(config: cfg, rules: rules, primary: MockProvider(name: "Other"), fallback: nil,
                                          cache: e.cache, notesCache: e.notesCache)
        check(drain(e2, base).stats?.fromCache == false, "cache key: provider/model changes the key")
        // Rules block: a glossary hit changes the prompt, another rules text changes it too.
        var pb = base; pb.text = "Send the postback"
        _ = drain(e, pb)
        check(drain(e, pb).stats?.fromCache == true, "cache: glossary text cached")
        let rules2 = RulesStore(path: "/nonexistent/rules.md", builtIn: "## Glossary\n- postback → пост-бэк\n")
        let e3 = DefaultTranslationEngine(config: cfg, rules: rules2, primary: p, fallback: nil, cache: e.cache, notesCache: e.notesCache)
        check(drain(e3, pb).stats?.fromCache == false, "cache key: edited glossary changes the key")
        let rules3 = RulesStore(path: "/nonexistent/rules.md", builtIn: "Be brief.\n" + rulesText)
        let e4 = DefaultTranslationEngine(config: cfg, rules: rules3, primary: p, fallback: nil, cache: e.cache, notesCache: e.notesCache)
        check(drain(e4, base).stats?.fromCache == false, "cache key: edited style rules change the key")

        // Bypass.
        let p5 = MockProvider(); let e5 = make(p5)
        _ = drain(e5, base)
        p5.output = "Здравствуй, мир"
        var fresh = base; fresh.bypassCache = true
        let f = drain(e5, fresh)
        check(f.text == "Здравствуй, мир" && p5.calls == 2 && f.stats?.fromCache == false, "cache: bypass calls the model", "\(f)")
        let after = drain(e5, base)
        check(after.text == "Здравствуй, мир" && after.stats?.fromCache == true && p5.calls == 2, "cache: bypass result replaces the entry", "\(after)")

        // LRU eviction: 2 slots; touching A keeps it, B is evicted.
        let p6 = MockProvider(); let e6 = make(p6, max: 2)
        func req(_ s: String) -> TranslationRequest { var r = base; r.text = s; return r }
        _ = drain(e6, req("A")); _ = drain(e6, req("B")); _ = drain(e6, req("A")); _ = drain(e6, req("C"))
        check(e6.cache.count == 2, "cache LRU: size capped", "\(e6.cache.count)")
        check(drain(e6, req("A")).stats?.fromCache == true, "cache LRU: recently used entry survives")
        check(drain(e6, req("B")).stats?.fromCache == false, "cache LRU: least recently used entry evicted")
        // Byte budget.
        let small = ResultCache<String>(maxEntries: 100, maxBytes: 10)
        small.set("a", "123456", cost: 6); small.set("b", "123456", cost: 6)
        check(small.get("a") == nil && small.get("b") != nil, "cache LRU: byte budget evicts the oldest")
        small.set("c", "x", cost: 11)
        check(small.get("c") == nil, "cache: value larger than the budget is not stored")

        // Expiry (24 h).
        let p7 = MockProvider(); let e7 = make(p7)
        _ = drain(e7, base)
        clock.advance(23 * 3600)
        check(drain(e7, base).stats?.fromCache == true, "cache TTL: still valid after 23 h")
        clock.advance(25 * 3600)
        check(drain(e7, base).stats?.fromCache == false && p7.calls == 2, "cache TTL: expired after 24 h")

        // Not stored: mid-stream error, fallback, empty, cancelled.
        let p8 = MockProvider(); p8.failAfterFirstChunk = true; let e8 = make(p8)
        let err = drain(e8, base)
        check(err.error != nil && e8.cache.count == 0, "cache: a broken stream is not stored", "\(String(describing: err.error))")
        let p9 = MockProvider(); p9.available = false; let fb = MockProvider(name: "Google")
        let e9 = make(p9, fallback: fb)
        let fr = drain(e9, base)
        check(fr.text == "Привет, мир" && e9.cache.count == 0, "cache: fallback translation is not stored", "\(fr)")
        check(drain(e9, base).stats?.fromCache == false && fb.calls == 2, "cache: fallback is asked again each time")
        let pe = MockProvider(); let ee = make(pe)
        _ = drain(ee, req("   "))
        check(ee.cache.count == 0 && pe.calls == 0, "cache: empty text is not stored")
        let pc = MockProvider(); pc.hang = true; let ec = make(pc)
        let sem = DispatchSemaphore(value: 0)
        let consumer = Task {
            do { for try await _ in ec.translate(base) {} } catch {}
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        consumer.cancel()
        _ = sem.wait(timeout: .now() + 3)
        Thread.sleep(forTimeInterval: 0.2)
        check(ec.cache.count == 0, "cache: a cancelled stream is not stored", "\(ec.cache.count)")

        // Thread safety: many parallel requests, one cache.
        let pt = MockProvider(); let et = make(pt)
        let group = DispatchGroup()
        for i in 0..<40 {
            group.enter()
            DispatchQueue.global().async { _ = drain(et, req("T\(i % 5)")); group.leave() }
        }
        check(group.wait(timeout: .now() + 10) == .success && et.cache.count == 5, "cache: parallel requests", "\(et.cache.count)")

        // Notes use a separate key space.
        let nk = TranslationCacheKey.notes(source: "a", translation: "b", from: .english, to: .russian, rules: "", identity: "x")
        let tk = TranslationCacheKey.translation(ResolvedRequest(text: "a", source: .english, target: .russian, tone: .auto),
                                                 systemPrompt: "", identity: "x")
        check(nk != tk, "cache: notes and translation key spaces differ")
        check(TranslationCacheKey.notes(source: "a", translation: "b", from: .english, to: .russian, rules: "r1", identity: "x")
              != TranslationCacheKey.notes(source: "a", translation: "b", from: .english, to: .russian, rules: "r2", identity: "x"),
              "cache key: notes depend on the rules block")
    }
}
