// Gray "ghost" suggestion drawn right after the caret in another app's text field.
// Non-interactive (ignores mouse), never activates Tolk, no timers or animations.
import AppKit

/// Borderless panel that can never become key or main, so it cannot steal focus.
private final class GhostWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Rounded badge behind the "⇥" hint. Drawn directly (no layer), so it renders the same everywhere.
/// Draws the suggestion text directly at the view's origin: no cell padding, so the text starts exactly
/// where the caret is (an NSTextField label adds ~2 pt, which showed as a double gap after a space).
private final class GhostLabel: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var leadingGap: CGFloat = 0 { didSet { needsDisplay = true } }
    var font: NSFont = .systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    var color: NSColor = .gray { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: NSPoint(x: leadingGap, y: 0))
    }
}

private final class HintBadge: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

@MainActor final class GhostTextPanel {
    private let panel: GhostWindow
    private let textField = GhostLabel()
    private let hintBox = HintBadge()
    private let hintField = NSTextField(labelWithString: "\u{21E5}")

    private static let gap: CGFloat = 6
    private static let hintPadX: CGFloat = 4
    private static let ghostColor = NSColor(white: 0.42, alpha: 1)
    private static let hintTextColor = NSColor(white: 0.45, alpha: 0.85)
    private static let ellipsis = "\u{2026}"

    init() {
        panel = GhostWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let content = NSView()
        panel.contentView = content

        for field in [hintField] {
            field.isBezeled = false
            field.drawsBackground = false
            field.backgroundColor = .clear
            field.isEditable = false
            field.isSelectable = false
            field.usesSingleLineMode = true
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byClipping
        }
        textField.color = Self.ghostColor
        hintField.textColor = Self.hintTextColor

        hintBox.addSubview(hintField)

        content.addSubview(textField)
        content.addSubview(hintBox)
    }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    /// caret: insertion-point rectangle in Cocoa screen coordinates (origin bottom-left, height = line height).
    func show(_ text: String, caret: NSRect, fontSize: CGFloat? = nil, rightLimit: CGFloat? = nil) {
        guard place(text, caret: caret, fontSize: fontSize, rightLimit: rightLimit) else { hide(); return }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    // MARK: - Layout

    /// Sets text, hint and panel frame for the given caret. Returns false when nothing can be shown.
    @discardableResult
    private func place(_ text: String, caret: NSRect, fontSize: CGFloat? = nil, rightLimit: CGFloat? = nil) -> Bool {
        guard !text.isEmpty else { return false }

        let size = fontSize.map { min(40, max(9, $0)) } ?? Self.fontSize(for: caret)
        let font = NSFont.systemFont(ofSize: size)
        let hintFont = NSFont.systemFont(ofSize: max(9, (size * 0.6).rounded()))

        // Right edge of the screen the caret is on.
        let point = NSPoint(x: caret.midX, y: caret.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var maxX = (screen?.frame.maxX ?? caret.maxX + 800) - 4
        if let rightLimit { maxX = min(maxX, rightLimit - 2) }   // never past the field / window edge

        let x0 = caret.minX
        let avail = maxX - x0
        guard avail > size else { return false }

        let hintSize = Self.measure("\u{21E5}", hintFont)
        let hintW = ceil(hintSize.width) + 2 * Self.hintPadX
        let hintH = ceil(hintSize.height) + 2

        // Keep the hint whenever there is room for it plus a couple of characters.
        var withHint = true
        var budget = avail - Self.gap - hintW
        if budget <= size * 2 {
            withHint = false
            budget = avail
        }
        let shown = Self.truncate(text, font, to: budget)
        guard !shown.isEmpty else { return false }

        // Leading spaces are drawn as an explicit gap, independent of the app: at least a font space wide
        // (and not narrower than 0.32 em), plus 1 pt so the real caret bar does not swallow it.
        let spaces = shown.prefix { $0 == " " }
        let body = String(shown.dropFirst(spaces.count))
        let gapW = spaces.isEmpty ? 0 : max(Self.measure(String(spaces), font).width, size * 0.32 * CGFloat(spaces.count)) + 1
        let textSize = Self.measure(body, font)
        let textW = ceil(textSize.width + gapW)
        let textH = ceil(textSize.height)
        let totalW = textW + (withHint ? Self.gap + hintW : 0)
        let height = max(textH, hintH) + 2

        // Align baselines: the app's baseline sits about 0.21 × line height above the bottom of the caret
        // rect; our text field is `textH` tall and its baseline is `-descender` above its bottom edge.
        let baselineY = caret.minY + 0.21 * caret.height
        let fieldY = baselineY + font.descender
        let frame = NSRect(x: x0, y: (fieldY - (height - textH) / 2).rounded(), width: totalW, height: height)
        panel.setFrame(frame, display: true)

        textField.text = body
        textField.leadingGap = gapW
        textField.font = font
        textField.frame = NSRect(x: 0, y: (height - textH) / 2, width: textW, height: textH)

        hintBox.isHidden = !withHint
        hintField.font = hintFont
        hintBox.frame = NSRect(x: textW + Self.gap, y: (height - hintH) / 2, width: hintW, height: hintH)
        hintField.frame = NSRect(x: Self.hintPadX, y: (hintH - hintSize.height) / 2,
                                 width: hintSize.width, height: hintSize.height)
        return true
    }

    private static func fontSize(for caret: NSRect) -> CGFloat {
        min(28, max(10, (caret.height * 0.78).rounded()))
    }

    private static func measure(_ string: String, _ font: NSFont) -> NSSize {
        NSAttributedString(string: string, attributes: [.font: font]).size()
    }

    /// Longest prefix of `text` that fits `budget` points, with an ellipsis when cut. Empty if nothing fits.
    private static func truncate(_ text: String, _ font: NSFont, to budget: CGFloat) -> String {
        if measure(text, font).width <= budget { return text }
        let chars = Array(text)
        var lo = 0
        var hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measure(String(chars[..<mid]) + ellipsis, font).width <= budget { lo = mid } else { hi = mid - 1 }
        }
        if lo == 0 && measure(ellipsis, font).width > budget { return "" }
        return String(chars[..<lo]) + ellipsis
    }

#if DEBUG
    /// Writes ghost-light.png and ghost-dark.png into `directory` and prints the truncation check.
    static func renderPreview(to directory: URL) {
        let panel = GhostTextPanel()
        let typed = "Привет, это тестовая строка для "
        let suggestion = "проверки подсказки"
        let canvasSize = NSSize(width: 620, height: 100)
        let typedFont = NSFont.systemFont(ofSize: 16)

        let samples: [(name: String, bg: NSColor, fg: NSColor)] = [
            ("ghost-light", .white, .black),
            ("ghost-dark", NSColor(white: 0.12, alpha: 1), .white),
        ]
        for sample in samples {
            let caret = NSRect(x: 12 + measure(typed, typedFont).width, y: 38, width: 1.5, height: 20)
            panel.place(suggestion, caret: caret)
            let frame = panel.panel.frame
            guard let view = panel.panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)

            let canvas = NSImage(size: canvasSize)
            canvas.lockFocus()
            sample.bg.setFill()
            NSRect(origin: .zero, size: canvasSize).fill()
            NSAttributedString(string: typed, attributes: [.font: typedFont, .foregroundColor: sample.fg])
                .draw(at: NSPoint(x: 12, y: 38))
            rep.draw(in: NSRect(x: caret.minX + 1, y: caret.midY - frame.height / 2,
                                width: frame.width, height: frame.height))
            canvas.unlockFocus()

            if let tiff = canvas.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(sample.name + ".png"))
            }
        }

        // Truncation check: caret near the right edge of the main screen.
        let screenMaxX = NSScreen.main?.frame.maxX ?? 1440
        let edgeCaret = NSRect(x: screenMaxX - 200, y: 500, width: 1.5, height: 20)
        let long = String(repeating: "очень длинная подсказка ", count: 10)
        panel.place(long, caret: edgeCaret)
        print("truncated: \"\(panel.textField.text)\" frameMaxX=\(panel.panel.frame.maxX) screenMaxX=\(screenMaxX)")
    }
#endif
}
