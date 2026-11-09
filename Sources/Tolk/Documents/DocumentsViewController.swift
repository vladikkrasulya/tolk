// STUB — owned by the "documents" helper. Whole-document translation page.
import AppKit
import TolkCore

final class DocumentsViewController: NSViewController {
    var engine: TranslationEngine
    init(engine: TranslationEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil); title = "Документы" }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
    /// Main window closed: stop a running document translation.
    func cancelWork() {}
}
