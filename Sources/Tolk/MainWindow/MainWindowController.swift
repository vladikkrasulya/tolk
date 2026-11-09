// STUB — owned by the "main window" session.
import AppKit
import TolkCore

/// Full app window with a sidebar: Перевод / Фото и скриншоты / Глоссарий / Настройки.
/// While it is open the app shows a Dock icon (`.regular`); when closed it returns to the menu bar (`.accessory`).
final class MainWindowController: NSWindowController {
    enum Section: String, CaseIterable { case translate, image, glossary, settings }

    /// Pages are built by AppDelegate and handed in, so each area owns its own view controller.
    init(translate: NSViewController, image: NSViewController, glossary: NSViewController, settings: NSViewController) {
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the window (activating the app) on the given section.
    func show(_ section: Section) {}
}

/// "Перевод" page: text in, live translation out (like the input window, embedded in the main window).
final class TranslatePageViewController: NSViewController {
    init(engine: TranslationEngine) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
    /// Puts text into the input and translates it (used by the popup's "expand" button).
    func load(text: String) {}
}

/// "Настройки" page: edits `TolkConfig` and saves it with `TolkConfig.save()`.
final class SettingsViewController: NSViewController {
    init(config: TolkConfig) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
}
