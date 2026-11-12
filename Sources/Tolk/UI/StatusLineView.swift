// One quiet line under a translation: who is translating, by which route, how fast.
//   ● Qwen · жду ответ…            (grey)
//   ● Qwen · генерация · 31 ток/с  (live, updated per chunk — no timers)
//   ● Qwen дома · первое слово 0,4 с · 29 ток/с · 1,9 с   (green / blue when remote)
//   ● Google · 0,8 с · the home server недоступен                    (orange: fallback, no glossary)
import AppKit
import TolkCore

@MainActor
final class StatusLineView: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var provider = ""
    private var firstChunkAt: Date?
    private var chunks = 0
    private var lastLiveUpdate = Date.distantPast
    private var slowHint: Timer?
    private var waitStart = Date()
    private var fallbackReason: String?
    /// The page shows the warnings in the «Проверка» card: here only a «⚠ 2» badge, so the line stays short.
    var compactWarnings = false
    /// Set by the window: a click on the «из кеша» mark asks for a fresh translation (no cache).
    var onRetranslate: (() -> Void)?
    private var retranslatable = false

    init(fontSize: CGFloat = 11) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = Theme.ink2
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reset()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Narrower than this the text would be cut to «Gem…»: the coloured dot alone says more, the text is in the tooltip.
    private static let minTextWidth: CGFloat = 96
    private var borrowedTip = false

    override func layout() {
        super.layout()
        let tight = bounds.width < Self.minTextWidth
        if label.isHidden != tight { label.isHidden = tight }
        // The states set their own tooltip; only a line without one borrows the hidden text.
        if tight, (toolTip ?? "").isEmpty, !label.stringValue.isEmpty { toolTip = label.stringValue; borrowedTip = true }
        if !tight, borrowedTip { toolTip = nil; borrowedTip = false }
    }

    // MARK: - States

    override func hitTest(_ point: NSPoint) -> NSView? {
        retranslatable && !isHidden && frame.contains(point) ? self : super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        if retranslatable { onRetranslate?() } else { super.mouseDown(with: event) }
    }
    override func resetCursorRects() {
        if retranslatable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    func reset() {
        retranslatable = false
        stopHint()
        provider = ""; firstChunkAt = nil; chunks = 0; fallbackReason = nil
        set("", color: .clear, text: Theme.ink2)
        isHidden = true
    }

    /// A request went out; nothing has arrived yet.
    func waiting(provider: String) {
        retranslatable = false
        stopHint()
        self.provider = provider
        firstChunkAt = nil; chunks = 0
        isHidden = false
        let local = !UIText.isFallbackProvider(provider)
        set("\(UIText.providerName(provider)) · жду ответ…", color: Theme.ink3, text: Theme.ink2)
        // A cold model takes 15–120 s to load on the server; say so, with a running counter, instead of
        // looking stuck. One 1 s timer only while waiting for the first word (stopped by chunk/finish/fail).
        waitStart = Date()
        if local {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.firstChunkAt == nil, !self.isHidden else { t.invalidate(); return }
                    let n = Int(Date().timeIntervalSince(self.waitStart))
                    guard n >= 3 else { return }
                    let what = n >= 40 ? "модель всё ещё загружается (холодный старт)" : "модель загружается на сервере"
                    self.set("\(UIText.providerName(self.provider)) · \(what)… \(n) с",
                             color: .systemYellow, text: Theme.ink2)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            slowHint = t
        }
    }

    private func stopHint() { slowHint?.invalidate(); slowHint = nil }

    func fellBack(reason: String) {
        stopHint()
        fallbackReason = reason
        set(ServerText.switching() + "…", color: .systemOrange, text: .systemOrange)
    }

    /// Called for every streamed chunk; the label is refreshed at most ~5 times a second.
    func chunk() {
        chunks += 1
        let now = Date()
        if firstChunkAt == nil { firstChunkAt = now; stopHint() }
        guard now.timeIntervalSince(lastLiveUpdate) > 0.2, let first = firstChunkAt else { return }
        lastLiveUpdate = now
        let elapsed = now.timeIntervalSince(first)
        var text = "\(UIText.providerName(provider)) · генерация"
        if elapsed > 0.3, !UIText.isFallbackProvider(provider) {
            text += " · \(Int((Double(chunks) / elapsed).rounded())) ток/с"
        }
        set(text, color: fallbackReason == nil ? Theme.ok : .systemOrange, text: Theme.ink2)
    }

    func finished(_ st: TranslationStats) {
        stopHint()
        isHidden = false
        var parts = [st.routeTitle]
        if st.fromCache {
            // Same text and settings as a recent translation: shown from memory, the model was not asked.
            parts.append("из кеша")
            set(parts.joined(separator: " · "), color: Theme.ok, text: Theme.ink2)
            if onRetranslate != nil {
                let attr = NSMutableAttributedString(string: label.stringValue + " · ", attributes: [
                    .font: label.font as Any, .foregroundColor: Theme.ink2])
                if let img = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Перевести заново") {
                    let att = NSTextAttachment()
                    att.image = img.withSymbolConfiguration(.init(pointSize: label.font?.pointSize ?? 11, weight: .regular))
                    attr.append(NSAttributedString(attachment: att))
                }
                attr.append(NSAttributedString(string: " заново", attributes: [
                    .font: label.font as Any, .foregroundColor: Theme.accent]))
                // Without a paragraph style the attributed text wraps into a column when the pane is narrow.
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingTail
                attr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attr.length))
                label.attributedStringValue = attr
                retranslatable = true
                toolTip = "Перевод взят из памяти. Нажмите — перевести заново, без кеша"
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        if let f = st.firstChunk, st.route == .home || st.route == .remote {
            parts.append("первое слово \(Self.seconds(f))")
        }
        if let tps = st.tokensPerSecond { parts.append("\(Int(tps.rounded())) ток/с\(st.tokensExact ? "" : "≈")") }
        parts.append(Self.seconds(st.total))
        if let reason = st.fallbackReason {
            parts.append(Self.shortReason(reason) + " — без глоссария")
            set(parts.joined(separator: " · "), color: .systemOrange, text: .systemOrange)
        } else {
            set(parts.joined(separator: " · "), color: st.route == .remote ? .systemBlue : Theme.ok,
                text: Theme.ink2)
        }
        var tip = st.fallbackReason.map { "Запасной перевод. Причина: \($0)" }
            ?? (st.tokensExact ? "Скорость по данным сервера" : "Скорость примерная")
        if !st.warnings.isEmpty {
            // The warning goes first so that tail truncation never hides it; full text in the tooltip.
            let warn = compactWarnings ? "⚠ \(st.warnings.count)" : "⚠ " + st.warnings.joined(separator: "; ")
            let rest = label.stringValue
            let attr = NSMutableAttributedString(string: warn, attributes: [
                .font: label.font as Any, .foregroundColor: NSColor.systemOrange])
            attr.append(NSAttributedString(string: " · " + rest, attributes: [
                .font: label.font as Any, .foregroundColor: label.textColor ?? Theme.ink2]))
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            attr.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attr.length))
            label.attributedStringValue = attr
            tip = "⚠ " + st.warnings.joined(separator: "; ") + "\n" + tip
        }
        toolTip = tip
    }

    func failed(_ message: String) {
        stopHint()
        isHidden = false
        set(message, color: .systemRed, text: .systemRed)
    }

    // MARK: - Helpers

    private func set(_ text: String, color: NSColor, text textColor: NSColor) {
        label.stringValue = text
        label.textColor = textColor
        dot.layer?.backgroundColor = color.cgColor
    }

    private static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    static func seconds(_ t: TimeInterval) -> String {
        (number.string(from: NSNumber(value: t)) ?? String(format: "%.1f", t)) + " с"
    }

    static func shortReason(_ r: String) -> String {
        ServerText.statusReason(r)
    }

    /// Layer colours do not follow light/dark switches by themselves.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let c = dot.layer?.backgroundColor, let ns = NSColor(cgColor: c) {
            effectiveAppearance.performAsCurrentDrawingAppearance { self.dot.layer?.backgroundColor = ns.cgColor }
        }
    }
}
