// «Сообщение собеседника» card of the reply mode: the partner's message (editable) and, right under it, its translation
// into the user's language, always visible. The translation is read-only.
import AppKit

@MainActor
final class ReplyMessageCard: NSView {
    let messageView = PlaceholderTextView()
    let translationView = NSTextView()
    private let titleLabel = UIFactory.label("Сообщение собеседника", size: 11.5, weight: .semibold, color: .secondaryLabelColor)
    private let langLabel = UIFactory.label("", size: 11, color: .tertiaryLabelColor)
    private let spinner = NSProgressIndicator()
    private let box = NSBox()

    static let fontSize: CGFloat = 15

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        box.boxType = .custom
        box.cornerRadius = TolkStyle.cardRadius
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.fillColor = TolkStyle.nsCard
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        guard let cv = box.contentView else { return }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let head = NSStackView(views: [titleLabel, UIFactory.spacer(), spinner, langLabel])
        head.orientation = .horizontal
        head.spacing = 6
        head.translatesAutoresizingMaskIntoConstraints = false

        let (msgScroll, msg) = Self.pane(messageView, editable: true)
        messageView.placeholder = "Вставьте сообщение собеседника"
        messageView.placeholderFont = .systemFont(ofSize: Self.fontSize)
        messageView.setAccessibilityLabel("Сообщение собеседника")
        let (trScroll, tr) = Self.pane(translationView, editable: false)
        _ = (msg, tr)
        translationView.textColor = .secondaryLabelColor

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for v in [head, msgScroll, divider, trScroll] { cv.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            head.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            head.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            msgScroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 0),
            msgScroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 1),
            msgScroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -1),
            divider.topAnchor.constraint(equalTo: msgScroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            trScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            trScroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 1),
            trScroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -1),
            trScroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -1),
            trScroll.heightAnchor.constraint(equalTo: msgScroll.heightAnchor, multiplier: 0.8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func pane(_ tv: NSTextView, editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isEditable = editable
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = editable
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 10, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = tv
        return (scroll, tv)
    }

    /// «EN → RU» in the header, spinner while the translation streams.
    func setInfo(_ text: String, busy: Bool) {
        langLabel.stringValue = text
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Text under the message; `dim` for hints like «Сообщение уже на вашем языке».
    func setTranslation(_ text: String, dim: Bool = false, error: Bool = false) {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        let color: NSColor = error ? .systemRed : dim ? .tertiaryLabelColor : .secondaryLabelColor
        translationView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Self.fontSize), .foregroundColor: color, .paragraphStyle: p]))
    }
    func appendTranslation(_ chunk: String) {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        translationView.textStorage?.append(NSAttributedString(string: chunk, attributes: [
            .font: NSFont.systemFont(ofSize: Self.fontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]))
    }
}
