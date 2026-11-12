// «Последние переводы»: popover with a search field and the newest translations from the history.
// Choosing one puts the original and the saved translation on the page — no new request.
import AppKit
import TolkCore

@MainActor
private final class RecentRow: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(entry: HistoryEntry) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
        let meta = "\(entry.sourceLanguage.flag) → \(entry.targetLanguage.flag)  ·  " + Self.date(entry.date)
            + (entry.app.map { "  ·  \($0)" } ?? "")
        let metaLabel = UIFactory.label(meta, size: 10.5, color: Theme.ink3)
        let src = UIFactory.label(oneLine(entry.source), size: 12.5, weight: .medium, color: Theme.ink)
        let dst = UIFactory.label(oneLine(entry.translation), size: 12, color: Theme.ink2)
        for l in [metaLabel, src, dst] {
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        }
        let stack = NSStackView(views: [metaLabel, src, dst])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        for l in [metaLabel, src, dst] { l.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()
    static func date(_ d: Date) -> String { formatter.localizedString(for: d, relativeTo: Date()) }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

@MainActor
final class RecentTranslationsViewController: NSViewController, NSSearchFieldDelegate {
    private let store: HistoryStore
    var onPick: ((HistoryEntry) -> Void)?
    private let search = NSSearchField()
    private let stack = NSStackView()
    private let empty = UIFactory.label("", size: 12, color: Theme.ink3)
    static let limit = 40

    init(store: HistoryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        root.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Поиск по последним переводам"
        search.controlSize = .regular
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedDoc()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        empty.translatesAutoresizingMaskIntoConstraints = false
        for v in [search, scroll, empty] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 420),
            root.heightAnchor.constraint(equalToConstant: 400),
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        reload()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    /// Translations only (not back-translations of other modes), newest first.
    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let q = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = store.search(q).filter { $0.mode == .translate }.prefix(Self.limit)
        for e in list {
            let row = RecentRow(entry: e)
            row.onClick = { [weak self] in self?.onPick?(e) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        empty.stringValue = !list.isEmpty ? "" : q.isEmpty
            ? (store.isEnabled ? "Пока нет переводов" : "История выключена в настройках")
            : "Ничего не найдено"
        empty.isHidden = !list.isEmpty
    }
}
