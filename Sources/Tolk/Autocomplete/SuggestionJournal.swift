// "Журнал отладки подсказок": opt-in, local, temporary. While enabled (one hour), every suggestion event is
// appended to ~/Library/Logs/Tolk/ac-debug/journal.jsonl and every shown suggestion gets a screenshot of the
// area around the caret (shots/*.png). This file DOES contain the last 80 characters the user typed —
// that is why it is off by default, expires by itself and can be deleted from the menu.
import AppKit
import ScreenCaptureKit

@MainActor
final class SuggestionJournal: NSObject, NSMenuItemValidation {
    static let shared = SuggestionJournal()

    static let duration: TimeInterval = 3600
    private static let untilKey = "acDebugJournalUntil"
    private static let maxShots = 300
    private static let minShotInterval: TimeInterval = 1
    private static let shotSize = CGSize(width: 700, height: 160)

    private let dir: URL
    private let shotsDir: URL
    private var shotCount = 0
    private var lastShot = Date.distantPast
    private var lastCaptureErrorLog = Date.distantPast
    private var expiryTimer: Timer?
    private let toggleItem = NSMenuItem()
    private let clearItem = NSMenuItem()

    private override init() {
        dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tolk/ac-debug")
        shotsDir = dir.appendingPathComponent("shots")
        super.init()
        toggleItem.target = self
        toggleItem.action = #selector(toggle)
        clearItem.title = "Удалить отладку"
        clearItem.target = self
        clearItem.action = #selector(clear)
        scheduleExpiry()
    }

    // MARK: - State

    private var until: Date? {
        get { UserDefaults.standard.object(forKey: Self.untilKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.untilKey) }
    }

    var isEnabled: Bool { (until ?? .distantPast) > Date() }

    func enable() {
        until = Date().addingTimeInterval(Self.duration)
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        shotCount = (try? FileManager.default.contentsOfDirectory(atPath: shotsDir.path).count) ?? 0
        scheduleExpiry()
        Diagnostics.log("autocomplete: debug journal on")
    }

    func disable() {
        until = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        Diagnostics.log("autocomplete: debug journal off")
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let until, until > Date() else { if until != nil { disable() }; return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.disable() }
        }
    }

    // MARK: - Menu

    /// Separator + the two journal items, to be appended to the "Автодополнение" submenu.
    func menuItems() -> [NSMenuItem] { [.separator(), toggleItem, clearItem] }

    @objc private func toggle() { isEnabled ? disable() : enable() }

    @objc private func clear() {
        try? FileManager.default.removeItem(at: dir)
        shotCount = 0
        Diagnostics.log("autocomplete: debug journal deleted")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item === toggleItem {
            if isEnabled, let until {
                let min = Int(until.timeIntervalSinceNow / 60) + 1
                item.title = "Записывать отладку подсказок (ещё \(min) мин)"
                item.state = .on
            } else {
                item.title = "Записывать отладку подсказок (1 час)"
                item.state = .off
            }
        }
        return true
    }

    // MARK: - Events

    func shown(bundleID: String?, before: String, text: String, ms: Int, ctxChars: Int, ctxSource: String?,
               caret: NSRect, panel: GhostTextPanel?) {
        guard isEnabled else { return }
        let shot = scheduleShot(caret: caret, panel: panel)
        var e: [String: Any] = ["ev": "shown", "app": bundleID ?? "?", "before": String(before.suffix(80)),
                                "suggestion": text, "ms": ms, "ctx": ctxChars > 0, "ctxChars": ctxChars]
        if let ctxSource { e["ctxSource"] = ctxSource }
        if let shot { e["png"] = shot }
        write(e)
    }

    func instant(bundleID: String?, before: String, replaceCount: Int, display: String, caret: NSRect, panel: GhostTextPanel?) {
        guard isEnabled else { return }
        let shot = scheduleShot(caret: caret, panel: panel)
        var e: [String: Any] = ["ev": "instant", "app": bundleID ?? "?", "before": String(before.suffix(80)),
                                "replace": replaceCount, "suggestion": display]
        if let shot { e["png"] = shot }
        write(e)
    }

    func accepted(kind: String, text: String, bundleID: String?, method: String = "unicode", ms: Int = 0, before: String? = nil, caret: NSRect? = nil) {
        guard isEnabled else { return }
        var e: [String: Any] = ["ev": "accepted", "kind": kind, "text": text, "app": bundleID ?? "?", "method": method, "insertMs": ms]
        if let before { e["before"] = String(before.suffix(60)) }
        // How the inserted text landed in the field (spaces, case, duplicates): ~200 ms after the insertion.
        if let caret, let shot = scheduleShot(caret: caret, panel: nil, delayMs: 200, ignoreInterval: true) { e["png"] = shot }
        write(e)
    }

    /// ~200 ms after an insertion: did the field change, and what stands before the caret now.
    func insertChecked(bundleID: String?, method: String, changed: Bool, after: String?) {
        guard isEnabled else { return }
        var e: [String: Any] = ["ev": "insert_check", "app": bundleID ?? "?", "method": method, "changed": changed]
        if let after { e["after"] = String(after.suffix(60)) }
        write(e)
    }

    func dismissed(reason: String, bundleID: String?) {
        guard isEnabled else { return }
        write(["ev": "dismissed", "reason": reason, "app": bundleID ?? "?"])
    }

    private func write(_ fields: [String: Any]) {
        var e = fields
        e["t"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        guard let data = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("journal.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data + Data("\n".utf8))
    }

    // MARK: - Screenshots

    /// Returns the file name when a screenshot was scheduled (≤1 per second, ≤300 files).
    private func scheduleShot(caret: NSRect, panel: GhostTextPanel?, delayMs: Int = 80, ignoreInterval: Bool = false) -> String? {
        let now = Date()
        guard shotCount < Self.maxShots, ignoreInterval || now.timeIntervalSince(lastShot) >= Self.minShotInterval else { return nil }
        lastShot = now
        shotCount += 1
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = stamp.string(from: now) + ".png"
        let url = shotsDir.appendingPathComponent(name)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self, panel?.isVisible ?? true else { return }
            do {
                let image = try await Self.capture(around: caret)
                try? FileManager.default.createDirectory(at: self.shotsDir, withIntermediateDirectories: true)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                try png.write(to: url)
            } catch {
                if Date().timeIntervalSince(self.lastCaptureErrorLog) > 30 {
                    self.lastCaptureErrorLog = Date()
                    self.write(["ev": "capture_error", "error": String(describing: error).prefix(200).description])
                }
            }
        }
        return name
    }

    /// About 700×160 pt around the caret (more to the right, where the suggestion is), Tolk's own windows included.
    private static func capture(around caret: NSRect) async throws -> CGImage {
        let point = NSPoint(x: caret.midX, y: caret.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            throw NSError(domain: "Tolk", code: 1, userInfo: [NSLocalizedDescriptionKey: "no screen"])
        }
        var r = NSRect(x: caret.minX - 200, y: caret.midY - shotSize.height / 2, width: shotSize.width, height: shotSize.height)
        r = r.intersection(screen.frame)
        guard !r.isEmpty else { throw NSError(domain: "Tolk", code: 2, userInfo: [NSLocalizedDescriptionKey: "empty rect"]) }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw NSError(domain: "Tolk", code: 3, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let local = CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
        config.sourceRect = local
        let scale = screen.backingScaleFactor
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        config.showsCursor = false
        config.scalesToFit = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
