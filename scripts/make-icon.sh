#!/bin/bash
# Draws the app icon with CoreGraphics (Swift script) and packs it into Resources/AppIcon.icns.
# Usage: scripts/make-icon.sh [output.icns]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/Resources/AppIcon.icns}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

cat > "$WORK/draw.swift" <<'SWIFT'
// "Aurora": night sky with aurora blobs, glowing rounded T, orbit with two language dots (A / Я).
import AppKit

let space = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a).cgColor }

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let f = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor, size: size) ?? f
}

func drawText(_ cg: CGContext, _ text: String, center: CGPoint, font: NSFont, color: CGColor) {
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
    let line = CTLineCreateWithAttributedString(str)
    cg.textMatrix = .identity
    let b = CTLineGetImageBounds(line, cg)
    cg.textPosition = CGPoint(x: center.x - b.width/2 - b.minX, y: center.y - b.height/2 - b.minY)
    CTLineDraw(line, cg)
}

func blob(_ cg: CGContext, _ p: CGPoint, _ r: CGFloat, _ color: CGColor) {
    let g = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
}

/// Common frame: shadow + rounded body clip. `paint` draws inside the clipped body.
func icon(_ px: Int, _ paint: (CGContext, CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: CGFloat(px)/1024, y: CGFloat(px)/1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0,0,0,0.32))
    cg.addPath(path); cg.setFillColor(c(0,0,0)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState(); cg.addPath(path); cg.clip()
    paint(cg, body)
    // glass edge highlight
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(path); cg.setStrokeColor(c(255,255,255,0.18)); cg.setLineWidth(3); cg.strokePath()
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// V1 Aurora: deep night sky with aurora blobs, glowing rounded T, orbit with two "language" dots.
func v1(_ px: Int) -> NSBitmapImageRep { icon(px) { cg, b in
    let bg = CGGradient(colorsSpace: space, colors: [c(14,16,48), c(28,20,78), c(10,12,36)] as CFArray, locations: [0, 0.6, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    blob(cg, CGPoint(x: 260, y: 760), 420, c(0, 220, 200, 0.55))
    blob(cg, CGPoint(x: 780, y: 820), 380, c(120, 90, 255, 0.60))
    blob(cg, CGPoint(x: 720, y: 260), 420, c(255, 70, 160, 0.45))
    blob(cg, CGPoint(x: 300, y: 250), 300, c(60, 120, 255, 0.40))
    // stars
    for (x, y, r) in [(220.0, 860.0, 4.0), (840.0, 700.0, 3.0), (180.0, 420.0, 3.0), (870.0, 420.0, 4.0), (640.0, 880.0, 3.0), (380.0, 180.0, 3.0)] {
        cg.setFillColor(c(255,255,255,0.8)); cg.fillEllipse(in: CGRect(x: x, y: y, width: r*2, height: r*2))
    }
    // orbit ellipse
    cg.saveGState()
    cg.translateBy(x: 512, y: 512); cg.rotate(by: -0.42)
    cg.setStrokeColor(c(255,255,255,0.55)); cg.setLineWidth(10)
    cg.strokeEllipse(in: CGRect(x: -330, y: -120, width: 660, height: 240))
    cg.restoreGState()
    // T with glow
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 60, color: c(150, 220, 255, 0.9))
    drawText(cg, "T", center: CGPoint(x: 512, y: 500), font: roundedFont(560, .heavy), color: c(255,255,255))
    cg.restoreGState()
    // dots on the orbit (front, drawn over T)
    func dot(_ angle: CGFloat, _ col: CGColor, _ label: String) {
        let ex = cos(angle) * 330, ey = sin(angle) * 120
        let rot: CGFloat = -0.42
        let x = 512 + ex*cos(rot) - ey*sin(rot), y = 512 + ex*sin(rot) + ey*cos(rot)
        cg.saveGState(); cg.setShadow(offset: .zero, blur: 24, color: col)
        cg.setFillColor(col); cg.fillEllipse(in: CGRect(x: x-50, y: y-50, width: 100, height: 100)); cg.restoreGState()
        drawText(cg, label, center: CGPoint(x: x, y: y), font: roundedFont(54, .bold), color: c(255,255,255))
    }
    dot(.pi * 0.92, c(0, 200, 190), "A")
    dot(-.pi * 0.10, c(255, 80, 160), "Я")
}}


let dir = CommandLine.arguments[1]
for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! v1(base * sc).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }
}
try! v1(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/../preview-1024.png"))
SWIFT

echo "==> drawing icon PNGs"
swift "$WORK/draw.swift" "$ICONSET"
echo "==> iconutil -> $OUT"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
if [ -n "${TOLK_ICON_PREVIEW:-}" ]; then cp "$WORK/preview-1024.png" "$TOLK_ICON_PREVIEW"; fi
echo "==> done: $OUT"
