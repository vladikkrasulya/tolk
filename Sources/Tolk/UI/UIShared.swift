// Helpers shared by the popup and the input window.
import AppKit
import TolkCore

// MARK: - Translation runner

/// Runs one translation at a time: starting a new one cancels the previous Task (and with it
/// the engine's stream). Events of a superseded run are dropped, so the UI never mixes texts.
@MainActor
final class TranslationRunner {
    enum Update {
        case started(provider: String, source: Language, target: Language)
        case delta(String)
        case fellBack(from: String, reason: String)
        case finished
        case failed(String)
    }

    private let engine: TranslationEngine
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var isRunning = false
    var onUpdate: ((Update) -> Void)?
    /// Who translated and how fast (arrives right before `.finished`).
    var onStats: ((TranslationStats) -> Void)?

    init(engine: TranslationEngine) { self.engine = engine }

    func start(_ request: TranslationRequest) {
        cancel()
        let gen = generation
        isRunning = true
        let stream = engine.translate(request)
        task = Task { @MainActor [weak self] in
            do {
                for try await event in stream {
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    self.deliver(event)
                }
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                if self.isRunning { self.isRunning = false; self.onUpdate?(.finished) }
            } catch {
                guard let self, self.generation == gen, !Task.isCancelled,
                      !(error is CancellationError) else { return }
                self.isRunning = false
                self.onUpdate?(.failed(UIText.errorMessage(error)))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isRunning = false
    }

    private func deliver(_ event: TranslationEvent) {
        switch event {
        case let .started(provider, source, target):
            onUpdate?(.started(provider: provider, source: source, target: target))
        case let .delta(chunk):
            onUpdate?(.delta(chunk))
        case let .fellBack(from, reason):
            onUpdate?(.fellBack(from: from, reason: reason))
        case let .stats(st):
            onStats?(st)
        case .finished:
            isRunning = false
            onUpdate?(.finished)
        }
    }
}

// MARK: - Texts

enum UIText {
    static func providerName(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("qwen") { return "Qwen" }
        if s.contains("gemma") { return "Gemma" }
        if s.contains("ollama") { return "Ollama" }
        if s.contains("google") { return "Google" }
        return raw.isEmpty ? "—" : raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func isFallbackProvider(_ raw: String) -> Bool {
        let s = raw.lowercased()
        return s.contains("google") || s.contains("apple") // not the home model → no "model is loading" hint, orange
    }

    static func toneTitle(_ tone: Tone) -> String {
        switch tone { case .auto: "Авто"; case .chat: "Чат"; case .formal: "Письмо" }
    }

    static func toneHint(_ tone: Tone) -> String {
        switch tone {
        case .auto: "Сохранять тон оригинала"
        case .chat: "Коротко и неформально — для Slack и Telegram"
        case .formal: "Вежливо, как в деловом письме"
        }
    }

    /// One wording for «the home model failed, the fallback service is working» on every page and in the popup.
    static func fallbackSwitching(from: String) -> String {
        ServerText.switching(fromHome: !isFallbackProvider(from), name: providerName(from))
    }

    /// «the home server недоступен — перевод от Google» (the fallback has started to answer).
    static func fallbackDone(from: String, to: String) -> String {
        ServerText.switched(fromHome: !isFallbackProvider(from), name: providerName(from), to: providerName(to))
    }

    static func capitalized(_ l: Language) -> String {
        l.russianName.prefix(1).uppercased() + l.russianName.dropFirst()
    }

    /// "на русский" etc.
    static func intoLanguage(_ l: Language) -> String {
        "На " + l.russianName
    }

    static func errorMessage(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return "Сервер перевода не ответил вовремя. Попробуйте ещё раз."
            case .notConnectedToInternet, .networkConnectionLost:
                return "Нет подключения к интернету."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "Не удалось подключиться к серверу перевода."
            default:
                return "Сбой сети. Попробуйте ещё раз."
            }
        }
        if let le = error as? LocalizedError, let d = le.errorDescription, !d.isEmpty {
            return "Не удалось перевести: \(d)"
        }
        return "Не удалось перевести: \(error.localizedDescription)"
    }
}

// MARK: - Small AppKit helpers

enum UIFactory {
    static func label(_ text: String = "", size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor = Theme.ink2) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    static func wrappingLabel(_ text: String = "", size: CGFloat = 12,
                              color: NSColor = Theme.ink2) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.isSelectable = false
        return l
    }

    static func symbolButton(_ symbol: String, tooltip: String, target: AnyObject?, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let b = NSButton(image: image, target: target, action: action)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.contentTintColor = Theme.ink2
        b.toolTip = tooltip
        b.setButtonType(.momentaryChange)
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    static func toneControl(target: AnyObject?, action: Selector) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: Tone.allCases.map(UIText.toneTitle),
                                   trackingMode: .selectOne, target: target, action: action)
        c.controlSize = .small
        c.selectedSegmentBezelColor = Theme.accentStrong
        c.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for (i, tone) in Tone.allCases.enumerated() { c.setToolTip(UIText.toneHint(tone), forSegment: i) }
        return c
    }

    static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    /// Small rounded "pill" with a text, used for the provider name.
    static func badge() -> BadgeView { BadgeView() }
}

final class BadgeView: NSView {
    let label = UIFactory.label("", size: 10.5, weight: .semibold, color: Theme.ink2)
    var tint: NSColor = Theme.ink2 { didSet { needsDisplay = true; label.textColor = tint } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; isHidden = newValue.isEmpty }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        tint.withAlphaComponent(0.14).setFill()
        path.fill()
    }
}

// MARK: - Edit shortcuts

/// The app is `.accessory` and has no main menu, so Cmd+C/V/X/A/Z would not reach text views.
/// Windows of the UI route them here from `performKeyEquivalent`.
enum EditShortcuts {
    @MainActor
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: Selector?
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}

// MARK: - Clipboard

enum Clipboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Closure button

/// Small push button with a closure action (for dynamically built rows like footnotes).
final class ClosureButton: NSButton {
    private var handler: () -> Void

    init(title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading }
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
