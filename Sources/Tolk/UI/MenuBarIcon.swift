// Menu bar icon in the spirit of the app icon («Aurora»): a rounded T with an orbit and two language dots.
// Template image (one colour): macOS tints it for light/dark menu bars and the highlighted state.
import AppKit

enum MenuBarIcon {
    enum State { case ready, unavailable }

    static func image(_ state: State) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: cg, state: state)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = state == .ready ? "Tolk" : "Tolk — сервер недоступен"
        return img
    }

    /// Geometry in an 18×18 point box (origin bottom-left).
    static func draw(in cg: CGContext, state: State) {
        let black = NSColor.black.cgColor
        cg.setFillColor(black)
        cg.setStrokeColor(black)

        // T: rounded bar + stem
        let bar = CGPath(roundedRect: CGRect(x: 5.0, y: 12.3, width: 8.0, height: 2.5), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil)
        let stem = CGPath(roundedRect: CGRect(x: 7.75, y: 3.4, width: 2.5, height: 10.6), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil)

        // Orbit: tilted ellipse around the centre
        var t = CGAffineTransform(translationX: 9, y: 9).rotated(by: 0.40)
        let orbit = CGPath(ellipseIn: CGRect(x: -8.4, y: -3.5, width: 16.8, height: 7.0), transform: &t)

        // 1) orbit (dashed when the server is down)
        cg.saveGState()
        cg.addPath(orbit)
        cg.setLineWidth(1.1)
        if state == .unavailable { cg.setLineDash(phase: 0, lengths: [1.6, 1.4]) }
        cg.strokePath()
        cg.restoreGState()

        // 2) knock a gap around the T so the orbit passes "behind" it
        cg.saveGState()
        cg.setBlendMode(.clear)
        for p in [bar, stem] {
            cg.addPath(p)
            cg.setLineWidth(1.4)
            cg.replacePathWithStrokedPath()
            cg.fillPath()
            cg.addPath(p); cg.fillPath()
        }
        cg.restoreGState()

        // 3) the T itself
        cg.addPath(bar); cg.fillPath()
        cg.addPath(stem); cg.fillPath()

        // 4) two language dots on the orbit (hollow when the server is down)
        for angle in [CGFloat.pi * 0.93, -CGFloat.pi * 0.07] {
            let local = CGPoint(x: cos(angle) * 8.4, y: sin(angle) * 3.5)
            let p = local.applying(CGAffineTransform(rotationAngle: 0.40)).applying(CGAffineTransform(translationX: 9, y: 9))
            let r: CGFloat = 1.75
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            // clear a ring so the dot reads separately from the orbit line
            cg.saveGState()
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: rect.insetBy(dx: -0.6, dy: -0.6))
            cg.restoreGState()
            if state == .ready {
                cg.fillEllipse(in: rect)
            } else {
                cg.setLineWidth(1.0)
                cg.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }

    #if DEBUG
    /// Dev: PNG preview on light and dark bars at 1×, 2× and an enlarged view.
    static func renderPreview(to path: String) {
        let w = 560, h = 150
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        for (i, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
            let y = CGFloat(i) * 75
            cg.setFillColor(bg.cgColor); cg.fill(CGRect(x: 0, y: y, width: CGFloat(w), height: 75))
            for (j, state) in [State.ready, .unavailable].enumerated() {
                for (k, scale) in [CGFloat(1), 2, 3.6].enumerated() {
                    let x = CGFloat(j * 280 + [16, 50, 110][k])
                    let layer = CGLayer(cg, size: CGSize(width: 18 * scale, height: 18 * scale), auxiliaryInfo: nil)!
                    let lc = layer.context!
                    lc.scaleBy(x: scale, y: scale)
                    draw(in: lc, state: state)
                    lc.setBlendMode(.sourceIn); lc.setFillColor(fg.cgColor); lc.fill(CGRect(x: 0, y: 0, width: 18, height: 18))
                    cg.draw(layer, at: CGPoint(x: x, y: y + (75 - 18 * scale) / 2))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}
