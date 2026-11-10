// First launch on a fresh Mac (no ~/Translate/tolk.json): one small screen over the main window.
// Two languages and a note about the home network; «Готово» writes the config once.
import AppKit
import TolkCore

@MainActor
final class FirstRunView: NSVisualEffectView {
    /// True when there is no config file yet. Evaluate before anything can save the config.
    static var isNeeded: Bool {
        !FileManager.default.fileExists(atPath: (TolkConfig.defaultPath as NSString).expandingTildeInPath)
    }

    /// Covers the window's content until «Готово».
    static func present(in window: NSWindow?, onDone: (() -> Void)? = nil) {
        guard let content = window?.contentView else { return }
        let v = FirstRunView(onDone: onDone)
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.makeFirstResponder(v.doneButton)
    }

    /// Russian unless the system language is Ukrainian.
    static var defaultMyLanguage: Language {
        (Locale.preferredLanguages.first ?? "").hasPrefix("uk") ? .ukrainian : .russian
    }

    private let mine = NSPopUpButton(frame: .zero, pullsDown: false)
    private let target = NSPopUpButton(frame: .zero, pullsDown: false)
    let doneButton = NSButton(title: "Готово", target: nil, action: nil)
    private let onDone: (() -> Void)?

    init(onDone: (() -> Void)?) {
        self.onDone = onDone
        super.init(frame: .zero)
        material = .windowBackground
        blendingMode = .withinWindow
        state = .active

        let title = UIFactory.label("Добро пожаловать в Tolk", size: 22, weight: .semibold)
        let sub = UIFactory.label("Два вопроса — и можно переводить", size: 13, color: .secondaryLabelColor)
        for p in [mine, target] {
            p.addItems(withTitles: Language.allCases.map { "\($0.flag)  " + UIText.capitalized($0) })
            p.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        mine.selectItem(at: Language.allCases.firstIndex(of: Self.defaultMyLanguage) ?? 0)
        target.selectItem(at: Language.allCases.firstIndex(of: .english) ?? 0)
        func row(_ caption: String, _ popup: NSPopUpButton) -> NSStackView {
            let l = UIFactory.label(caption, size: 13)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let r = NSStackView(views: [l, popup])
            r.spacing = 10
            return r
        }
        let note = UIFactory.wrappingLabel("Модель работает только в домашней сети. Вне дома перевод идёт через запасной сервис.",
                                           size: 12, color: .secondaryLabelColor)
        note.alignment = .center
        note.preferredMaxLayoutWidth = 320
        doneButton.bezelStyle = .push
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(done)

        let stack = NSStackView(views: [title, sub, row("Мой язык", mine), row("Перевожу на", target), note, doneButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(22, after: sub)
        stack.setCustomSpacing(18, after: target.superview ?? target)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func done() {
        let all = Language.allCases
        let my = all[max(0, mine.indexOfSelectedItem)]
        var other = all[max(0, target.indexOfSelectedItem)]
        if other == my { other = my == .english ? .russian : .english }
        var config = TolkConfig()
        config.primaryLanguage = my
        config.secondaryLanguage = other
        do { try config.save() } catch { NSLog("Tolk: first-run config not saved: \(error)") }
        removeFromSuperview()
        onDone?()
    }
}
