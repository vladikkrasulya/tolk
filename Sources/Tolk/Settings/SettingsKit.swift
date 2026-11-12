// Building blocks of the settings page — and the app's shared look: cards on a quiet page, hairline borders,
// 12 pt corners, small status pills, a hint under every control, grey example tiles.
import SwiftUI
import AppKit

/// One place for the sizes and colours every screen uses (SwiftUI and AppKit).
enum TolkStyle {
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 8
    static let cardPadding: CGFloat = 16
    static let gap: CGFloat = 16

    static var page: Color { Theme.pageC }
    static var card: Color { Theme.cardC }
    static var tile: Color { Theme.wellC }
    static var hairline: Color { Theme.lineC }

    static var nsCard: NSColor { Theme.card }
    static var nsTile: NSColor { Theme.well }
}

/// Icon in a small tinted square: the mark of a card or a section.
struct SIconBadge: View {
    let symbol: String
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Theme.accentInkC)
            .frame(width: size, height: size)
            .background(Theme.accentSoftC, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

// MARK: - Layout

/// Cards in as many equal columns as fit: each card goes to the shortest column. A card marked `.fullSpan()` takes the whole row.
struct MasonryLayout: Layout {
    var minColumn: CGFloat = 340
    var maxColumns = 3
    var spacing: CGFloat = TolkStyle.gap

    private struct SpanKey: LayoutValueKey { static let defaultValue = false }
    static func span<V: View>(_ v: V) -> some View { v.layoutValue(key: SpanKey.self, value: true) }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let maxN = max(1, min(maxColumns, Int((width + spacing) / (minColumn + spacing))))
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        var i = 0
        while i < subviews.count {
            if subviews[i][SpanKey.self] {
                let h = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                frames[i] = CGRect(x: 0, y: y, width: width, height: h)
                y += h + spacing
                i += 1
                continue
            }
            // A group of cards up to the next full-width item: never more columns than cards, so a short group
            // spreads over the whole width instead of leaving empty columns.
            var j = i
            while j < subviews.count, !subviews[j][SpanKey.self] { j += 1 }
            let n = min(maxN, j - i)
            let colW = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
            var heights = [CGFloat](repeating: y, count: n)
            for k in i..<j {
                let c = heights.indices.min { heights[$0] < heights[$1] } ?? 0
                let h = subviews[k].sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
                frames[k] = CGRect(x: CGFloat(c) * (colW + spacing), y: heights[c], width: colW, height: h)
                heights[c] += h + spacing
            }
            y = heights.max() ?? y
            i = j
        }
        return (frames, max(0, y - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 800
        return CGSize(width: w, height: arrange(width: w, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (s, f) in zip(subviews, frames) {
            s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

extension View {
    /// In a `MasonryLayout`: take the whole width.
    func fullSpan() -> some View { MasonryLayout.span(self) }
}

/// Items left to right, wrapping to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        var points: [CGPoint] = []
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + line))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = arrange(width: bounds.width, subviews: subviews).points
        for (s, p) in zip(subviews, points) {
            s.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), anchor: .topLeading, proposal: .unspecified)
        }
    }
}

// MARK: - Card and rows

struct SCard<Content: View, Trailing: View>: View {
    let title: String
    let symbol: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, symbol: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.subtitle = subtitle; self.trailing = trailing; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                SIconBadge(symbol: symbol)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                trailing()
            }
            if let subtitle { SHint(subtitle).padding(.top, 6) }
            content().padding(.top, 12)
        }
        .padding(TolkStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TolkStyle.card, in: RoundedRectangle(cornerRadius: TolkStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TolkStyle.cardRadius, style: .continuous).strokeBorder(TolkStyle.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(Theme.isCustom ? 0.05 : 0), radius: 10, x: 0, y: 3)
    }
}

extension SCard where Trailing == EmptyView {
    init(_ title: String, symbol: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, symbol: symbol, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// Heading of a group of cards inside a tab: a strong rule, a coloured icon and a large title. Takes the whole row;
/// the cards under it start a fresh set of columns.
struct SSection: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    /// The first section of a page needs no rule and no extra air above it.
    var first = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first {
                Rectangle().fill(Theme.lineC).frame(height: 1).padding(.bottom, 16)
            }
            HStack(alignment: .center, spacing: 11) {
                if let symbol { SIconBadge(symbol: symbol, size: 32) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 20, weight: .bold)).tracking(-0.3)
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, first ? 2 : 18).padding(.bottom, 2).padding(.horizontal, 2)
        .fullSpan()
    }
}

/// Every section of a tab, one under another: heading, then its cards.
struct SSections<Cards: View>: View {
    let tab: SettingsTab
    @ViewBuilder var cards: (Int) -> Cards

    var body: some View {
        ForEach(0..<tab.sections.count, id: \.self) { i in
            SSection(title: tab.sections[i].title, subtitle: tab.sections[i].note, symbol: tab.sections[i].symbol, first: i == 0)
            cards(i)
        }
    }
}

/// Explanation under a setting.
struct SHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grey tile with an example («Пример: …»). `ghost` is drawn the way a suggestion looks.
struct SExample: View {
    var label = "Пример"
    let text: String
    var ghost: String?

    var body: some View {
        (Text(label + ": ").foregroundStyle(.secondary) + Text(text) + Text(ghost ?? "").foregroundStyle(.tertiary))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(TolkStyle.tile, in: RoundedRectangle(cornerRadius: TolkStyle.controlRadius, style: .continuous))
    }
}

/// One setting: title on the left, control on the right, then the hint and an example. A hairline separates it from the row above.
struct SRow<Control: View>: View {
    let title: String
    var hint: String?
    var example: SExample?
    var divider = true
    @ViewBuilder var control: () -> Control

    init(_ title: String, hint: String? = nil, example: SExample? = nil, divider: Bool = true, @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.hint = hint; self.example = example; self.divider = divider; self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if divider { Rectangle().fill(TolkStyle.hairline).frame(height: 0.5).padding(.bottom, 4) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).fixedSize()
                    Spacer(minLength: 8)
                    control()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    control()
                }
            }
            if let hint { SHint(hint) }
            if let example { example }
        }
        .padding(.bottom, 8)
    }
}

struct SToggle: View {
    let title: String
    @Binding var isOn: Bool
    var hint: String?
    /// Shown instead of `hint` while the switch is off («что будет, если выключить»).
    var offHint: String?
    var example: SExample?
    var divider = true

    init(_ title: String, isOn: Binding<Bool>, hint: String? = nil, offHint: String? = nil, example: SExample? = nil, divider: Bool = true) {
        self.title = title; self._isOn = isOn; self.hint = hint; self.offHint = offHint; self.example = example; self.divider = divider
    }

    var body: some View {
        SRow(title, hint: isOn ? hint : (offHint ?? hint), example: example, divider: divider) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A choice where the hint under it describes the option that is selected now.
struct SChoice<Value: Hashable>: View {
    struct Option { let value: Value; let title: String; let effect: String }
    let title: String
    @Binding var selection: Value
    let options: [Option]
    var example: ((Value) -> SExample?)?
    var divider = true

    var body: some View {
        SRow(title, hint: options.first { $0.value == selection }?.effect, example: example?(selection), divider: divider) {
            Picker("", selection: $selection) {
                ForEach(0..<options.count, id: \.self) { Text(options[$0].title).tag(options[$0].value) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

/// Slider with the value on the right.
struct SSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var hint: String?
    var divider = true

    var body: some View {
        SRow(title, hint: hint, divider: divider) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step).frame(width: 150)
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
            }
        }
    }
}

// MARK: - Small pieces

enum SRole { case neutral, ok, warn, bad, accent
    var color: Color {
        switch self {
        case .neutral: Theme.ink2C
        case .ok: Theme.okC
        case .warn: .orange
        case .bad: .red
        case .accent: Theme.accentC
        }
    }
    var soft: Color {
        switch self {
        case .neutral: Theme.wellC
        case .ok: Theme.okSoftC
        case .warn: Color.orange.opacity(0.15)
        case .bad: Color.red.opacity(0.14)
        case .accent: Theme.accentSoftC
        }
    }
    var ink: Color {
        switch self {
        case .neutral: Theme.ink2C
        case .ok: Theme.okInkC
        case .warn: .orange
        case .bad: .red
        case .accent: Theme.accentInkC
        }
    }
}

struct SPill: View {
    let text: String
    var symbol: String?
    var role: SRole = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(role.ink)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(role.soft, in: Capsule())
    }
}

/// Ready-made phrases; a click adds one.
struct SChips: View {
    let items: [String]
    let isUsed: (String) -> Bool
    let add: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                let used = isUsed(item)
                Button { add(item) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: used ? "checkmark" : "plus").imageScale(.small)
                        Text(item)
                    }
                    .font(.callout)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .foregroundStyle(used ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accentInkC))
                    .background(used ? Theme.wellC : Theme.accentSoftC, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(used)
                .help(used ? "Уже добавлено" : "Добавить в инструкции")
            }
        }
    }
}

/// Colour of a number tile. `hero`: the one filled tile of a page, white on the theme colour.
enum STone { case neutral, accent, second, ok, hero }

/// Number tile: icon and caption on top, big value, optional note.
struct STile: View {
    let caption: String
    let value: String
    var note: String?
    var symbol: String?
    var tone: STone = .neutral

    private var bg: Color {
        switch tone {
        case .neutral: TolkStyle.tile
        case .accent: Theme.accentSoftC
        case .second: Theme.secondSoftC
        case .ok: Theme.okSoftC
        case .hero: Theme.heroC
        }
    }
    private var ink: Color {
        switch tone {
        case .neutral: Theme.inkC
        case .accent: Theme.accentInkC
        case .second: Theme.secondInkC
        case .ok: Theme.okInkC
        case .hero: .white
        }
    }
    private var sub: AnyShapeStyle { tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(ink.opacity(0.82)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(caption).lineLimit(1)
            }
            .font(.callout.weight(.medium)).foregroundStyle(sub)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(ink)
            if let note { Text(note).font(.caption).foregroundStyle(sub).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(bg, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// Tiles in a grid that adapts to the width.
struct STileGrid<Content: View>: View {
    var minTile: CGFloat = 140
    @ViewBuilder var content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minTile), spacing: 8)], alignment: .leading, spacing: 8) { content() }
    }
}

/// Thin progress bar with a caption under it.
struct SProgress: View {
    let fraction: Double
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.wellC)
                    Capsule().fill(Theme.accentC).frame(width: max(4, g.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Horizontal share bar: label, bar, value.
struct SShareRow: View {
    let label: String
    let value: Int
    let total: Int
    var note: String?
    var color: Color = Theme.accentC

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(value)").monospacedDigit().foregroundStyle(.secondary)
                Text(total > 0 ? "\(Int((Double(value) / Double(total) * 100).rounded())) %" : "—")
                    .fontWeight(.semibold).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .font(.callout)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.wellC)
                    Capsule().fill(color)
                        .frame(width: total > 0 ? max(4, g.size.width * CGFloat(value) / CGFloat(total)) : 0)
                }
            }
            .frame(height: 6)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 4)
    }
}

/// A ring of shares with the biggest one in the middle, and a legend under it.
struct SDonut: View {
    let rows: [(String, Int)]
    var centerNote = ""
    static let palette: [Color] = [Theme.accentC, Theme.secondC, Theme.okC, Theme.ink3C]

    var body: some View {
        let sorted = rows.sorted { $0.1 > $1.1 }
        let total = max(1, sorted.map(\.1).reduce(0, +))
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.wellC, lineWidth: 14)
                ForEach(Array(sorted.prefix(4).enumerated()), id: \.offset) { i, r in
                    let start = Double(sorted.prefix(i).map(\.1).reduce(0, +)) / Double(total)
                    let end = start + Double(r.1) / Double(total)
                    Circle().trim(from: start + 0.004, to: max(start + 0.004, end - 0.004))
                        .stroke(Self.palette[i], style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text("\(Int((Double(sorted.first?.1 ?? 0) / Double(total) * 100).rounded())) %")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(centerNote.isEmpty ? (sorted.first?.0 ?? "") : centerNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(sorted.prefix(4).enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2.5).fill(Self.palette[i]).frame(width: 10, height: 10)
                        Text(r.0).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(r.1)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Smooth chart per day: `front` as the main line with a fill; `back` (when it differs) as a second, lighter one.
/// Days marked `mark` get a dashed rule. Hover shows the day and its numbers.
struct SDayChart: View {
    struct Bar: Identifiable { let id: String; let back: Int; let front: Int; var mark = false }
    let bars: [Bar]
    var height: CGFloat = 120
    var frontName = ""
    var backName = ""
    @State private var hover: Int?

    static func short(_ day: String) -> String { String(day.suffix(5)).split(separator: "-").reversed().joined(separator: ".") }

    private static func line(_ p: [CGPoint]) -> Path {
        Path { path in
            guard let first = p.first else { return }
            path.move(to: first)
            for i in 1..<max(1, p.count) where i < p.count {
                let mx = (p[i - 1].x + p[i].x) / 2
                path.addCurve(to: p[i], control1: CGPoint(x: mx, y: p[i - 1].y), control2: CGPoint(x: mx, y: p[i].y))
            }
        }
    }
    private static func area(_ p: [CGPoint], bottom: CGFloat) -> Path {
        var path = line(p)
        guard let first = p.first, let last = p.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: bottom))
        path.addLine(to: CGPoint(x: first.x, y: bottom))
        path.closeSubpath()
        return path
    }

    var body: some View {
        let maxV = max(1, bars.map { max($0.back, $0.front) }.max() ?? 1)
        let two = bars.contains { $0.back != $0.front }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let n = bars.count
                let x = { (i: Int) -> CGFloat in n > 1 ? 4 + (w - 8) * CGFloat(i) / CGFloat(n - 1) : w / 2 }
                let y = { (v: Int) -> CGFloat in h - 3 - (h - 12) * CGFloat(v) / CGFloat(maxV) }
                let back = bars.indices.map { CGPoint(x: x($0), y: y(bars[$0].back)) }
                let front = bars.indices.map { CGPoint(x: x($0), y: y(bars[$0].front)) }
                ZStack(alignment: .topLeading) {
                    ForEach(0..<3, id: \.self) { k in
                        Path { p in let yy = 9 + (h - 12) * CGFloat(k) / 2; p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: w, y: yy)) }
                            .stroke(Theme.lineC, style: StrokeStyle(lineWidth: 0.6, dash: k == 2 ? [] : [2, 3]))
                    }
                    ForEach(bars.indices.filter { bars[$0].mark }, id: \.self) { i in
                        Path { p in p.move(to: CGPoint(x: x(i), y: 4)); p.addLine(to: CGPoint(x: x(i), y: h)) }
                            .stroke(Theme.ink3C, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    if two {
                        Self.area(back, bottom: h).fill(Theme.secondC.opacity(0.13))
                        Self.line(back).stroke(Theme.secondC.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                    Self.area(front, bottom: h).fill(Theme.accentC.opacity(0.16))
                    Self.line(front).stroke(Theme.accentC, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    if let i = hover, bars.indices.contains(i) {
                        Path { p in p.move(to: CGPoint(x: x(i), y: 0)); p.addLine(to: CGPoint(x: x(i), y: h)) }
                            .stroke(Theme.ink3C, lineWidth: 1)
                        if two { dot(back[i], Theme.secondC) }
                        dot(front[i], Theme.accentC)
                        label(i, two: two)
                            .fixedSize()
                            .position(x: min(max(x(i), 70), w - 70), y: -12)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = n > 1 ? Int(((p.x - 4) / max(1, w - 8) * CGFloat(n - 1)).rounded()).clamped(0, n - 1) : 0
                    case .ended: hover = nil
                    }
                }
            }
            .frame(height: height)
            .padding(.top, 14)
            if let first = bars.first, let last = bars.last {
                HStack {
                    Text(Self.short(first.id)); Spacer(); Text(Self.short(bars[bars.count / 2].id)); Spacer(); Text(Self.short(last.id))
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func dot(_ p: CGPoint, _ c: Color) -> some View {
        Circle().fill(c).frame(width: 9, height: 9).overlay(Circle().stroke(Theme.cardC, lineWidth: 2)).position(p)
    }

    private func label(_ i: Int, two: Bool) -> some View {
        let b = bars[i]
        let text = two ? "\(Self.short(b.id)) · \(frontName.isEmpty ? "" : frontName + " ")\(b.front) из \(b.back)" : "\(Self.short(b.id)) · \(b.front)"
        return Text(text).font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.cardC, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.lineC, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

struct SLegend: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 10, height: 10)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}
