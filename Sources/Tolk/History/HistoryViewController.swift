// STUB — owned by the "history" helper. «История» page.
import AppKit
import TolkCore

final class HistoryViewController: NSViewController {
    init(store: HistoryStore) { super.init(nibName: nil, bundle: nil); title = "История" }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
}
