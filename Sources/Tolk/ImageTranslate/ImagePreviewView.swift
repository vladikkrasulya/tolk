// Owned by the "image" session. Image preview with the recognized paragraphs highlighted.
import AppKit

/// Shows an image aspect-fit and outlines recognized paragraphs. Hover highlights, click reports the index.
final class ImagePreviewView: NSView {
    var image: CGImage? { didSet { nsImage = image.map { NSImage(cgImage: $0, size: .zero) }; hovered = nil; needsDisplay = true } }
    /// Paragraph rectangles in image pixels (top-left origin).
    var boxes: [CGRect] = [] { didSet { hovered = nil; needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true } }
    var onClickBox: ((Int) -> Void)?

    private var nsImage: NSImage?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Изображение")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where the image is drawn inside the view.
    var imageRect: CGRect {
        guard let image else { return .zero }
        let inset = bounds.insetBy(dx: 12, dy: 12)
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, inset.width > 0, inset.height > 0 else { return .zero }
        let s = min(inset.width / iw, inset.height / ih)
        let w = iw * s, h = ih * s
        return CGRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h).integral
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        guard let image else { return .zero }
        let ir = imageRect
        let sx = ir.width / CGFloat(image.width), sy = ir.height / CGFloat(image.height)
        return CGRect(x: ir.minX + r.minX * sx, y: ir.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
            .insetBy(dx: -3, dy: -2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let nsImage else { return }
        let ir = imageRect
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: ir, xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: ir, xRadius: 4, yRadius: 4).addClip()
        nsImage.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()

        let accent = NSColor.controlAccentColor
        for (i, box) in boxes.enumerated() {
            let r = viewRect(box)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            let active = i == hovered || i == selected
            accent.withAlphaComponent(active ? 0.28 : 0.10).setFill()
            path.fill()
            accent.withAlphaComponent(active ? 0.95 : 0.55).setStroke()
            path.lineWidth = active ? 2 : 1
            path.stroke()
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func box(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return boxes.indices.last { viewRect(boxes[$0]).contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = onClickBox == nil ? nil : box(at: event)
        if hovered != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        if let i = box(at: event), let onClickBox { selected = i; onClickBox(i) }
    }
}

/// Rounded dashed frame for the empty state; turns accent while a drag hovers over it.
final class DropZoneView: NSView {
    var isTargeted = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        if isTargeted {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        (isTargeted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = isTargeted ? 2.5 : 1.5
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.stroke()
    }
}
