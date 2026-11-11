// Building blocks of the settings page — and the app's shared look: cards on a quiet page, hairline borders,
// 12 pt corners, small status pills, a hint under every control, grey example tiles.
import SwiftUI
import AppKit

/// One place for the sizes and colours every screen uses (SwiftUI and AppKit).
enum TolkStyle {
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let cardPadding: CGFloat = 14
    static let gap: CGFloat = 14

    static var page: Color { Color(nsColor: .windowBackgroundColor) }
    static var card: Color { Color(nsColor: nsCard) }
    static var tile: Color { Color.primary.opacity(0.055) }
    static var hairline: Color { Color(nsColor: .separatorColor) }

    /// White card in light mode, a slightly lifted grey in dark mode.
    static let nsCard = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : .white
    }
    static let nsTile = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.055)
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
        let n = max(1, min(maxColumns, Int((width + spacing) / (minColumn + spacing))))
        let colW = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        var heights = [CGFloat](repeating: 0, count: n)
        var frames: [CGRect] = []
        for s in subviews {
            if s[SpanKey.self] {
                let y = heights.max() ?? 0
                let h = s.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                frames.append(CGRect(x: 0, y: y, width: width, height: h))
                heights = heights.map { _ in y + h + spacing }
            } else {
                let i = heights.indices.min { heights[$0] < heights[$1] } ?? 0
                let h = s.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
                frames.append(CGRect(x: CGFloat(i) * (colW + spacing), y: heights[i], width: colW, height: h))
                heights[i] += h + spacing
            }
        }
        return (frames, max(0, (heights.max() ?? 0) - spacing))
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 20)
                Text(title).font(.headline)
                Spacer(minLength: 8)
                trailing()
            }
            if let subtitle { SHint(subtitle).padding(.top, 4) }
            content().padding(.top, 10)
        }
        .padding(TolkStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TolkStyle.card, in: RoundedRectangle(cornerRadius: TolkStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TolkStyle.cardRadius, style: .continuous).strokeBorder(TolkStyle.hairline, lineWidth: 0.5))
    }
}

extension SCard where Trailing == EmptyView {
    init(_ title: String, symbol: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, symbol: symbol, subtitle: subtitle, trailing: { EmptyView() }, content: content)
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
        case .neutral: .secondary
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        case .accent: .accentColor
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
        .font(.callout)
        .foregroundStyle(role == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(role.color))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((role == .neutral ? Color.primary.opacity(0.06) : role.color.opacity(0.14)), in: Capsule())
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
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(used ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    .background(Color.accentColor.opacity(used ? 0.05 : 0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(used)
                .help(used ? "Уже добавлено" : "Добавить в инструкции")
            }
        }
    }
}

/// Number tile: caption on top, big value, optional note.
struct STile: View {
    let caption: String
    let value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 22, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TolkStyle.tile, in: RoundedRectangle(cornerRadius: TolkStyle.controlRadius, style: .continuous))
    }
}

/// Tiles in a grid that adapts to the width.
struct STileGrid<Content: View>: View {
    var minTile: CGFloat = 130
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
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.accentColor).frame(width: max(4, g.size.width * fraction))
                }
            }
            .frame(height: 5)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(value)").monospacedDigit().foregroundStyle(.secondary)
                Text(total > 0 ? "\(Int((Double(value) / Double(total) * 100).rounded())) %" : "—")
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .font(.callout)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: total > 0 ? max(3, g.size.width * CGFloat(value) / CGFloat(total)) : 0)
                }
            }
            .frame(height: 4)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 3)
    }
}

/// Bars per day (grey = `back`, accent = `front`), with first / middle / last day labels.
struct SDayChart: View {
    struct Bar: Identifiable { let id: String; let back: Int; let front: Int; var mark = false }
    let bars: [Bar]
    var height: CGFloat = 84

    static func short(_ day: String) -> String { String(day.suffix(5)).split(separator: "-").reversed().joined(separator: ".") }

    var body: some View {
        let maxV = max(1, bars.map { max($0.back, $0.front) }.max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bars) { b in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.14))
                            .frame(height: b.back > 0 ? max(2, height * CGFloat(b.back) / CGFloat(maxV)) : 0)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor)
                            .frame(height: b.front > 0 ? max(2, height * CGFloat(min(b.front, max(b.back, b.front))) / CGFloat(maxV)) : 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottom)
                    .overlay(alignment: .leading) { if b.mark { Rectangle().fill(Color.orange).frame(width: 2) } }
                    .help("\(Self.short(b.id)): \(b.back)" + (b.front != b.back ? " / \(b.front)" : ""))
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(TolkStyle.hairline).frame(height: 0.5) }
            if let first = bars.first, let last = bars.last {
                HStack {
                    Text(Self.short(first.id)); Spacer(); Text(Self.short(bars[bars.count / 2].id)); Spacer(); Text(Self.short(last.id))
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SLegend: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
