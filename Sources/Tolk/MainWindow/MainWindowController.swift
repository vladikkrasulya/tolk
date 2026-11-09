// Owned by the "main window" session.
import AppKit
import TolkCore

/// Full app window with a sidebar: Перевод / Фото и скриншоты / Глоссарий / Настройки.
/// While it is open the app shows a Dock icon (`.regular`); when closed it returns to the menu bar (`.accessory`).
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    enum Section: String, CaseIterable {
        case translate, image, documents, history, glossary, settings, help

        var title: String {
            switch self {
            case .translate: "Перевод"
            case .image: "Фото и скриншоты"
            case .documents: "Документы"
            case .history: "История"
            case .glossary: "Глоссарий"
            case .settings: "Настройки"
            case .help: "Как пользоваться"
            }
        }

        var symbol: String {
            switch self {
            case .translate: "character.bubble"
            case .image: "text.viewfinder"
            case .documents: "doc.text"
            case .history: "clock.arrow.circlepath"
            case .glossary: "book.closed"
            case .settings: "gearshape"
            case .help: "questionmark.circle"
            }
        }

        /// ⌘1…⌘4 in the "Окно" menu.
        var keyEquivalent: String {
            switch self {
            case .translate: "1"; case .image: "2"; case .documents: "3"; case .history: "4"
            case .glossary: "5"; case .settings: "6"; case .help: "7"
            }
        }
    }

    private static let sectionKey = "tolk.main.section"
    private static let autosaveName = "TolkMainWindow"

    let pages: [Section: NSViewController]
    private let split = NSSplitViewController()
    private let sidebar: SidebarViewController
    private let content = PageContainerViewController()
    private(set) var current: Section

    /// Called after the window closes (AppDelegate may e.g. release resources). Dock policy is handled here.
    var onClose: (() -> Void)?

    /// Pages are built by AppDelegate and handed in, so each area owns its own view controller.
    init(translate: NSViewController, image: NSViewController, documents: NSViewController, history: NSViewController,
         glossary: NSViewController, settings: NSViewController) {
        pages = [.translate: translate, .image: image, .documents: documents, .history: history,
                 .glossary: glossary, .settings: settings, .help: HelpViewController()]
        current = Section(rawValue: UserDefaults.standard.string(forKey: Self.sectionKey) ?? "") ?? .translate
        sidebar = SidebarViewController(sections: Section.allCases)

        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        super.init(window: window)

        window.title = "Tolk"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.tabbingMode = .disallowed
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 215
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 520
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "TolkMainSplit"
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "TolkMainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = toolbarDelegate
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        // contentViewController resizes the window to the fitting size: restore the intended frame.
        window.setContentSize(NSSize(width: 900, height: 620))
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)

        sidebar.onSelect = { [weak self] in self?.select($0) }
        select(current)
        AppPresence.shared.mainWindow = self
    }
    required init?(coder: NSCoder) { fatalError() }

    private let toolbarDelegate = MainToolbarDelegate()

    /// Shows the window (activating the app) on the given section.
    func show(_ section: Section) {
        select(section)
        present()
    }

    /// Shows the window on the last used section.
    func show() { show(current) }

    var translatePage: TranslatePageViewController? { pages[.translate] as? TranslatePageViewController }

    private func present() {
        AppPresence.shared.windowWillAppear()
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func select(_ section: Section) {
        current = section
        UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey)
        sidebar.select(section)
        if let page = pages[section] { content.show(page) }
        window?.title = section.title
        window?.subtitle = ""
    }

    // MARK: - Menu actions (Окно → Перевод ⌘1 … Настройки ⌘4, Tolk → Настройки ⌘,)

    @objc func showTranslate(_ sender: Any?) { show(.translate) }
    @objc func showImage(_ sender: Any?) { show(.image) }
    @objc func showGlossary(_ sender: Any?) { show(.glossary) }
    @objc func showSettingsSection(_ sender: Any?) { show(.settings) }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        (pages[.translate] as? TranslatePageViewController)?.stop()
        onClose?()
        AppPresence.shared.windowDidClose(excluding: window)
    }
}

// MARK: - Window

/// Main window. With the app `.regular` the main menu handles ⌘C/⌘V/…; the fallback covers the
/// moment the policy flips back while the window is still key.
final class MainWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return EditShortcuts.handle(event)
    }
}

// MARK: - Toolbar

/// Only the sidebar toggle + the tracking separator, like Notes / System Settings.
final class MainToolbarDelegate: NSObject, NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        NSToolbarItem(itemIdentifier: id)
    }
}

// MARK: - Content container

/// Hosts the selected page as a child view controller, below the toolbar (safe area).
final class PageContainerViewController: NSViewController {
    private var currentPage: NSViewController?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        view = v
    }

    func show(_ page: NSViewController) {
        loadViewIfNeeded()
        guard page !== currentPage else { return }
        if let old = currentPage {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(page)
        let pv = page.view
        pv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pv)
        NSLayoutConstraint.activate([
            pv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        currentPage = page
    }
}

// MARK: - Sidebar

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    typealias Section = MainWindowController.Section
    let sections: [Section]
    var onSelect: ((Section) -> Void)?
    private let table = NSTableView()
    private var suppress = false

    init(sections: [Section]) {
        self.sections = sections
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.frame = NSRect(x: 0, y: 0, width: 220, height: 400)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .large
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none
        table.setAccessibilityLabel("Разделы")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = true
        view = scroll
        table.reloadData()
    }

    func select(_ section: Section) {
        loadViewIfNeeded()
        guard let row = sections.firstIndex(of: section), table.selectedRow != row else { return }
        suppress = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        suppress = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = sections[row]
        let id = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let iv = NSImageView()
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            for v in [iv, tf] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
            c.imageView = iv
            c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 22),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 7),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = section.title
        cell.imageView?.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
        cell.imageView?.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        cell.imageView?.contentTintColor = .controlAccentColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, table.selectedRow >= 0 else { return }
        onSelect?(sections[table.selectedRow])
    }

    // Never leave the sidebar without a selection.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.isEmpty ? tableView.selectedRowIndexes : proposed
    }
}
