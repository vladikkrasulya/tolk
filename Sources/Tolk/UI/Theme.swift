// Colour themes. Five palettes, each in a light and a dark variant; which variant is drawn follows the system
// (light / dark mode). Plus «Классика» — the colours of macOS, the way Tolk looked before themes.
//
// Every colour here is a dynamic NSColor: it is resolved at draw time for the appearance of the view and the palette
// chosen now, so code keeps one name (`Theme.accent`) and a palette switch only needs a redraw (`Theme.apply`).
import AppKit
import SwiftUI

enum ThemePalette: String, CaseIterable, Sendable {
    case jade, milk, coffee, butter, rose, classic

    var title: String {
        switch self {
        case .jade: "Нефрит"
        case .milk: "Молоко и синий"
        case .coffee: "Кофе и лазурь"
        case .butter: "Масло и томат"
        case .rose: "Роза и шоколад"
        case .classic: "Классика"
        }
    }

    var note: String {
        switch self {
        case .jade: "Почти белый фон и приглушённый нефрит. Самая спокойная — глаза меньше всего устают за день."
        case .milk: "Молочный фон и насыщенный синий. Чётко видно, где кнопка и что выбрано."
        case .coffee: "Тёплый бежевый фон и лазурь. Тёпло и с характером."
        case .butter: "Сливочно-жёлтый, синий и томатный. Самая яркая."
        case .rose: "Пудрово-розовый и шоколад. Мягкая и тёплая."
        case .classic: "Цвета macOS и ваш системный акцент — как Tolk выглядел раньше."
        }
    }

    static let `default`: ThemePalette = .jade
}

/// One variant (light or dark) of a palette. Hex strings, `nil` only in «Классика», which uses system colours.
struct ThemeColors {
    var page, card, side, well, ink, ink2, ink3, line, line2: UInt32
    var accent, accentStrong, accentSoft, accentInk, hero: UInt32
    var second, secondSoft, secondInk: UInt32
    var ok, okSoft, okInk: UInt32
}

enum Theme {
    /// The palette drawn now. Read from any thread by the colour providers, written on the main thread.
    nonisolated(unsafe) static var palette: ThemePalette = .default

    // MARK: Tokens

    /// Window and page background.
    static let page = dyn(\.page) { .windowBackgroundColor }
    /// Cards, text fields, panels.
    static let card = dyn(\.card) { NSColor(name: nil) { $0.isDark ? NSColor(white: 0.17, alpha: 1) : .white } }
    /// Sidebar of the main window.
    static let side = dyn(\.side) { .clear }
    /// Tiles and wells inside a card.
    static let well = dyn(\.well) { NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.055) } }
    static let ink = dyn(\.ink) { .labelColor }
    static let ink2 = dyn(\.ink2) { .secondaryLabelColor }
    static let ink3 = dyn(\.ink3) { .tertiaryLabelColor }
    static let line = dyn(\.line) { .separatorColor }
    static let line2 = dyn(\.line2) { .separatorColor }
    /// Icons, selection, chart lines, links in the UI.
    static let accent = dyn(\.accent) { .controlAccentColor }
    /// Filled buttons (white text on it).
    static let accentStrong = dyn(\.accentStrong) { .controlAccentColor }
    static let accentSoft = dyn(\.accentSoft) { NSColor.controlAccentColor.withAlphaComponent(0.14) }
    static let accentInk = dyn(\.accentInk) { .controlAccentColor }
    /// The one filled tile per page (white text on it).
    static let hero = dyn(\.hero) { .controlAccentColor }
    /// Second colour: glossary terms, the second series of a chart.
    static let second = dyn(\.second) { .systemOrange }
    static let secondSoft = dyn(\.secondSoft) { NSColor.systemOrange.withAlphaComponent(0.14) }
    static let secondInk = dyn(\.secondInk) { .systemOrange }
    /// «Всё работает».
    static let ok = dyn(\.ok) { .systemGreen }
    static let okSoft = dyn(\.okSoft) { NSColor.systemGreen.withAlphaComponent(0.14) }
    static let okInk = dyn(\.okInk) { .systemGreen }
    /// Background laid over the translucent material of the floating panels; clear in «Классика».
    static let panel = dyn(\.card) { .clear }

    // SwiftUI twins.
    static var pageC: Color { Color(nsColor: page) }
    static var cardC: Color { Color(nsColor: card) }
    static var wellC: Color { Color(nsColor: well) }
    static var inkC: Color { Color(nsColor: ink) }
    static var ink2C: Color { Color(nsColor: ink2) }
    static var ink3C: Color { Color(nsColor: ink3) }
    static var lineC: Color { Color(nsColor: line) }
    static var accentC: Color { Color(nsColor: accent) }
    static var accentStrongC: Color { Color(nsColor: accentStrong) }
    static var accentSoftC: Color { Color(nsColor: accentSoft) }
    static var accentInkC: Color { Color(nsColor: accentInk) }
    static var heroC: Color { Color(nsColor: hero) }
    static var secondC: Color { Color(nsColor: second) }
    static var secondSoftC: Color { Color(nsColor: secondSoft) }
    static var secondInkC: Color { Color(nsColor: secondInk) }
    static var okC: Color { Color(nsColor: ok) }
    static var okSoftC: Color { Color(nsColor: okSoft) }
    static var okInkC: Color { Color(nsColor: okInk) }

    /// Is the chosen palette one of the five (not «Классика»)?
    static var isCustom: Bool { palette != .classic }

    // MARK: Switching

    /// Switches the palette and redraws every window. Dynamic colours re-resolve on the redraw; views that cache a
    /// CGColor (layers) redo it in `viewDidChangeEffectiveAppearance`, which the appearance flip below triggers.
    @MainActor static func apply(_ p: ThemePalette) {
        guard p != palette else { return }
        palette = p
        for w in NSApp.windows {
            let a = w.appearance
            w.appearance = NSAppearance(named: (w.effectiveAppearance.isDark ? .aqua : .darkAqua))
            w.appearance = a
            w.contentView?.needsDisplay = true
            w.invalidateShadow()
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static let changed = Notification.Name("TolkThemeChanged")

    // MARK: Palettes

    static func colors(_ p: ThemePalette, dark: Bool) -> ThemeColors? {
        switch (p, dark) {
        case (.classic, _): return nil
        case (.jade, false): return .init(page: 0xF0EEE6, card: 0xFCFBF7, side: 0xF6F5EF, well: 0xE9E7DE, ink: 0x17231F, ink2: 0x55615C, ink3: 0x99A096, line: 0xE1DFD5, line2: 0xCBCABE,
                                          accent: 0x3A8A79, accentStrong: 0x2D7264, accentSoft: 0xDCEDE7, accentInk: 0x1F5A4D, hero: 0x2D7264,
                                          second: 0xB97F4E, secondSoft: 0xF4E8DC, secondInk: 0x7A4F2A, ok: 0x4C9A5E, okSoft: 0xE0EFE1, okInk: 0x2C5F37)
        case (.jade, true): return .init(page: 0x0E1412, card: 0x16201C, side: 0x121A17, well: 0x202B27, ink: 0xE8EEEA, ink2: 0x9CA9A3, ink3: 0x66726D, line: 0x23302B, line2: 0x35443E,
                                         accent: 0x7CC9B6, accentStrong: 0x2D7264, accentSoft: 0x163430, accentInk: 0xB6E6DA, hero: 0x2D7264,
                                         second: 0xE0AE80, secondSoft: 0x3A2A1C, secondInk: 0xF2D2B3, ok: 0x86CF94, okSoft: 0x17301D, okInk: 0xBDE8C5)
        case (.milk, false): return .init(page: 0xF0EEE9, card: 0xFBFAF7, side: 0xF6F4EF, well: 0xE9E6DF, ink: 0x121218, ink2: 0x55555F, ink3: 0x9A988F, line: 0xE2DFD7, line2: 0xCFCBC1,
                                          accent: 0x2A25F3, accentStrong: 0x2A25F3, accentSoft: 0xE4E3FD, accentInk: 0x1D19B0, hero: 0x2A25F3,
                                          second: 0xD08A1E, secondSoft: 0xFBEFD9, secondInk: 0x87560C, ok: 0x1F9D78, okSoft: 0xDFF2EA, okInk: 0x0D654D)
        case (.milk, true): return .init(page: 0x0C0C13, card: 0x15151F, side: 0x11111A, well: 0x1F1F2C, ink: 0xEEEDE8, ink2: 0xA1A0AB, ink3: 0x686774, line: 0x25253A, line2: 0x3A3A55,
                                         accent: 0x8A87FF, accentStrong: 0x3B36F5, accentSoft: 0x1E1C55, accentInk: 0xCFCDFF, hero: 0x2A25F3,
                                         second: 0xF2B65A, secondSoft: 0x3A2C14, secondInk: 0xF8D69C, ok: 0x4FD1A9, okSoft: 0x11342A, okInk: 0xA2EBD3)
        case (.coffee, false): return .init(page: 0xE8DDCF, card: 0xF8F3EC, side: 0xF1E8DD, well: 0xE2D6C7, ink: 0x2A1D15, ink2: 0x6A5647, ink3: 0xA08E7D, line: 0xDCCEBC, line2: 0xC6B5A0,
                                            accent: 0x0E8CDB, accentStrong: 0x0A72B8, accentSoft: 0xD7EBF9, accentInk: 0x0A5A91, hero: 0x0A72B8,
                                            second: 0x8C5A3C, secondSoft: 0xEEDFD2, secondInk: 0x5E3A24, ok: 0x3C9A6E, okSoft: 0xDFF0E6, okInk: 0x245F43)
        case (.coffee, true): return .init(page: 0x16110D, card: 0x211A14, side: 0x1B1511, well: 0x2D241C, ink: 0xF1E8DC, ink2: 0xB7A797, ink3: 0x7A6B5D, line: 0x30271E, line2: 0x46392D,
                                           accent: 0x4FC3FF, accentStrong: 0x0A72B8, accentSoft: 0x10324A, accentInk: 0xB3E2FF, hero: 0x0A72B8,
                                           second: 0xD2A07C, secondSoft: 0x3A2A1F, secondInk: 0xEED1B9, ok: 0x6FD1A2, okSoft: 0x14322A, okInk: 0xB2EAD0)
        case (.butter, false): return .init(page: 0xF6EBBE, card: 0xFFFBEA, side: 0xFBF3D2, well: 0xF1E5B5, ink: 0x16182B, ink2: 0x5B5745, ink3: 0x9A9070, line: 0xEADCA3, line2: 0xD5C584,
                                            accent: 0x1F3BD6, accentStrong: 0x1F3BD6, accentSoft: 0xDCE2FB, accentInk: 0x16299A, hero: 0x1F3BD6,
                                            second: 0xE5432D, secondSoft: 0xFBDCD5, secondInk: 0x9A2412, ok: 0x2E8B57, okSoft: 0xDDEFE2, okInk: 0x1B5E37)
        case (.butter, true): return .init(page: 0x14130D, card: 0x1F1D14, side: 0x1A1810, well: 0x2B281C, ink: 0xF7EFCF, ink2: 0xB9B08C, ink3: 0x7A745C, line: 0x302D20, line2: 0x47432F,
                                           accent: 0xF2D46B, accentStrong: 0x2E49E0, accentSoft: 0x3A3216, accentInk: 0xF8E6A6, hero: 0x2E49E0,
                                           second: 0xFF7A63, secondSoft: 0x3E1C16, secondInk: 0xFFC1B5, ok: 0x5DC48A, okSoft: 0x15301F, okInk: 0xA9E6C1)
        case (.rose, false): return .init(page: 0xF1E1DE, card: 0xFCF6F5, side: 0xF7EBE9, well: 0xECDAD6, ink: 0x2B1915, ink2: 0x6E514B, ink3: 0xA38883, line: 0xE5D0CC, line2: 0xD1B6B0,
                                          accent: 0x5A3328, accentStrong: 0x4A2A21, accentSoft: 0xEBDCD6, accentInk: 0x4A2A21, hero: 0x4A2A21,
                                          second: 0xC46F7D, secondSoft: 0xF6DDE1, secondInk: 0x8A3E4B, ok: 0x6E9A6A, okSoft: 0xE3EDE0, okInk: 0x3F6239)
        case (.rose, true): return .init(page: 0x1A110E, card: 0x241915, side: 0x1F1512, well: 0x30221D, ink: 0xF4E6E3, ink2: 0xC1A8A2, ink3: 0x866C66, line: 0x35261F, line2: 0x4A362E,
                                         accent: 0xE8A5AF, accentStrong: 0x8A4A40, accentSoft: 0x3E2228, accentInk: 0xF6CCD3, hero: 0x6B3B30,
                                         second: 0xD9B08C, secondSoft: 0x3A2A1D, secondInk: 0xF0D5BC, ok: 0x93C48C, okSoft: 0x1E2F1C, okInk: 0xC8E6C2)
        }
    }

    /// Light and dark swatches of a palette for the picker: page, card, accent, second.
    static func swatch(_ p: ThemePalette, dark: Bool) -> [NSColor] {
        guard let c = colors(p, dark: dark) else {
            return dark ? [NSColor(white: 0.12, alpha: 1), NSColor(white: 0.17, alpha: 1), .controlAccentColor, .systemOrange]
                        : [NSColor(white: 0.93, alpha: 1), .white, .controlAccentColor, .systemOrange]
        }
        return [c.page, c.card, c.accent, c.second].map(NSColor.init(hex:))
    }

    // MARK: Plumbing

    private static func dyn(_ key: KeyPath<ThemeColors, UInt32>, classic: @escaping @Sendable () -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            guard let c = colors(palette, dark: appearance.isDark) else {
                var out = NSColor.clear
                appearance.performAsCurrentDrawingAppearance { out = classic().usingColorSpace(.sRGB) ?? classic() }
                return out
            }
            return NSColor(hex: c[keyPath: key])
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A view that fills itself with a dynamic colour and keeps it right when the appearance or the palette changes
/// (a layer keeps a CGColor, which does not follow the appearance by itself).
final class ThemeFillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var radius: CGFloat { didSet { needsDisplay = true } }

    init(_ color: NSColor, radius: CGFloat = 0) {
        self.color = color
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        if radius > 0 { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() } else { bounds.fill() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Puts a fill under everything else in `parent`, edge to edge.
    @discardableResult static func underlay(_ parent: NSView, color: NSColor, radius: CGFloat = 0) -> ThemeFillView {
        let f = ThemeFillView(color, radius: radius)
        f.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(f, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: parent.leadingAnchor), f.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            f.topAnchor.constraint(equalTo: parent.topAnchor), f.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
        return f
    }
}
