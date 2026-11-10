// Text view of the «Перевод» page: placeholder, hover / click by character index (sentence pairs, variants),
// dropped files forwarded to the page.
import AppKit

final class PlaceholderTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderFont: NSFont = .systemFont(ofSize: 18)
    /// Character index under the mouse (nil: outside the text). Called on every move.
    var onHover: ((Int?) -> Void)?
    /// A plain click (no drag, no selection) landed on this character.
    var onClickAt: ((Int) -> Void)?
    /// A document file was dropped on the text.
    var onFileDrop: ((URL) -> Void)?
    var onFileDragTargeted: ((Bool) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        let rect = NSRect(origin: origin, size: NSSize(width: bounds.width - origin.x * 2, height: bounds.height))
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: [.font: placeholderFont, .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() { super.didChangeText(); needsDisplay = true }

    // MARK: Hover / click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self && a.userInfo?["pairs"] != nil { removeTrackingArea(a) }
        guard onHover != nil else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["pairs": true]))
    }

    /// Install / remove the hover callback and refresh the tracking area.
    func setHover(_ handler: ((Int?) -> Void)?) { onHover = handler; updateTrackingAreas() }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(characterIndex(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(nil) }

    override func mouseDown(with event: NSEvent) {
        let down = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard onClickAt != nil, event.clickCount == 1, selectedRange().length == 0,
              let i = characterIndex(at: down) else { return }
        onClickAt?(i)
    }

    func characterIndex(at point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard p.y >= used.minY, p.y <= used.maxY, p.x >= used.minX - 2, p.x <= used.maxX + 2 else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

    // MARK: Dropped files

    static func droppedFile(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onFileDrop != nil, Self.droppedFile(sender) != nil { onFileDragTargeted?(true); return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onFileDrop != nil, Self.droppedFile(sender) != nil { return .copy }
        return super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onFileDragTargeted?(false); super.draggingExited(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onFileDrop, let url = Self.droppedFile(sender) {
            onFileDragTargeted?(false)
            onFileDrop(url)
            return true
        }
        return super.performDragOperation(sender)
    }
}
