// "Глоссарий" page of the main window: table of terms + "Стиль и правила" editor over `rules.md`.
// Autosaves (debounced) through `GlossaryFile`, follows external changes (popup "В глоссарий",
// VS Code) with `GlossaryFileWatcher`, CSV import/export for sharing.
import AppKit
import TolkCore
import UniformTypeIdentifiers

final class GlossaryViewController: NSViewController {
    private(set) var rulesPath: String
    private var file: GlossaryFile
    private var watcher: GlossaryFileWatcher?
    private(set) var doc: GlossaryDocument

    // Table state: indices into doc.entries, filtered + sorted.
    private var visible: [Int] = []
    private var saveTimer: Timer?
    private var dirty = false
    private var reloadAfterEditing = false
    private var applyingStyle = false

    // Views
    private let tabs = NSSegmentedControl(labels: ["Термины", "Стиль и правила"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let termsPane = NSView()
    private let stylePane = NSView()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let table = GlossaryTableView()
    private let addRemove = NSSegmentedControl()
    private let styleText = NSTextView()
    private let styleCount = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")

    private static let tabKey = "tolk.glossary.tab"
    private enum Col: String, CaseIterable {
        case term, translation, comment
        var title: String {
            switch self { case .term: "Термин"; case .translation: "Перевод"; case .comment: "Комментарий" }
        }
    }

    init(rulesPath: String) {
        self.rulesPath = (rulesPath as NSString).expandingTildeInPath
        self.file = GlossaryFile(path: rulesPath)
        self.doc = file.load()
        super.init(nibName: nil, bundle: nil)
        title = "Глоссарий"
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { watcher?.stop() }

    // MARK: - Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 560))
        view = root

        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentStyle = .automatic
        tabs.selectedSegment = UserDefaults.standard.integer(forKey: Self.tabKey) == 1 ? 1 : 0

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        let status = NSStackView(views: [statusIcon, statusLabel])
        status.spacing = 4

        let header = NSStackView(views: [tabs, NSView(), status])
        header.orientation = .horizontal
        header.alignment = .centerY

        buildTermsPane()
        buildStylePane()

        for v in [header, termsPane, stylePane] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        ])
        for pane in [termsPane, stylePane] {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
                pane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                pane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                pane.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            ])
        }
        applyDocumentToUI()
        tabChanged()
        setStatus(.saved)
    }

    private func buildTermsPane() {
        search.placeholderString = "Поиск по терминам, переводам и комментариям"
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [search, countLabel])
        top.spacing = 12

        for c in Col.allCases {
            let col = NSTableColumn(identifier: .init(c.rawValue))
            col.title = c.title
            col.minWidth = 90
            col.width = c == .comment ? 170 : 200
            col.resizingMask = .userResizingMask
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: true,
                                                           selector: #selector(NSString.localizedStandardCompare(_:)))
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.rowSizeStyle = .medium
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.autosaveName = "TolkGlossaryTable"
        table.autosaveTableColumns = true
        table.menu = rowMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.contentView = scroll

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Добавить"), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Удалить"), forSegment: 1)
        addRemove.setToolTip("Добавить термин (⌘N)", forSegment: 0)
        addRemove.setToolTip("Удалить выбранные (⌫)", forSegment: 1)
        addRemove.trackingMode = .momentary
        addRemove.segmentStyle = .smallSquare
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked(_:))
        for i in 0..<2 { addRemove.setWidth(28, forSegment: i) }

        let importButton = NSButton(title: "Импорт CSV…", target: self, action: #selector(importCSVClicked))
        let exportButton = NSButton(title: "Экспорт CSV…", target: self, action: #selector(exportCSV))
        let revealButton = NSButton(title: "Показать файл", target: self, action: #selector(revealFile))
        revealButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        revealButton.imagePosition = .imageLeading
        revealButton.toolTip = "Показать \(abbreviated(rulesPath)) в Finder — запасной путь: файл можно править в любом редакторе"
        importButton.toolTip = "CSV с колонками: термин, перевод, комментарий (запятая или точка с запятой)"
        exportButton.toolTip = "Сохранить глоссарий в CSV — открывается в Excel, Numbers, Google Таблицах"
        for b in [importButton, exportButton, revealButton] { b.bezelStyle = .rounded; b.controlSize = .regular }

        let bottom = NSStackView(views: [addRemove, NSView(), importButton, exportButton, revealButton])
        bottom.spacing = 8

        let hint = NSTextField(wrappingLabelWithString:
            "Варианты пишите через «/»: «cap / daily cap → капа / дневная капа». В запрос к модели попадают только строки, "
            + "термины которых встречаются в переводимом тексте. Комментарий подсказывает модели контекст.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        for v in [top, box, bottom, hint, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            termsPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: termsPane.topAnchor),
            top.leadingAnchor.constraint(equalTo: termsPane.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: termsPane.trailingAnchor),
            box.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            box.leadingAnchor.constraint(equalTo: termsPane.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: termsPane.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: termsPane.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: termsPane.trailingAnchor),
            hint.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: termsPane.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: termsPane.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: termsPane.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -40),
        ])
    }

    private func buildStylePane() {
        let title = NSTextField(labelWithString: "Стиль и общие правила")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString:
            "Этот текст целиком добавляется в каждый запрос к модели: контекст переписки, тон, что не переводить "
            + "(ID, суммы, названия продуктов), какие аббревиатуры оставлять. Пишите коротко, списком — "
            + "чем длиннее блок, тем медленнее начинается перевод. Термины лучше вносить во вкладку «Термины»: "
            + "они подставляются только когда встречаются в тексте.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        styleText.isRichText = false
        styleText.importsGraphics = false
        styleText.allowsUndo = true
        styleText.font = .systemFont(ofSize: 13)
        styleText.textContainerInset = NSSize(width: 8, height: 10)
        styleText.isAutomaticQuoteSubstitutionEnabled = false
        styleText.isAutomaticDashSubstitutionEnabled = false
        styleText.isAutomaticTextReplacementEnabled = false
        styleText.isAutomaticSpellingCorrectionEnabled = false
        styleText.isContinuousSpellCheckingEnabled = false
        styleText.drawsBackground = true
        styleText.backgroundColor = .textBackgroundColor
        styleText.delegate = self
        styleText.isVerticallyResizable = true
        styleText.isHorizontallyResizable = false
        styleText.autoresizingMask = [.width]
        styleText.textContainer?.widthTracksTextView = true
        styleText.minSize = NSSize(width: 0, height: 0)
        styleText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        styleText.setAccessibilityLabel("Стиль и правила")

        let scroll = NSScrollView()
        scroll.documentView = styleText
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = .textBackgroundColor
        box.contentViewMargins = .zero
        box.contentView = scroll

        styleCount.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        styleCount.textColor = .secondaryLabelColor

        for v in [title, hint, box, styleCount] {
            v.translatesAutoresizingMaskIntoConstraints = false
            stylePane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: stylePane.topAnchor, constant: 2),
            title.leadingAnchor.constraint(equalTo: stylePane.leadingAnchor),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: stylePane.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: stylePane.trailingAnchor),
            box.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            box.leadingAnchor.constraint(equalTo: stylePane.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: stylePane.trailingAnchor),
            styleCount.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 8),
            styleCount.leadingAnchor.constraint(equalTo: stylePane.leadingAnchor),
            styleCount.bottomAnchor.constraint(equalTo: stylePane.bottomAnchor),
        ])
    }

    private func rowMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Добавить термин", action: #selector(addTerm), keyEquivalent: "")
        m.addItem(withTitle: "Изменить", action: #selector(editClicked), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Удалить", action: #selector(removeSelectedAction), keyEquivalent: "")
        m.items.forEach { $0.target = self }
        return m
    }

    // MARK: - Lifecycle

    override func viewWillAppear() {
        super.viewWillAppear()
        if watcher == nil {
            watcher = GlossaryFileWatcher(path: rulesPath) { [weak self] in
                MainActor.assumeIsolated { self?.fileChangedOutside() }
            }
        }
        fileChangedOutside() // catch changes made while the page was hidden
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        view.window?.makeFirstResponder(nil) // commit a cell being edited
        flush()
    }

    @objc private func appWillTerminate() { flush() }

    /// Saves pending changes right away (call on app quit; also done when the page hides).
    func flush() {
        saveTimer?.invalidate(); saveTimer = nil
        if dirty { save() }
    }

    // MARK: - Document <-> UI

    private func applyDocumentToUI() {
        if styleText.string != doc.style {
            applyingStyle = true
            styleText.string = doc.style
            applyingStyle = false
        }
        updateStyleCount()
        rebuildVisible()
    }

    private func rebuildVisible(keepSelection ids: Set<UUID>? = nil) {
        let selected = ids ?? Set(table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? doc.entries[visible[$0]].id : nil })
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var idx = Array(doc.entries.indices)
        if !q.isEmpty {
            idx = idx.filter { i in
                let e = doc.entries[i]
                return e.term.lowercased().contains(q) || e.translation.lowercased().contains(q) || e.comment.lowercased().contains(q)
            }
        }
        if let sd = table.sortDescriptors.first, let key = sd.key, let col = Col(rawValue: key) {
            idx.sort { a, b in
                let x = value(doc.entries[a], col), y = value(doc.entries[b], col)
                let r = x.localizedStandardCompare(y)
                return sd.ascending ? r == .orderedAscending : r == .orderedDescending
            }
        }
        visible = idx
        table.reloadData()
        let rows = IndexSet(visible.indices.filter { selected.contains(doc.entries[visible[$0]].id) })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        updateCount()
    }

    private func value(_ e: GlossaryEntry, _ c: Col) -> String {
        switch c { case .term: e.term; case .translation: e.translation; case .comment: e.comment }
    }

    private func updateCount() {
        let total = doc.entries.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        countLabel.stringValue = q.isEmpty ? Self.terms(total) : "\(visible.count) из \(total)"
        emptyLabel.isHidden = !visible.isEmpty
        emptyLabel.stringValue = q.isEmpty ? "Глоссарий пуст. Нажмите «+», чтобы добавить термин,\nили импортируйте CSV."
                                           : "Ничего не найдено по «\(q)»"
        addRemove.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    static func terms(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = (m10 == 1 && m100 != 11) ? "термин" : ((2...4).contains(m10) && !(12...14).contains(m100)) ? "термина" : "терминов"
        return "\(n) \(w)"
    }

    private func updateStyleCount() {
        let n = styleText.string.count
        styleCount.stringValue = "\(n) симв. · ≈ \(max(0, n / 3)) токенов в каждом запросе"
    }

    // MARK: - Status / saving

    private enum Status { case saved, editing, saving, info(String), error(String) }

    private func setStatus(_ s: Status) {
        let (text, symbol, color): (String, String?, NSColor) = {
            switch s {
            case .saved: return ("Сохранено", "checkmark.circle.fill", .systemGreen)
            case .editing: return ("Изменено…", "pencil.circle", .secondaryLabelColor)
            case .saving: return ("Сохранение…", "arrow.triangle.2.circlepath", .secondaryLabelColor)
            case .info(let t): return (t, "arrow.down.circle.fill", .systemBlue)
            case .error(let t): return (t, "exclamationmark.triangle.fill", .systemRed)
            }
        }()
        statusLabel.stringValue = text
        statusLabel.textColor = { if case .error = s { return .systemRed }; return .secondaryLabelColor }()
        statusIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        statusIcon.contentTintColor = color
        statusLabel.toolTip = abbreviated(rulesPath)
    }

    private func scheduleSave() {
        dirty = true
        setStatus(.editing)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    private func save() {
        saveTimer?.invalidate(); saveTimer = nil
        do {
            let r = try file.save(doc)
            dirty = false
            if r.mergedFromDisk > 0 {
                doc = r.document
                applyDocumentToUI()
                setStatus(.info("Сохранено · из попапа добавлено: \(r.mergedFromDisk)"))
            } else {
                setStatus(.saved)
            }
        } catch {
            setStatus(.error("Не удалось сохранить: \(error.localizedDescription)"))
        }
    }

    /// Settings changed the rules file: save pending edits to the old one, then show the new one.
    func switchFile(to path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded != rulesPath else { return }
        if dirty { save() }
        watcher?.stop(); watcher = nil
        rulesPath = expanded
        file = GlossaryFile(path: expanded)
        doc = file.load()
        guard isViewLoaded else { return }
        applyDocumentToUI()
        rebuildVisible(keepSelection: [])
        if view.window != nil {
            watcher = GlossaryFileWatcher(path: rulesPath) { [weak self] in
                MainActor.assumeIsolated { self?.fileChangedOutside() }
            }
        }
    }

    private func fileChangedOutside() {
        guard file.changedOnDisk() else { return }
        if dirty { save(); return }            // merges what appeared on disk, then writes ours
        if table.editedRow >= 0 { reloadAfterEditing = true; return }
        let selected = Set(table.selectedRowIndexes.compactMap { visible.indices.contains($0) ? doc.entries[visible[$0]].termKey : nil })
        doc = file.load()
        applyDocumentToUI()
        let ids = Set(doc.entries.filter { selected.contains($0.termKey) }.map(\.id))
        rebuildVisible(keepSelection: ids)
        setStatus(.info("Обновлено из файла"))
    }

    // MARK: - Editing (undoable)

    private func setEntries(_ new: [GlossaryEntry], action: String, select: Set<UUID>? = nil) {
        let old = doc.entries
        guard old != new else { return }
        undoManager?.registerUndo(withTarget: self) { vc in
            MainActor.assumeIsolated { vc.setEntries(old, action: action) }
        }
        undoManager?.setActionName(action)
        doc.entries = new
        rebuildVisible(keepSelection: select)
        scheduleSave()
    }

    @objc func addTerm() {
        if tabs.selectedSegment != 0 { tabs.selectedSegment = 0; tabChanged() }
        if !search.stringValue.isEmpty { search.stringValue = "" }
        let e = GlossaryEntry(term: "", translation: "")
        var new = doc.entries
        new.append(e)
        // A blank row stays out of the file until it has a term; no undo step for it.
        doc.entries = new
        rebuildVisible(keepSelection: [e.id])
        guard let row = visible.firstIndex(where: { doc.entries[$0].id == e.id }) else { return }
        table.scrollRowToVisible(row)
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeSelectedAction() { removeSelected() }

    func removeSelected() {
        var rows = table.selectedRowIndexes
        if rows.isEmpty, table.clickedRow >= 0 { rows = [table.clickedRow] }
        let ids = Set(rows.compactMap { visible.indices.contains($0) ? doc.entries[visible[$0]].id : nil })
        guard !ids.isEmpty else { return }
        let next = rows.last.map { $0 + 1 - rows.count }
        setEntries(doc.entries.filter { !ids.contains($0.id) }, action: ids.count == 1 ? "Удаление термина" : "Удаление терминов")
        if let n = next, !visible.isEmpty { table.selectRowIndexes([min(n, visible.count - 1)], byExtendingSelection: false) }
    }

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? addTerm() : removeSelected()
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0 else {
            // Double click on the empty area below the rows = new term (header clicks are not in `table`).
            if let e = NSApp.currentEvent, table.bounds.contains(table.convert(e.locationInWindow, from: nil)) { addTerm() }
            return
        }
        table.editColumn(max(table.clickedColumn, 0), row: row, with: nil, select: true)
    }

    @objc private func editClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func searchChanged() { rebuildVisible() }

    @objc private func tabChanged() {
        let i = tabs.selectedSegment
        termsPane.isHidden = i != 0
        stylePane.isHidden = i != 1
        UserDefaults.standard.set(i, forKey: Self.tabKey)
    }

    // MARK: - Files

    @objc private func revealFile() {
        flush()
        let url = URL(fileURLWithPath: rulesPath)
        if FileManager.default.fileExists(atPath: rulesPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    @objc private func exportCSV() {
        view.window?.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Глоссарий Tolk.csv"
        panel.message = "Термин, перевод и комментарий — откроется в Excel, Numbers или Google Таблицах."
        let entries = doc.entries
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try GlossaryCSV.export(entries).write(to: url, options: .atomic)
                    self?.setStatus(.info("Экспортировано: \(Self.terms(entries.filter { !$0.term.isEmpty }.count))"))
                } catch {
                    self?.setStatus(.error("Не удалось экспортировать: \(error.localizedDescription)"))
                }
            }
        }
        if let w = view.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    @objc private func importCSVClicked() {
        view.window?.makeFirstResponder(nil)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "CSV с колонками: термин, перевод, комментарий"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importCSV(from: url) }
        }
        if let w = view.window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    func importCSV(from url: URL, askHowToMerge: Bool = true) {
        guard let data = try? Data(contentsOf: url) else {
            setStatus(.error("Не удалось прочитать \(url.lastPathComponent)")); return
        }
        let incoming = GlossaryCSV.parse(data)
        guard !incoming.isEmpty else {
            let a = NSAlert()
            a.messageText = "В файле нет терминов"
            a.informativeText = "Ожидается CSV с колонками: термин, перевод, комментарий."
            a.runModal()
            return
        }
        let existing = Set(doc.entries.map(\.termKey))
        let overlap = incoming.filter { existing.contains($0.termKey) }.count
        var overwrite = true
        if askHowToMerge, overlap > 0 {
            let a = NSAlert()
            a.messageText = "Импорт \(Self.terms(incoming.count)) из «\(url.lastPathComponent)»"
            a.informativeText = "\(overlap) из них уже есть в глоссарии. Обновить их перевод и комментарий из файла?"
            a.addButton(withTitle: "Обновить")
            a.addButton(withTitle: "Только новые")
            a.addButton(withTitle: "Отмена")
            switch a.runModal() {
            case .alertFirstButtonReturn: overwrite = true
            case .alertSecondButtonReturn: overwrite = false
            default: return
            }
        }
        var d = doc
        let r = d.merge(incoming, overwrite: overwrite)
        let newIds = Set(d.entries.suffix(r.added).map(\.id))
        setEntries(d.entries, action: "Импорт CSV", select: newIds)
        setStatus(.info("Импорт: добавлено \(r.added), обновлено \(r.updated)"))
        if let first = visible.firstIndex(where: { newIds.contains(doc.entries[$0].id) }) { table.scrollRowToVisible(first) }
    }

    private func abbreviated(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
}

// MARK: - Table

extension GlossaryViewController: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tc = tableColumn, let col = Col(rawValue: tc.identifier.rawValue) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell." + col.rawValue)
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField()
            tf.isBordered = false
            tf.drawsBackground = false
            tf.isEditable = true
            tf.lineBreakMode = .byTruncatingTail
            tf.cell?.usesSingleLineMode = true
            tf.delegate = self
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let e = doc.entries[visible[row]]
        let tf = cell.textField!
        tf.stringValue = value(e, col)
        tf.font = col == .term ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
        tf.textColor = col == .comment ? .secondaryLabelColor : .labelColor
        tf.placeholderString = col == .term ? "термин" : col == .translation ? "перевод" : nil
        tf.toolTip = value(e, col).isEmpty ? nil : value(e, col)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        rebuildVisible()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        addRemove.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        let row = table.row(for: tf), colIndex = table.column(for: tf)
        guard row >= 0, colIndex >= 0, visible.indices.contains(row),
              let col = Col(rawValue: table.tableColumns[colIndex].identifier.rawValue) else { return }
        let i = visible[row]
        var e = doc.entries[i]
        let v = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch col {
        case .term: e.term = v
        case .translation: e.translation = v
        case .comment: e.comment = v
        }
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        let isBlank = e.term.isEmpty && e.translation.isEmpty && e.comment.isEmpty
        if e != doc.entries[i] {
            var new = doc.entries
            new[i] = e
            let wasBlank = doc.entries[i].term.isEmpty && doc.entries[i].translation.isEmpty && doc.entries[i].comment.isEmpty
            setEntriesInPlace(new, row: row, action: wasBlank ? "Добавление термина" : "Изменение термина")
        }
        // Tab / Shift-Tab walk the cells; Return finishes.
        if movement == .tab || movement == .backtab {
            let next = colIndex + (movement == .tab ? 1 : -1)
            if next >= 0, next < table.numberOfColumns {
                DispatchQueue.main.async { self.table.editColumn(next, row: row, with: nil, select: true) }
                return
            }
        }
        if isBlank, movement != .tab, movement != .backtab {
            // Abandoned new row: drop it silently.
            let id = e.id
            doc.entries.removeAll { $0.id == id }
            rebuildVisible()
        }
        if reloadAfterEditing {
            reloadAfterEditing = false
            DispatchQueue.main.async { self.fileChangedOutside() }
        }
    }

    /// Like `setEntries`, but reloads only one row so the order does not jump while editing.
    private func setEntriesInPlace(_ new: [GlossaryEntry], row: Int, action: String) {
        let old = doc.entries
        undoManager?.registerUndo(withTarget: self) { vc in
            MainActor.assumeIsolated { vc.setEntries(old, action: action) }
        }
        undoManager?.setActionName(action)
        doc.entries = new
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<table.numberOfColumns))
        updateCount()
        scheduleSave()
    }
}

// MARK: - Style text

extension GlossaryViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard !applyingStyle, (notification.object as? NSTextView) === styleText else { return }
        doc.style = styleText.string
        updateStyleCount()
        scheduleSave()
    }
}

/// Delete / Backspace removes the selected rows; ⌘N adds a term.
final class GlossaryTableView: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty || flags == .function, [51, 117].contains(event.keyCode), selectedRow >= 0 {
            onDelete?(); return
        }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "n",
           let vc = delegate as? GlossaryViewController {
            vc.addTerm(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
