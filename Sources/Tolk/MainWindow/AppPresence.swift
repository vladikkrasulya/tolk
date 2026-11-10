import AppKit

/// Dock icon + main menu. The app lives in the menu bar (`.accessory`); while the main window
/// (or another regular window) is open it becomes a normal app with a Dock icon and a main menu.
@MainActor
final class AppPresence: NSObject {
    static let shared = AppPresence()

    /// Set by AppDelegate; menu items "Настройки…" and ⌘1…⌘4 open sections in it.
    weak var mainWindow: MainWindowController?

    private var closeObserver: NSObjectProtocol?
    /// Set by AppDelegate: the last regular app (not Tolk) the user had in front.
    var previousApp: (() -> NSRunningApplication?)?

    /// Makes Tolk the active app with `window` in front. The plain `NSApp.activate()` is only a request on
    /// macOS 14+: opened from the status menu, a hotkey or the popup (Tolk is not the active app at that moment)
    /// the window came up *behind* the app the user was in and keystrokes kept going there.
    static func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The policy switch accessory → regular lands a moment later and can swallow the first request
        // (seen on a Dock / `open` reopen): ask again until Tolk really is the frontmost app.
        for delay in [0.12, 0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard window.isVisible, NSWorkspace.shared.frontmostApplication != NSRunningApplication.current else { return }
                Diagnostics.log("window not in front after \(delay)s — activating again")
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Call before showing a window that should give the app a Dock icon.
    func windowWillAppear() {
        installMainMenuIfNeeded()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if closeObserver == nil {
            // Any closing regular window may be the last one: re-check then.
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                   object: nil, queue: .main) { [weak self] note in
                let w = note.object as? NSWindow
                MainActor.assumeIsolated { self?.windowDidClose(excluding: w) }
            }
        }
    }

    /// Back to menu-bar only when no regular window is left on screen.
    func windowDidClose(excluding closing: NSWindow?) {
        // willClose fires while the window is still visible: decide on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, NSApp.activationPolicy() == .regular else { return }
                let others = NSApp.windows.filter { w in
                    w !== closing && w.isVisible && !(w is NSPanel) && w.styleMask.contains(.titled)
                        && w.level == .normal && w.className != "NSStatusBarWindow"
                }
                guard others.isEmpty else { return }
                let wasActive = NSApp.isActive
                NSApp.setActivationPolicy(.accessory)
                // Without a window Tolk would stay the active app: an empty menu bar and keystrokes going
                // nowhere until the user clicks something. Hand the focus back to the app they were in.
                if wasActive, let app = self.previousApp?(), !app.isTerminated {
                    app.activate()
                    Diagnostics.log("last window closed — focus back to \(app.localizedName ?? "?")")
                }
                if let o = self.closeObserver { NotificationCenter.default.removeObserver(o); self.closeObserver = nil }
            }
        }
    }

    // MARK: - Main menu (Tolk / Правка / Окно)

    private var menuInstalled = false

    func installMainMenuIfNeeded() {
        guard !menuInstalled else { return }
        menuInstalled = true
        let main = NSMenu()

        // Tolk
        let app = NSMenu(title: "Tolk")
        app.addItem(item("О программе Tolk", #selector(about), target: self))
        app.addItem(.separator())
        app.addItem(item("Настройки…", #selector(openSettings), key: ",", target: self))
        app.addItem(.separator())
        app.addItem(item("Скрыть Tolk", #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item("Скрыть остальные", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(item("Показать все", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Выйти из Tolk", #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenu(app))

        // Правка
        let edit = NSMenu(title: "Правка")
        edit.addItem(item("Отменить", Selector(("undo:")), key: "z"))
        let redo = item("Повторить", Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Вырезать", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Копировать", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Вставить", #selector(NSText.paste(_:)), key: "v"))
        let pasteMatch = item("Вставить без форматирования", #selector(NSTextView.pasteAsPlainText(_:)), key: "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(pasteMatch)
        edit.addItem(item("Удалить", #selector(NSText.delete(_:))))
        edit.addItem(item("Выбрать все", #selector(NSText.selectAll(_:)), key: "a"))
        edit.addItem(.separator())
        let find = NSMenu(title: "Найти")
        let findItem = item("Найти…", #selector(NSTextView.performFindPanelAction(_:)), key: "f")
        findItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        find.addItem(findItem)
        let next = item("Найти далее", #selector(NSTextView.performFindPanelAction(_:)), key: "g")
        next.tag = Int(NSFindPanelAction.next.rawValue)
        find.addItem(next)
        edit.addItem(submenu(find))
        main.addItem(submenu(edit))

        // Окно
        let window = NSMenu(title: "Окно")
        window.addItem(item("Свернуть", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Изменить масштаб", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        for section in MainWindowController.Section.allCases {
            let i = item(section.title, #selector(openSection(_:)), key: section.keyEquivalent, target: self)
            i.representedObject = section.rawValue
            window.addItem(i)
        }
        window.addItem(.separator())
        window.addItem(item("Закрыть окно", #selector(NSWindow.performClose(_:)), key: "w"))
        window.addItem(.separator())
        window.addItem(item("Все окна — на передний план", #selector(NSApplication.arrangeInFront(_:))))
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target
        return i
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    @objc private func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Tolk",
            .applicationVersion: version,
            .version: "",
            .credits: NSAttributedString(string: "Личный переводчик: двойной ⌘C — и перевод у курсора.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
        NSApp.activate()
    }

    @objc private func openSettings() { mainWindow?.show(.settings) }

    @objc private func openSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let section = MainWindowController.Section(rawValue: raw) else { return }
        mainWindow?.show(section)
    }
}
