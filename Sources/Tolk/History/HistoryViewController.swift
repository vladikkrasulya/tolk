// «История» page: local history of translations (only on this Mac).
//
// Search + list grouped by day on the left, the selected entry (full texts, copy / open / delete) on the right.
// Reloads on `HistoryStore.didChange` — only while the page is on screen; a hidden page just marks itself stale.
import AppKit
import TolkCore

final class HistoryViewController: NSViewController {
    let store: HistoryStore
    /// «Открыть в переводе» / double click: the coordinator shows the translate page with this entry.
    var onOpen: ((HistoryEntry) -> Void)? { didSet { if isViewLoaded { updateDetail() } } }

    private enum Row {
        case day(String)
        case entry(HistoryEntry)
    }
    private var rows: [Row] = []
    private var stale = true

    // Views
    private let search = NSSearchField()
    private let enabledSwitch = NSSwitch()
    private let clearButton = NSButton(title: "Очистить всё…", target: nil, action: nil)
    private let table = HistoryTableView()
    private let listBox = NSBox()
    private let emptyView = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyText = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    private let detailBox = NSBox()
    private let detailContent = NSStackView()
    private let detailPlaceholder = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let originBadge = BadgeView()
    private let sourceCaption = NSTextField(labelWithString: "")
    private let targetCaption = NSTextField(labelWithString: "")
    private let sourceText = NSTextView()
    private let targetText = NSTextView()
    private var copyTranslationButton: NSButton!
    private var copySourceButton: NSButton!
    private var openButton: NSButton!
    private var deleteButton: NSButton!
    private var copyResetWork: DispatchWorkItem?

    init(store: HistoryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "История"
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: HistoryStore.didChange, object: store)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 690, height: 570))
        view = root

        search.placeholderString = "Поиск по тексту, переводу и приложению"
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        enabledSwitch.controlSize = .small
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        let switchLabel = NSTextField(labelWithString: "Сохранять историю")
        switchLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let switchStack = NSStackView(views: [enabledSwitch, switchLabel])
        switchStack.spacing = 6
        switchStack.toolTip = "Переводы из попапа, ответа, быстрых действий, страниц «Перевод» и «Фото» сохраняются только на этом Mac"

        clearButton.target = self
        clearButton.action = #selector(clearAll)
        clearButton.bezelStyle = .rounded

        let header = NSStackView(views: [search, switchStack, clearButton])
        header.spacing = 14
        header.alignment = .centerY
        header.setCustomSpacing(18, after: search)

        buildList()
        buildDetail()

        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = Theme.ink2
        let hint = NSTextField(labelWithString: "Хранится только на этом Mac — никуда не отправляется")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = Theme.ink3
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? NSImage())
        lock.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        lock.contentTintColor = Theme.ink3
        let footer = NSStackView(views: [countLabel, UIFactory.spacer(), lock, hint])
        footer.spacing = 4

        for v in [header, listBox, detailBox, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            listBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            listBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            listBox.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.47, constant: -20),
            listBox.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            detailBox.topAnchor.constraint(equalTo: listBox.topAnchor),
            detailBox.leadingAnchor.constraint(equalTo: listBox.trailingAnchor, constant: 12),
            detailBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            detailBox.bottomAnchor.constraint(equalTo: listBox.bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
    }

    private func roundedBox(_ box: NSBox) {
        box.boxType = .custom
        box.cornerRadius = TolkStyle.cardRadius
        box.borderColor = Theme.line
        box.borderWidth = 0.5
        box.fillColor = TolkStyle.nsCard
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
    }

    private func buildList() {
        let col = NSTableColumn(identifier: .init("entry"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .inset
        table.floatsGroupRows = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.menu = rowMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        emptyIcon.symbolConfiguration = .init(pointSize: 30, weight: .light)
        emptyIcon.contentTintColor = Theme.ink3
        emptyTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        emptyTitle.textColor = Theme.ink2
        emptyTitle.alignment = .center
        emptyText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyText.textColor = Theme.ink2
        emptyText.alignment = .center
        emptyText.preferredMaxLayoutWidth = 240
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 8
        for v in [emptyIcon, emptyTitle, emptyText] { emptyView.addArrangedSubview(v) }
        emptyView.setCustomSpacing(12, after: emptyIcon)

        let container = NSView()
        for v in [scroll, emptyView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
            emptyText.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        roundedBox(listBox)
        listBox.contentView = container
    }

    private func buildDetail() {
        roundedBox(detailBox)

        metaLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        metaLabel.textColor = Theme.ink2
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let meta = NSStackView(views: [originBadge, metaLabel])
        meta.spacing = 8

        let (sourceScroll, targetScroll) = (textScroll(sourceText, size: 13), textScroll(targetText, size: 14))
        for c in [sourceCaption, targetCaption] {
            c.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            c.textColor = Theme.ink2
        }

        copyTranslationButton = button("Копировать перевод", symbol: "doc.on.doc", #selector(copyTranslation))
        copyTranslationButton.keyEquivalent = "\r"
        copyTranslationButton.bezelColor = Theme.accentStrong
        copySourceButton = button("Копировать оригинал", symbol: nil, #selector(copySource))
        openButton = button("Открыть в переводе", symbol: "arrow.up.forward.app", #selector(openInTranslate))
        deleteButton = button("Удалить", symbol: "trash", #selector(deleteSelected))
        deleteButton.toolTip = "Удалить запись (⌫)"
        let buttons1 = NSStackView(views: [copyTranslationButton, copySourceButton, UIFactory.spacer()])
        buttons1.spacing = 8
        let buttons2 = NSStackView(views: [openButton, UIFactory.spacer(), deleteButton])
        buttons2.spacing = 8

        detailContent.orientation = .vertical
        detailContent.alignment = .leading
        detailContent.spacing = 6
        for v in [meta, sourceCaption, sourceScroll, targetCaption, targetScroll, buttons1, buttons2] {
            detailContent.addArrangedSubview(v)
        }
        detailContent.setCustomSpacing(14, after: meta)
        detailContent.setCustomSpacing(14, after: sourceScroll)
        detailContent.setCustomSpacing(14, after: targetScroll)
        detailContent.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for v in [sourceScroll, targetScroll, buttons1, buttons2, meta] {
            v.widthAnchor.constraint(equalTo: detailContent.widthAnchor, constant: -32).isActive = true
        }
        sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        targetScroll.heightAnchor.constraint(equalTo: sourceScroll.heightAnchor).isActive = true
        sourceScroll.setContentHuggingPriority(.init(1), for: .vertical)
        targetScroll.setContentHuggingPriority(.init(1), for: .vertical)

        detailPlaceholder.textColor = Theme.ink3
        detailPlaceholder.alignment = .center
        detailPlaceholder.font = .systemFont(ofSize: 13)

        let container = NSView()
        for v in [detailContent, detailPlaceholder] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            detailContent.topAnchor.constraint(equalTo: container.topAnchor),
            detailContent.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            detailContent.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailContent.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            detailPlaceholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            detailPlaceholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        detailBox.contentView = container
    }

    private func textScroll(_ tv: NSTextView, size: CGFloat) -> NSScrollView {
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: size)
        tv.textColor = Theme.ink
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let s = NSScrollView()
        s.documentView = tv
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.drawsBackground = false
        s.borderType = .noBorder
        return s
    }

    private func button(_ title: String, symbol: String?, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        if let symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
        }
        return b
    }

    private func rowMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Копировать перевод", action: #selector(copyTranslation), keyEquivalent: "").target = self
        m.addItem(withTitle: "Копировать оригинал", action: #selector(copySource), keyEquivalent: "").target = self
        m.addItem(withTitle: "Открыть в переводе", action: #selector(openInTranslate), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Удалить", action: #selector(deleteSelected), keyEquivalent: "").target = self
        return m
    }

    // MARK: - Lifecycle / reload

    override func viewWillAppear() {
        super.viewWillAppear()
        if stale { reload() }
    }

    @objc private func storeChanged() {
        stale = true
        guard isViewLoaded, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else { return }
        reload()
    }

    /// Rebuilds the list from the store (keeps the selection by id).
    func reload() {
        loadViewIfNeeded()
        stale = false
        let selected = selectedEntries.map(\.id)
        let entries = store.search(search.stringValue)
        rows = Self.group(entries)
        table.reloadData()
        let keep = IndexSet(rows.indices.filter { if case let .entry(e) = rows[$0] { selected.contains(e.id) } else { false } })
        table.selectRowIndexes(keep, byExtendingSelection: false)

        enabledSwitch.state = store.isEnabled ? .on : .off
        let total = store.count
        clearButton.isEnabled = total > 0
        countLabel.stringValue = search.stringValue.isEmpty
            ? (total == 0 ? "" : Self.entriesText(total))
            : "Найдено: \(entries.count) из \(total)"
        updateEmptyState(total: total, shown: entries.count)
        updateDetail()
    }

    private func updateEmptyState(total: Int, shown: Int) {
        emptyView.isHidden = shown > 0
        guard shown == 0 else { return }
        if total > 0 {
            emptyIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            emptyTitle.stringValue = "Ничего не найдено"
            emptyText.stringValue = "Попробуйте другое слово — поиск идёт по оригиналу, переводу и названию приложения."
        } else if !store.isEnabled {
            emptyIcon.image = NSImage(systemSymbolName: "clock.badge.xmark", accessibilityDescription: nil)
            emptyTitle.stringValue = "История выключена"
            emptyText.stringValue = "Включите «Сохранять историю», чтобы Tolk запоминал переводы. Они хранятся только на этом Mac."
        } else {
            emptyIcon.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            emptyTitle.stringValue = "История пуста"
            emptyText.stringValue = "Здесь появятся переводы из попапа, окна ответа, быстрых действий, страниц «Перевод» "
                + "и «Фото». История хранится только на этом Mac и никуда не отправляется."
        }
    }

    // MARK: - Grouping and texts

    private static func group(_ entries: [HistoryEntry]) -> [Row] {
        var rows: [Row] = []
        var lastDay: Date?
        let cal = Calendar.current
        for e in entries {
            let day = cal.startOfDay(for: e.date)
            if day != lastDay { rows.append(.day(dayTitle(day))); lastDay = day }
            rows.append(.entry(e))
        }
        return rows
    }

    static func dayTitle(_ day: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Сегодня" }
        if cal.isDateInYesterday(day) { return "Вчера" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        let days = cal.dateComponents([.day], from: day, to: cal.startOfDay(for: now)).day ?? 99
        if days < 7 { f.dateFormat = "EEEE, d MMMM" }
        else if cal.component(.year, from: day) == cal.component(.year, from: now) { f.dateFormat = "d MMMM" }
        else { f.dateFormat = "d MMMM yyyy" }
        let s = f.string(from: day)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }

    static func originTitle(_ origin: String) -> String {
        switch origin {
        case "popup": "Попап"
        case "reply": "Ответ"
        case "quick": "Замена"
        case "page": "Перевод"
        case "image": "Фото"
        case "document": "Документ"
        default: origin
        }
    }

    static func originColor(_ origin: String) -> NSColor {
        switch origin {
        case "popup": .systemBlue
        case "reply": Theme.ok
        case "quick": .systemOrange
        case "page": .systemPurple
        case "image": .systemPink
        default: .systemTeal
        }
    }

    static func entriesText(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let word = (m10 == 1 && m100 != 11) ? "запись"
            : ((2...4).contains(m10) && !(12...14).contains(m100)) ? "записи" : "записей"
        return "\(n) \(word)"
    }

    static func snippet(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Selection / detail

    private var selectedEntries: [HistoryEntry] {
        table.selectedRowIndexes.compactMap { i in
            guard i < rows.count, case let .entry(e) = rows[i] else { return nil }
            return e
        }
    }

    /// Entries the action applies to: the selection, or the right-clicked row.
    private var actionEntries: [HistoryEntry] {
        let clicked = table.clickedRow
        if clicked >= 0, clicked < rows.count, !table.selectedRowIndexes.contains(clicked),
           case let .entry(e) = rows[clicked] { return [e] }
        return selectedEntries
    }

    private func updateDetail() {
        let sel = selectedEntries
        guard sel.count == 1, let e = sel.first else {
            detailContent.isHidden = true
            detailPlaceholder.isHidden = false
            detailPlaceholder.stringValue = sel.count > 1
                ? "Выбрано: \(Self.entriesText(sel.count)) — ⌫ удалит их"
                : (rows.isEmpty ? "" : "Выберите запись")
            return
        }
        detailContent.isHidden = false
        detailPlaceholder.isHidden = true
        originBadge.text = Self.originTitle(e.origin)
        originBadge.tint = Self.originColor(e.origin)
        let cal = Calendar.current
        let day = cal.isDateInToday(e.date) || cal.isDateInYesterday(e.date)
            ? Self.dayTitle(e.date) : Self.dayTitle(e.date).replacingOccurrences(of: ", ", with: " ")
        var parts = ["\(day), \(Self.time(e.date))"]
        if let app = e.app, !app.isEmpty { parts.append(app) }
        parts.append(UIText.providerName(e.provider))
        metaLabel.stringValue = parts.joined(separator: " · ")
        metaLabel.toolTip = metaLabel.stringValue
        if e.mode == .polish {
            sourceCaption.stringValue = "Исходный текст · \(UIText.capitalized(e.sourceLanguage))"
            targetCaption.stringValue = "Причёсано"
        } else {
            sourceCaption.stringValue = "Оригинал · \(UIText.capitalized(e.sourceLanguage))"
            targetCaption.stringValue = "Перевод · \(UIText.capitalized(e.targetLanguage))"
        }
        if sourceText.string != e.source { sourceText.string = e.source; sourceText.scrollToBeginningOfDocument(nil) }
        if targetText.string != e.translation { targetText.string = e.translation; targetText.scrollToBeginningOfDocument(nil) }
        openButton.isHidden = onOpen == nil
        copyTranslationButton.title = "Копировать перевод"
        copySourceButton.title = "Копировать оригинал"
    }

    // MARK: - Actions

    @objc private func searchChanged() { reload() }

    @objc private func toggleEnabled() {
        store.isEnabled = enabledSwitch.state == .on
        reload()
    }

    @objc private func clearAll() {
        let n = store.count
        guard n > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Очистить всю историю?"
        alert.informativeText = "\(Self.entriesText(n).prefix(1).uppercased() + Self.entriesText(n).dropFirst()) будут удалены с этого Mac. Это нельзя отменить."
        let ok = alert.addButton(withTitle: "Очистить")
        ok.hasDestructiveAction = true
        alert.addButton(withTitle: "Отмена")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .alertFirstButtonReturn { self?.store.clear() }
        }
        if let w = view.window { alert.beginSheetModal(for: w, completionHandler: done) } else { done(alert.runModal()) }
    }

    @objc private func copyTranslation() {
        let list = actionEntries
        guard !list.isEmpty else { return }
        Clipboard.copy(list.map(\.translation).joined(separator: "\n\n"))
        flash(copyTranslationButton, "Скопировано")
    }

    @objc private func copySource() {
        let list = actionEntries
        guard !list.isEmpty else { return }
        Clipboard.copy(list.map(\.source).joined(separator: "\n\n"))
        flash(copySourceButton, "Скопировано")
    }

    private func flash(_ b: NSButton, _ text: String) {
        guard selectedEntries.count == 1 else { return }
        b.title = text
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateDetail() }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    @objc private func openInTranslate() {
        guard let e = actionEntries.first else { return }
        onOpen?(e)
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count, case let .entry(e) = rows[r] else { return }
        onOpen?(e)
    }

    @objc func deleteSelected() {
        let ids = Set(actionEntries.map(\.id))
        guard !ids.isEmpty else { return }
        // Select the neighbour, so ⌫ ⌫ ⌫ walks down the list.
        let next = (table.selectedRowIndexes.last.map { $0 + 1 } ?? 0)
        var nextID: UUID?
        for i in next..<max(next, rows.count) { if case let .entry(e) = rows[i], !ids.contains(e.id) { nextID = e.id; break } }
        if nextID == nil {
            for i in stride(from: (table.selectedRowIndexes.first ?? 0) - 1, through: 0, by: -1) {
                if case let .entry(e) = rows[i], !ids.contains(e.id) { nextID = e.id; break }
            }
        }
        store.remove(ids: ids)
        // Apply right away (don't wait for the async notification).
        rows = Self.group(store.search(search.stringValue))
        table.reloadData()
        if let nextID, let i = rows.firstIndex(where: { if case let .entry(e) = $0 { e.id == nextID } else { false } }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        }
        reload()
    }
}

// MARK: - Table

extension HistoryViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .day = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .day = rows[row] { return 26 }
        return 58
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .day = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .day(title):
            let id = NSUserInterfaceItemIdentifier("day")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let l = NSTextField(labelWithString: "")
                l.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                l.textColor = Theme.ink2
                l.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(l)
                c.textField = l
                NSLayoutConstraint.activate([
                    l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    l.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = title
            return cell
        case let .entry(e):
            let id = NSUserInterfaceItemIdentifier("entry")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCellView ?? {
                let c = HistoryCellView()
                c.identifier = id
                return c
            }()
            cell.configure(e)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }
}

final class HistoryTableView: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty || flags == .function || flags == .command, [51, 117].contains(event.keyCode), selectedRow >= 0 {
            onDelete?(); return
        }
        super.keyDown(with: event)
    }
}

/// Row: «14:32 · [icon] Telegram ……… [Попап]» / source snippet / «→ translation snippet».
final class HistoryCellView: NSTableCellView {
    private let timeLabel = UIFactory.label("", size: 11, color: Theme.ink2)
    private let appIcon = NSImageView()
    private let appLabel = UIFactory.label("", size: 11, color: Theme.ink2)
    private let badge = BadgeView()
    private let sourceLabel = UIFactory.label("", size: 13, color: Theme.ink)
    private let translationLabel = UIFactory.label("", size: 12, color: Theme.ink2)

    private static var iconCache: [String: NSImage] = [:]

    init() {
        super.init(frame: .zero)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        appLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.label.font = .systemFont(ofSize: 10, weight: .semibold)
        let top = NSStackView(views: [timeLabel, appIcon, appLabel, UIFactory.spacer(), badge])
        top.spacing = 5
        top.setCustomSpacing(8, after: timeLabel)
        let stack = NSStackView(views: [top, sourceLabel, translationLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in [sourceLabel, translationLabel] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            translationLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ e: HistoryEntry) {
        timeLabel.stringValue = HistoryViewController.time(e.date)
        let app = e.app ?? ""
        appLabel.stringValue = app
        appLabel.isHidden = app.isEmpty
        appIcon.image = Self.icon(for: e.appBundleID)
        appIcon.isHidden = appIcon.image == nil
        badge.text = HistoryViewController.originTitle(e.origin)
        badge.tint = HistoryViewController.originColor(e.origin)
        sourceLabel.stringValue = HistoryViewController.snippet(e.source)
        translationLabel.stringValue = "→ " + HistoryViewController.snippet(e.translation)
        toolTip = nil
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // Selected row (emphasized): keep text readable on the accent color.
            let selected = backgroundStyle == .emphasized
            sourceLabel.textColor = selected ? .alternateSelectedControlTextColor : Theme.ink
            for l in [timeLabel, appLabel, translationLabel] {
                l.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : Theme.ink2
            }
        }
    }

    private static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let img = iconCache[bundleID] { return img }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 14, height: 14)
        iconCache[bundleID] = img
        return img
    }
}
