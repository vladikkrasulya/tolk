// Row of compact rewrite buttons above the translation: Короче · Мягче · Твёрже · Проще · [ты|Вы].
// In a narrow card the buttons fold into one «Переписать ▾» menu. While a request runs: spinner and «Отмена».
import AppKit
import TolkCore

@MainActor
final class RewriteBar: NSView {
    var onMode: ((RewriteMode) -> Void)?
    var onCancel: (() -> Void)?

    private let buttons: [(RewriteMode, NSButton)]
    private let pronoun = NSSegmentedControl(labels: ["ты", "Вы"], trackingMode: .selectOne, target: nil, action: nil)
    private let foldMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let spinner = NSProgressIndicator()
    private let cancel = NSButton(title: "Отмена", target: nil, action: nil)
    private let busyLabel = UIFactory.label("", size: 11.5, color: .secondaryLabelColor)
    private let row = NSStackView()
    private var compact = false
    private var busy = false
    private var enabled = false

    static let plainModes: [RewriteMode] = [.shorter, .softer, .firmer, .simpler]

    override init(frame: NSRect) {
        buttons = Self.plainModes.map { mode in
            let b = NSButton(title: mode.russianTitle, target: nil, action: nil)
            b.bezelStyle = .roundRect
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11.5)
            b.toolTip = Self.tip(mode)
            b.setContentCompressionResistancePriority(.init(700), for: .horizontal)
            return (mode, b)
        }
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for (i, (mode, b)) in buttons.enumerated() {
            b.target = self; b.action = #selector(plainClicked(_:)); b.tag = i
            _ = mode
        }
        pronoun.target = self
        pronoun.action = #selector(pronounClicked(_:))
        pronoun.controlSize = .small
        pronoun.font = .systemFont(ofSize: 11.5)
        pronoun.selectedSegment = -1
        pronoun.segmentStyle = .rounded
        pronoun.setToolTip(Self.tip(.informal), forSegment: 0)
        pronoun.setToolTip(Self.tip(.formal), forSegment: 1)
        pronoun.setContentCompressionResistancePriority(.init(700), for: .horizontal)

        foldMenu.controlSize = .small
        foldMenu.font = .systemFont(ofSize: 11.5)
        foldMenu.bezelStyle = .roundRect
        foldMenu.addItem(withTitle: "Переписать")
        for mode in Self.plainModes + [.informal, .formal] {
            let item = NSMenuItem(title: mode.russianTitle, action: #selector(menuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            foldMenu.menu?.addItem(item)
        }
        foldMenu.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        cancel.bezelStyle = .roundRect
        cancel.controlSize = .small
        cancel.font = .systemFont(ofSize: 11.5)
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.isHidden = true
        busyLabel.isHidden = true
        busyLabel.lineBreakMode = .byTruncatingTail
        busyLabel.setContentCompressionResistancePriority(.init(300), for: .horizontal)

        row.setViews(buttons.map(\.1) + [pronoun, foldMenu, busyLabel, UIFactory.spacer(), spinner, cancel], in: .leading)
        row.orientation = .horizontal
        row.spacing = 5
        row.setClippingResistancePriority(.init(1), for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    static func tip(_ mode: RewriteMode) -> String {
        switch mode {
        case .shorter: "Сократить перевод, сохранив факты и вопросы"
        case .softer: "Смягчить тон: вежливее, без резкостей"
        case .firmer: "Сделать твёрже и увереннее, без грубости"
        case .simpler: "Проще слова и короче фразы"
        case .informal: "Перейти на «ты»"
        case .formal: "Перейти на «Вы»"
        }
    }

    // MARK: State

    /// Buttons available (a translation is on screen and nothing else blocks).
    func setEnabled(_ e: Bool) { enabled = e; apply() }

    /// A request for `mode` is running (nil: idle).
    func setBusy(_ mode: RewriteMode?) {
        busy = mode != nil
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        busyLabel.stringValue = mode.map { "Переписываю: \($0.russianTitle)…" } ?? ""
        busyLabel.isHidden = !busy
        cancel.isHidden = !busy
        apply()
    }

    /// Which of ты / Вы the shown translation already is (nil: unknown).
    func setPronoun(_ mode: RewriteMode?) {
        pronoun.selectedSegment = mode == .informal ? 0 : mode == .formal ? 1 : -1
    }

    func setCompact(_ c: Bool) { guard c != compact else { return }; compact = c; apply() }

    private func apply() {
        // While a request runs the buttons give way to «Переписываю…», a spinner and «Отмена»: the row never gets wider.
        for (_, b) in buttons { b.isHidden = compact || busy; b.isEnabled = enabled && !busy }
        pronoun.isHidden = compact || busy
        pronoun.isEnabled = enabled && !busy
        foldMenu.isHidden = !compact || busy
        foldMenu.isEnabled = enabled && !busy
    }

    // MARK: Actions

    @objc private func plainClicked(_ sender: NSButton) { onMode?(buttons[sender.tag].0) }
    @objc private func pronounClicked(_ sender: NSSegmentedControl) {
        onMode?(sender.selectedSegment == 0 ? .informal : .formal)
    }
    @objc private func menuPicked(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = RewriteMode(rawValue: raw) { onMode?(m) }
    }
    @objc private func cancelClicked() { onCancel?() }
}
