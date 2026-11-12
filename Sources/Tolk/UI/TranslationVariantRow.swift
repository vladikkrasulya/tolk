// One alternative translation in the «Варианты перевода» card of the hints panel:
// badge with the model's label, the reason in grey, the text with the words that differ from the current translation
// highlighted (like the «Правка» card), and a «Взять» button.
import AppKit
import TolkCore

@MainActor
final class TranslationVariantRow: NSView {
    var onTake: (() -> Void)?
    private let takeButton = NSButton(title: "Взять", target: nil, action: nil)

    init(variant: TranslationVariant, base: String, taken: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let badge = UIFactory.badge()
        badge.text = variant.label
        let tone = UIText.toneColor(variant.label)
        badge.tint = tone == Theme.ink2 ? Theme.accent : tone

        takeButton.target = self
        takeButton.action = #selector(take)
        takeButton.bezelStyle = .push
        takeButton.controlSize = .small
        takeButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        takeButton.setContentHuggingPriority(.required, for: .horizontal)
        takeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        if taken {
            takeButton.title = "Взято"
            takeButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            takeButton.imagePosition = .imageLeading
            takeButton.isEnabled = false
        } else {
            takeButton.toolTip = "Заменить перевод этим вариантом (потом можно вернуть)"
        }

        let head = NSStackView(views: [badge, UIFactory.spacer(), takeButton])
        head.orientation = .horizontal
        head.spacing = 6
        head.alignment = .centerY

        var rows: [NSView] = [head]
        if !variant.reason.isEmpty {
            let reason = UIFactory.flexibleLabel(variant.reason, size: 11.5, color: Theme.ink2, selectable: false)
            rows.append(reason)
        }
        let text = UIFactory.flexibleLabel("", size: 12.5, color: Theme.ink)
        text.attributedStringValue = TranslationHintsPanel.diff(old: base, new: variant.text).1
        rows.append(text)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        for v in rows { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func take() { onTake?() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.ink.withAlphaComponent(0.045).setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
