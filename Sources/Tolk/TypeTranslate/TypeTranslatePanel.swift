// The line under the text field of another app: the translation (≤ 3 lines), the language label and the key hint.
// A non-activating panel that never takes focus and ignores the mouse, like `GhostTextPanel`.
import AppKit
import TolkCore

enum TypeTranslateContent: Equatable {
    case translation(text: String, label: String)
    case error(String)
    case notice(String)
}

private final class TypeTranslateWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the card directly (no subviews/layers): identical on screen and in the offline render.
private final class TypeTranslateView: NSView {
    var content: TypeTranslateContent = .notice("") { didSet { needsDisplay = true } }

    static let padX: CGFloat = 10, padY: CGFloat = 7
    static let font = NSFont.systemFont(ofSize: 13)
    static let hintFont = NSFont.systemFont(ofSize: 11)
    static let chipFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    static let maxLines = 3
    static let chipGap: CGFloat = 8

    static func textWidth(forPanelWidth w: CGFloat, chip: String?) -> CGFloat {
        w - 2 * padX - (chip.map { chipSize($0).width + chipGap } ?? 0)
    }

    static func chipSize(_ s: String) -> NSSize {
        let t = NSAttributedString(string: s, attributes: [.font: chipFont]).size()
        return NSSize(width: ceil(t.width) + 10, height: ceil(t.height) + 2)
    }

    /// Wrapped text, at most `maxLines` lines, an ellipsis at the cut.
    static func layout(_ text: String, width: CGFloat, font: NSFont, maxLines: Int) -> (NSLayoutManager, NSTextContainer, NSTextStorage, NSSize) {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: max(20, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = .byTruncatingTail
        let lm = NSLayoutManager()
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        return (lm, container, storage, NSSize(width: ceil(used.width), height: ceil(used.height)))
    }

    /// Panel height for `content` at `width`.
    static func height(for content: TypeTranslateContent, width: CGFloat) -> CGFloat {
        switch content {
        case let .translation(text, label):
            let body = layout(text, width: textWidth(forPanelWidth: width, chip: label), font: font, maxLines: maxLines).3.height
            let hint = NSAttributedString(string: TypeTranslate.hint, attributes: [.font: hintFont]).size().height
            return ceil(body + 3 + hint) + 2 * padY
        case let .error(s), let .notice(s):
            return layout(s, width: width - 2 * padX, font: font, maxLines: 2).3.height + 2 * padY
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Self.background.setFill(); card.fill()
        Self.border.setStroke(); card.lineWidth = 1; card.stroke()
        switch content {
        case let .translation(text, label):
            let chip = Self.chipSize(label)
            let chipRect = NSRect(x: Self.padX, y: Self.padY + 1, width: chip.width, height: chip.height)
            Self.chipFill.setFill()
            NSBezierPath(roundedRect: chipRect, xRadius: 4, yRadius: 4).fill()
            NSAttributedString(string: label, attributes: [.font: Self.chipFont, .foregroundColor: Self.chipText])
                .draw(at: NSPoint(x: chipRect.minX + 5, y: chipRect.minY + 1))
            let x = Self.padX + chip.width + Self.chipGap
            let (lm, container, storage, size) = Self.layout(text, width: bounds.width - x - Self.padX, font: Self.font, maxLines: Self.maxLines)
            storage.addAttribute(.foregroundColor, value: Self.text, range: NSRange(location: 0, length: storage.length))
            let glyphs = lm.glyphRange(for: container)
            lm.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: x, y: Self.padY))
            NSAttributedString(string: TypeTranslate.hint, attributes: [.font: Self.hintFont, .foregroundColor: Self.hintColor])
                .draw(at: NSPoint(x: x, y: Self.padY + size.height + 3))
        case let .error(s):
            draw(s, color: Self.errorColor)
        case let .notice(s):
            draw(s, color: Self.text)
        }
    }

    private func draw(_ s: String, color: NSColor) {
        let (lm, container, storage, _) = Self.layout(s, width: bounds.width - 2 * Self.padX, font: Self.font, maxLines: 2)
        storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
        lm.drawGlyphs(forGlyphRange: lm.glyphRange(for: container), at: NSPoint(x: Self.padX, y: Self.padY))
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    static let background = dynamic(light: NSColor(white: 0.97, alpha: 0.98), dark: NSColor(white: 0.17, alpha: 0.98))
    static let border = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.16))
    static let text = dynamic(light: NSColor(white: 0.32, alpha: 1), dark: NSColor(white: 0.78, alpha: 1))
    static let hintColor = dynamic(light: NSColor(white: 0.52, alpha: 1), dark: NSColor(white: 0.55, alpha: 1))
    static let chipFill = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.12))
    static let chipText = dynamic(light: NSColor(white: 0.35, alpha: 1), dark: NSColor(white: 0.72, alpha: 1))
    static let errorColor = dynamic(light: NSColor(red: 0.72, green: 0.2, blue: 0.15, alpha: 1), dark: NSColor(red: 1, green: 0.55, blue: 0.48, alpha: 1))
}

@MainActor
final class TypeTranslatePanel {
    private let panel: TypeTranslateWindow
    private let view = TypeTranslateView()
    private(set) var content: TypeTranslateContent?

    static let minWidth: CGFloat = 300, maxWidth: CGFloat = 640, fallbackWidth: CGFloat = 440, gap: CGFloat = 4

    init() {
        panel = TypeTranslateWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view
    }

    var isVisible: Bool { panel.isVisible }
    var appearance: NSAppearance? { get { panel.appearance } set { panel.appearance = newValue } }

    /// Under the field (`fieldFrame`, Cocoa screen coordinates), else under the caret line; above when there is no room below.
    func show(_ content: TypeTranslateContent, fieldFrame: NSRect?, caret: NSRect?) {
        guard let anchor = fieldFrame ?? caret else { hide(); return }
        let frame = Self.frame(for: content, fieldFrame: fieldFrame, anchor: anchor, screen: Self.visibleFrame(containing: anchor))
        self.content = content
        view.content = content
        panel.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        content = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    private static func visibleFrame(containing r: NSRect) -> NSRect {
        let p = NSPoint(x: r.midX, y: r.midY)
        return (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Pure geometry (also used by the offline render).
    static func frame(for content: TypeTranslateContent, fieldFrame: NSRect?, anchor: NSRect, screen: NSRect) -> NSRect {
        let width = min(maxWidth, max(minWidth, fieldFrame?.width ?? fallbackWidth), screen.width - 8)
        let height = TypeTranslateView.height(for: content, width: width)
        var x = anchor.minX
        x = min(max(x, screen.minX + 4), screen.maxX - width - 4)
        var y = anchor.minY - gap - height
        if y < screen.minY + 2 { y = anchor.maxY + gap }                 // no room below: above the field
        y = min(y, screen.maxY - height - 2)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    /// Offline render: the card as an image at `width` (no window shown). `appearance` decides light / dark.
    static func image(for content: TypeTranslateContent, width: CGFloat, appearance: NSAppearance?) -> NSImage? {
        let height = TypeTranslateView.height(for: content, width: width)
        let v = TypeTranslateView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        v.content = content
        v.appearance = appearance
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.addRepresentation(rep)
        return img
    }
}
