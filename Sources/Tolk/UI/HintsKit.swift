// Pieces shared by the popup and the «Перевод» page for the hints on a finished translation:
// footnotes, back-translation, word alternatives, the glossary form. One implementation, two places.
import AppKit
import TolkCore

// MARK: - Settings

/// The two switches live in one place, so the popup and the page never disagree.
enum HintsSettings {
    /// Footnotes toggle (remembered, on by default): notes on debatable industry terms.
    static var notesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "tolk.popup.notes") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tolk.popup.notes") }
    }
    /// Back-translation toggle (remembered): after each translation, translate it back to check meaning.
    static var backEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "tolk.popup.back") }
        set { UserDefaults.standard.set(newValue, forKey: "tolk.popup.back") }
    }
}

// MARK: - Jobs

/// One cancellable async request whose result goes back to the main actor (footnotes, alternatives).
@MainActor
final class HintTask {
    private var task: Task<Void, Never>?
    private(set) var isRunning = false

    func run<T: Sendable>(_ work: @escaping @Sendable () async -> T, then: @escaping @MainActor (T) -> Void) {
        task?.cancel()
        isRunning = true
        task = Task { @MainActor [weak self] in
            let result = await work()
            guard !Task.isCancelled else { return }
            self?.isRunning = false
            then(result)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}

/// The translation translated back into the source language, to see whether the meaning survived.
@MainActor
final class BackTranslationJob {
    enum Update {
        case running(String)    // text so far ("" = just started / restarted)
        case finished(String)
        case failed(String)
    }

    private var runner: TranslationRunner?
    private(set) var text = ""
    var onUpdate: ((Update) -> Void)?
    var isRunning: Bool { runner?.isRunning ?? false }

    /// `from` is the language of `translation`, `to` the language of the original text.
    func start(engine: TranslationEngine, translation: String, from: Language, to: Language) {
        cancel()
        let r = TranslationRunner(engine: engine)
        r.onUpdate = { [weak self] in self?.handle($0) }
        runner = r
        r.start(TranslationRequest(text: translation, source: from, target: to, tone: .auto))
    }

    func cancel() {
        runner?.cancel()
        runner = nil
        text = ""
    }

    private func handle(_ update: TranslationRunner.Update) {
        switch update {
        case .started, .fellBack:
            text = ""
            onUpdate?(.running(""))
        case let .delta(chunk):
            text += chunk
            onUpdate?(.running(text))
        case .finished:
            onUpdate?(.finished(text))
        case let .failed(message):
            onUpdate?(.failed(message))
        }
    }
}

// MARK: - Views

/// Wrapping label that follows the width it is given (its height then follows the text).
final class WrapLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5, bounds.width > 0 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

extension UIFactory {
    /// Wrapping label (any number of lines) that adapts to its width.
    static func flexibleLabel(_ text: String = "", size: CGFloat = 12.5, color: NSColor = .labelColor,
                              selectable: Bool = true) -> WrapLabel {
        let l = WrapLabel(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.isSelectable = selectable
        l.maximumNumberOfLines = 0
        l.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        return l
    }
}

/// A footnote on a debatable term: «term → «used»» with the explanation and the two actions.
enum NoteRow {
    /// `width` fixed (popup) or nil (the caller pins the row to its container, text follows).
    /// `onSave(value, retranslate)`: «Так и оставить» saves `used`; the replacement saves the suggestion and retranslates.
    @MainActor
    static func make(_ n: TranslationNote, index: Int, width: CGFloat?,
                     onSave: @escaping (_ value: String, _ retranslate: Bool) -> Void) -> NSView {
        let text = NSMutableAttributedString()
        let small = NSFont.systemFont(ofSize: 12.5)
        text.append(NSAttributedString(string: "\(index). ", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
        text.append(NSAttributedString(string: n.term, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: " → «\(n.used)»", attributes: [.font: small, .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "\n" + n.note, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        let label = width == nil ? WrapLabel(labelWithAttributedString: text) : NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        if let width { label.preferredMaxLayoutWidth = width }
        label.isSelectable = true

        var buttons: [NSView] = []
        let keep = ClosureButton(title: "Так и оставить", symbol: "checkmark") { onSave(n.used, false) }
        keep.toolTip = "Сохранить «\(n.term) → \(n.used)» в глоссарий"
        // Shrink priority: «Так и оставить» is never cut; the long replacement (««минимальная цена»») gives way first
        // (cut with «…», the full text stays in the tooltip).
        keep.setContentCompressionResistancePriority(.required, for: .horizontal)
        buttons.append(keep)
        if let sug = n.suggestion {
            let use = ClosureButton(title: "«\(sug)»", symbol: "arrow.triangle.2.circlepath") { onSave(sug, true) }
            use.toolTip = "Сохранить «\(n.term) → \(sug)» в глоссарий и перевести заново"
            use.lineBreakMode = .byTruncatingTail
            use.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            buttons.append(use)
        }
        let row = NSStackView(views: buttons + [UIFactory.spacer()])
        row.orientation = .horizontal
        row.spacing = 6
        let box = NSStackView(views: [label, row])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        if width == nil {
            label.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
            row.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        }
        return box
    }
}

/// «Термин → как переводить» + Сохранить / Отмена. Enter in the first field moves on, in the second saves; Esc cancels.
@MainActor
final class GlossaryFormView: NSStackView, NSTextFieldDelegate {
    let termField = NSTextField()
    let valueField = NSTextField()
    /// Called with trimmed, non-empty values.
    var onSave: ((_ term: String, _ value: String) -> Void)?
    var onCancel: (() -> Void)?

    /// `stacked`: fields one under the other (narrow panels); `showsTitle`: «Добавить в глоссарий» next to the buttons;
    /// `defaultButton`: «Сохранить» answers to Return (windows without a text view that eats it).
    init(stacked: Bool = false, showsTitle: Bool = true, defaultButton: Bool = false) {
        super.init(frame: .zero)
        termField.placeholderString = "Термин"
        valueField.placeholderString = "Как переводить"
        for f in [termField, valueField] {
            f.delegate = self
            f.controlSize = .small
            f.font = .systemFont(ofSize: 12)
        }
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveClicked))
        save.controlSize = .small
        save.bezelStyle = .push
        if defaultButton { save.keyEquivalent = "\r" }
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelClicked))
        cancel.controlSize = .small
        cancel.bezelStyle = .push

        let fields: NSStackView
        if stacked {
            fields = NSStackView(views: [termField, valueField])
            fields.orientation = .vertical
            fields.spacing = 6
            termField.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
            valueField.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        } else {
            fields = NSStackView(views: [termField, UIFactory.label("→", size: 12), valueField])
            fields.orientation = .horizontal
            fields.spacing = 6
            termField.widthAnchor.constraint(equalTo: valueField.widthAnchor).isActive = true
        }
        var bottom: [NSView] = []
        if showsTitle { bottom.append(UIFactory.label("Добавить в глоссарий", size: 11, weight: .medium)) }
        bottom += [UIFactory.spacer(), cancel, save]
        let buttons = NSStackView(views: bottom)
        buttons.orientation = .horizontal

        orientation = .vertical
        alignment = .leading
        spacing = 6
        addArrangedSubview(fields)
        addArrangedSubview(buttons)
        fields.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func fill(term: String? = nil, value: String? = nil) {
        if let term { termField.stringValue = term }
        if let value { valueField.stringValue = value }
    }

    func clear() { termField.stringValue = ""; valueField.stringValue = "" }

    func focusTerm() { window?.makeFirstResponder(termField) }

    @objc private func saveClicked() { save() }
    @objc private func cancelClicked() { onCancel?() }

    private func save() {
        let term = termField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = valueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !value.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(term.isEmpty ? termField : valueField)
            return
        }
        onSave?(term, value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if control === termField { window?.makeFirstResponder(valueField) } else { save() }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}

// MARK: - Sentence variants, tone

/// One variant of a sentence: a small label above, the text below; the whole row is a button.
@MainActor
final class VariantRowView: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(label: String, text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let tag = UIFactory.label(label, size: 10.5, weight: .semibold, color: .tertiaryLabelColor)
        let body = UIFactory.flexibleLabel(text, size: 12.5, color: .labelColor, selectable: false)
        let stack = NSStackView(views: [tag, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        toolTip = "Подставить вместо предложения"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(0.045)).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

extension UIText {
    /// Colour of the tone badge in «Что он имел в виду»: warm words red/orange, friendly green, formal blue.
    static func toneColor(_ tone: String) -> NSColor {
        let t = tone.lowercased()
        func has(_ keys: [String]) -> Bool { keys.contains { t.contains($0) } }
        if has(["раздраж", "недовол", "резк", "жёстк", "жестк", "агресс", "угроз", "претенз", "злой", "зол", "сердит"]) { return .systemRed }
        if has(["срочн", "давлен", "настойч", "требоват", "напряж", "нетерпел", "тревож", "отказ"]) { return .systemOrange }
        if has(["ирон", "сарказ", "насмеш"]) { return .systemPurple }
        if has(["дружел", "тепл", "вежлив", "благодар", "радост", "позитив", "любез", "заботл"]) { return .systemGreen }
        if has(["формал", "официал", "делов", "сдержан"]) { return .systemBlue }
        return .secondaryLabelColor
    }
}
