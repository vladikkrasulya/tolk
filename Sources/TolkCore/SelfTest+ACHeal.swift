// Checks for AutocompleteHealing.swift and ContextRefresh.swift.
import Foundation

extension SelfTest {
    static func autocompleteHealing(_ check: Check) {
        // Plan: what goes into the prompt, what is forced.
        let p1 = AutocompleteHealing.plan(textBefore: "Тут пока что не получи")
        check(p1.head == "Тут пока что не" && p1.literal == " получи", "heal: mid-word, space before the word", "\(p1)")
        let p2 = AutocompleteHealing.plan(textBefore: "Hello")
        check(p2.head == "" && p2.literal == "Hello", "heal: the whole text is one word")
        let p3 = AutocompleteHealing.plan(textBefore: "Тут пока что ")
        check(p3.head == "Тут пока что" && p3.literal == nil, "heal: caret after a space → nothing forced")
        let p4 = AutocompleteHealing.plan(textBefore: "кто-т")
        check(p4.head == "кто-" && p4.literal == "т", "heal: after a hyphen no space is forced")
        let p5 = AutocompleteHealing.plan(textBefore: "Привет!\nКак")
        check(p5.head == "Привет!" + "\n" && p5.literal == "Как", "heal: after a line break no space is forced", "\(p5)")
        let p6 = AutocompleteHealing.plan(textBefore: "price 100")
        check(p6.literal == nil && p6.head == "price 100", "heal: digits are not healed")
        check(AutocompleteHealing.plan(textBefore: "").literal == nil, "heal: empty text")

        // Grammar text.
        check(AutocompleteHealing.grammar(forLiteral: " по") == "root ::= \" по\" [^\\n]*", "heal: grammar")
        check(AutocompleteHealing.grammar(forLiteral: "a\"b\\c") == "root ::= \"a\\\"b\\\\c\" [^\\n]*", "heal: grammar escapes quotes and backslashes")

        // Strip: literal made of whole tokens, then free tokens keep their probabilities.
        typealias T = AutocompleteHealing.Token
        let a = AutocompleteHealing.strip(literal: " по", content: " получилось, что", tokens: [
            T(text: " по", prob: 0.2), T(text: "лучилось", prob: 0.9), T(text: ",", prob: 0.5), T(text: " что", prob: 0.4)])
        check(a.content == "лучилось, что" && a.tokens.map(\.text) == ["лучилось", ",", " что"] && a.tokens[0].prob == 0.9, "strip: literal = whole tokens", "\(a)")
        // A token that crosses the end of the literal: renormalised over consistent alternatives.
        let b = AutocompleteHealing.strip(literal: " п", content: " получилось", tokens: [
            T(text: " получилось", prob: 0.05, top: [(" могу", 0.44), (" получилось", 0.05), (" пока", 0.15), (" п", 0.05), (" успе", 0.14)])])
        check(b.content == "олучилось" && b.tokens.count == 1 && b.tokens[0].text == "олучилось", "strip: crossing token is cut", "\(b)")
        check(abs(b.tokens[0].prob - 0.05 / 0.25) < 1e-9, "strip: crossing token probability renormalised", "\(b.tokens[0].prob)")
        // Literal fully covered by the last token: nothing left.
        let c = AutocompleteHealing.strip(literal: " да", content: " да", tokens: [T(text: " да", prob: 0.3)])
        check(c.content == "" && c.tokens.isEmpty, "strip: nothing after the literal")
        // No literal: untouched.
        let d = AutocompleteHealing.strip(literal: "", content: "x", tokens: [T(text: "x", prob: 0.5)])
        check(d.content == "x" && d.tokens.count == 1, "strip: no literal, no change")
        // Cyrillic (multi-byte scalars) literal split inside a token.
        let e = AutocompleteHealing.strip(literal: "ст", content: "стоит ли", tokens: [T(text: "сто", prob: 0.6, top: [("сто", 0.6), ("ста", 0.2)]), T(text: "ит", prob: 0.8)])
        check(e.content == "оит ли" && e.tokens.map(\.text) == ["о", "ит"], "strip: Cyrillic literal inside a token", "\(e)")
    }

    // MARK: Screen-context refresh (frame comparison + timing)

    /// A fake chat window: grey text lines made of dark dashes.
    private static func fakeChat(width: Int = 400, height: Int = 300, lines: Int = 12, shiftUp: Int = 0, extraLineAtBottom: Bool = false) -> [UInt8] {
        var px = [UInt8](repeating: 242, count: width * height)
        func line(_ y: Int, seed: Int, widthFrac: Double = 0.8) {
            guard y >= 0, y + 10 < height else { return }
            var x = 12; var s = UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 12345)
            while x < Int(Double(width) * widthFrac) {
                s = s &* 1664525 &+ 1013904223
                let w = 6 + Int(s >> 24) % 18   // a "word"
                for yy in y..<(y + 10) { for xx in x..<min(width - 1, x + w) { px[yy * width + xx] = 50 } }
                x += w + 7
            }
        }
        for k in 0..<lines { line(8 + k * 20 - shiftUp, seed: k) }
        if extraLineAtBottom { line(8 + lines * 20 - shiftUp, seed: 99, widthFrac: 0.5) }
        return px
    }

    static func screenContextRefresh(_ check: Check) {
        func sig(_ px: [UInt8], w: Int = 400, h: Int = 300) -> FrameChange.Signature { FrameChange.signature(luma: px, width: w, height: h)! }
        let base = sig(fakeChat())
        check(!FrameChange.isChanged(old: base, new: sig(fakeChat())), "frame: identical picture = unchanged")
        // Only the input field changed (it is not in the region at all): the region is byte-identical → unchanged.
        // A blinking dot / caret-sized speck (4×10 px) inside the region → still unchanged.
        var speck = fakeChat()
        for y in 100..<110 { for x in 200..<204 { speck[y * 400 + x] = 0 } }
        check(!FrameChange.isChanged(old: base, new: sig(speck)), "frame: a small blinking speck = unchanged", "\(FrameChange.changedFraction(base, sig(speck)))")
        // A new message arrives: older text moves up by a line and a new line appears at the bottom.
        let newMsg = sig(fakeChat(shiftUp: 20, extraLineAtBottom: true))
        check(FrameChange.isChanged(old: base, new: newMsg), "frame: new message below, text shifted = changed", "\(FrameChange.changedFraction(base, newMsg))")
        // A short new line in free space (the window was not full yet).
        var half = fakeChat(lines: 6); let before = sig(half)
        for y in (8 + 6 * 20)..<(8 + 6 * 20 + 10) { for x in 12..<70 { half[y * 400 + x] = 50 } }
        check(FrameChange.isChanged(old: before, new: sig(half)), "frame: one short new line = changed", "\(FrameChange.changedFraction(before, sig(half)))")
        // Scrolled by half a line.
        check(FrameChange.isChanged(old: base, new: sig(fakeChat(shiftUp: 10))), "frame: scrolled = changed")
        // Different size of the region (the input field grew) and no previous picture.
        check(FrameChange.isChanged(old: base, new: sig(fakeChat(height: 280), h: 280)), "frame: another region height = changed")
        check(FrameChange.isChanged(old: nil, new: base), "frame: no previous picture = changed")
        check(FrameChange.signature(luma: [0, 1, 2], width: 3, height: 1) == nil, "frame: too small / short buffer → nil")
        // Mean-brightness maths: a uniform picture has a uniform signature.
        let flat = sig([UInt8](repeating: 100, count: 400 * 300))
        check(flat.cells.allSatisfy { $0 == 100 } && flat.cells.count == 1024, "frame: signature of a flat picture")

        // Timing policy.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func may(_ dt: Double, _ e: ContextRefreshPolicy.Event) -> Bool { ContextRefreshPolicy.mayCheck(now: t0.addingTimeInterval(dt), lastCheck: t0, event: e) }
        check(ContextRefreshPolicy.mayCheck(now: t0, lastCheck: nil, event: .none), "policy: never checked → check")
        check(!may(5, .none) && !may(14.9, .none) && may(15, .none), "policy: quiet screen is looked at every 15 s")
        check(may(0.1, .windowChanged), "policy: another window → at once")
        check(!may(1.0, .sent) && may(1.6, .sent), "policy: after Return wait 1.5 s")
        check(!may(1.0, .scrolled) && may(1.6, .scrolled), "policy: after scrolling wait 1.5 s")
    }
}
