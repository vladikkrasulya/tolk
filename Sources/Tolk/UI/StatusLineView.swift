// One quiet line under a translation: who is translating, by which route, how fast.
//   ● Qwen · жду ответ…            (grey)
//   ● Qwen · генерация · 31 ток/с  (live, updated per chunk — no timers)
//   ● Qwen дома · первое слово 0,4 с · 29 ток/с · 1,9 с   (green / blue when remote)
//   ● Google · 0,8 с · vkbox не ответил                    (orange: fallback, no glossary)
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
    private var slowHint: DispatchWorkItem?
    private var fallbackReason: String?

    init(fontSize: CGFloat = 11) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
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

    // MARK: - States

    func reset() {
        slowHint?.cancel()
        provider = ""; firstChunkAt = nil; chunks = 0; fallbackReason = nil
        set("", color: .clear, text: .secondaryLabelColor)
        isHidden = true
    }

    /// A request went out; nothing has arrived yet.
    func waiting(provider: String) {
        slowHint?.cancel()
        self.provider = provider
        firstChunkAt = nil; chunks = 0
        isHidden = false
        let local = !UIText.isFallbackProvider(provider)
        set("\(UIText.providerName(provider)) · жду ответ…", color: .tertiaryLabelColor, text: .secondaryLabelColor)
        // A cold model takes 15–60 s to load on the server; say so instead of looking stuck.
        if local {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.firstChunkAt == nil, !self.isHidden else { return }
                self.set("\(UIText.providerName(self.provider)) · модель загружается на сервере…",
                         color: .systemYellow, text: .secondaryLabelColor)
            }
            slowHint = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    func fellBack(reason: String) {
        fallbackReason = reason
        set("переключаюсь на запасной перевод…", color: .systemOrange, text: .systemOrange)
    }

    /// Called for every streamed chunk; the label is refreshed at most ~5 times a second.
    func chunk() {
        chunks += 1
        let now = Date()
        if firstChunkAt == nil { firstChunkAt = now; slowHint?.cancel() }
        guard now.timeIntervalSince(lastLiveUpdate) > 0.2, let first = firstChunkAt else { return }
        lastLiveUpdate = now
        let elapsed = now.timeIntervalSince(first)
        var text = "\(UIText.providerName(provider)) · генерация"
        if elapsed > 0.3, !UIText.isFallbackProvider(provider) {
            text += " · \(Int((Double(chunks) / elapsed).rounded())) ток/с"
        }
        set(text, color: fallbackReason == nil ? .systemGreen : .systemOrange, text: .secondaryLabelColor)
    }

    func finished(_ st: TranslationStats) {
        slowHint?.cancel()
        isHidden = false
        var parts = [st.routeTitle]
        if let f = st.firstChunk, st.route == .home || st.route == .remote {
            parts.append("первое слово \(Self.seconds(f))")
        }
        if let tps = st.tokensPerSecond { parts.append("\(Int(tps.rounded())) ток/с\(st.tokensExact ? "" : "≈")") }
        parts.append(Self.seconds(st.total))
        if let reason = st.fallbackReason {
            parts.append(Self.shortReason(reason) + " — без глоссария")
            set(parts.joined(separator: " · "), color: .systemOrange, text: .systemOrange)
        } else {
            set(parts.joined(separator: " · "), color: st.route == .remote ? .systemBlue : .systemGreen,
                text: .secondaryLabelColor)
        }
        toolTip = st.fallbackReason.map { "Запасной перевод. Причина: \($0)" }
            ?? (st.tokensExact ? "Скорость по данным сервера" : "Скорость примерная")
    }

    func failed(_ message: String) {
        slowHint?.cancel()
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
        let l = r.lowercased()
        if l.contains("vkbox") || l.contains("не отвечает") || l.contains("недоступ") { return "vkbox не ответил" }
        if l.contains("таймаут") || l.contains("timed out") { return "сервер не успел ответить" }
        return r
    }

    /// Layer colours do not follow light/dark switches by themselves.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let c = dot.layer?.backgroundColor, let ns = NSColor(cgColor: c) {
            effectiveAppearance.performAsCurrentDrawingAppearance { self.dot.layer?.backgroundColor = ns.cgColor }
        }
    }
}
