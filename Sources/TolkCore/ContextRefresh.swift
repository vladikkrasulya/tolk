// When does the screen context (OCR of the window above the input field) need to be recognised again?
// Pure logic, no AppKit: the app feeds it 8-bit grayscale pixels and clock values. Self-test: SelfTest+ACHeal.swift.
//
// Why: one OCR cycle (snapshot + Vision) costs ~0.35–0.55 s of CPU/GPU (median 473 ms over 496 cycles in the real log),
// and it used to run every 4 s while typing even when nothing on the screen had changed. Now the snapshot is shrunk to a
// 32×32 grayscale signature and compared with the previous one; Vision runs only when the picture changed, and — without an
// event (another window, a sent message, scrolling) — not more often than every `quietInterval`.
import Foundation

public enum FrameChange {
    public static let grid = 32
    /// A cell counts as changed when its mean brightness moves by more than this (0…255).
    public static let cellThreshold = 12
    /// Share of changed cells that counts as "the picture changed": 0.4 % ≈ 5 of 1024 cells. A one-line message is
    /// ≥ 5 cells; a blinking dot, a clock or a hover highlight is 1–3.
    public static let changedShare = 0.004

    public struct Signature: Equatable, Sendable {
        public let cells: [UInt8]
        public let width: Int
        public let height: Int
        public init(cells: [UInt8], width: Int, height: Int) { self.cells = cells; self.width = width; self.height = height }
    }

    /// Box average of a `width`×`height` 8-bit luma buffer (row-major, top row first) down to `grid`×`grid`.
    public static func signature(luma: [UInt8], width: Int, height: Int) -> Signature? {
        guard width >= grid, height >= grid, luma.count >= width * height else { return nil }
        var cells = [UInt8](repeating: 0, count: grid * grid)
        for gy in 0..<grid {
            let y0 = gy * height / grid, y1 = max(y0 + 1, (gy + 1) * height / grid)
            for gx in 0..<grid {
                let x0 = gx * width / grid, x1 = max(x0 + 1, (gx + 1) * width / grid)
                var sum = 0
                for y in y0..<y1 { let row = y * width; for x in x0..<x1 { sum += Int(luma[row + x]) } }
                cells[gy * grid + gx] = UInt8(sum / ((y1 - y0) * (x1 - x0)))
            }
        }
        return Signature(cells: cells, width: width, height: height)
    }

    /// Share of cells whose brightness differs by more than `cellThreshold`.
    public static func changedFraction(_ a: Signature, _ b: Signature) -> Double {
        guard a.cells.count == b.cells.count, !a.cells.isEmpty else { return 1 }
        var n = 0
        for i in a.cells.indices where abs(Int(a.cells[i]) - Int(b.cells[i])) > cellThreshold { n += 1 }
        return Double(n) / Double(a.cells.count)
    }

    /// True when the picture is new: no previous signature, another size (the region above a growing input field shrinks),
    /// or at least `changedShare` of the cells changed.
    public static func isChanged(old: Signature?, new: Signature) -> Bool {
        guard let old else { return true }
        if old.width != new.width || old.height != new.height { return true }
        return changedFraction(old, new) >= changedShare
    }
}

public enum ContextRefreshPolicy {
    public enum Event: Equatable, Sendable {
        case none
        /// Another window / field / chat (the key changed).
        case windowChanged
        /// The input field was emptied: a message has just been sent (Return).
        case sent
        /// The mouse wheel / trackpad scrolled over the screen and has settled.
        case scrolled
    }

    /// Without an event: look at the screen at most this often.
    public static let quietInterval: TimeInterval = 15
    /// After an event: look again after this long (lets the new message render, avoids snapshot storms).
    public static let eventInterval: TimeInterval = 1.5

    /// May the screen be captured and compared now? `lastCheck` is the time of the previous capture (nil: never).
    public static func mayCheck(now: Date, lastCheck: Date?, event: Event) -> Bool {
        guard let last = lastCheck else { return true }
        if event == .windowChanged { return true }
        let age = now.timeIntervalSince(last)
        return age >= (event == .none ? quietInterval : eventInterval)
    }
}
