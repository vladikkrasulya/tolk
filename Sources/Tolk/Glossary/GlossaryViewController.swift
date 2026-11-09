// STUB — owned by the "glossary" session.
import AppKit
import TolkCore

/// "Глоссарий" page: table of terms + style rules editor over `~/Translate/rules.md`.
final class GlossaryViewController: NSViewController {
    init(rulesPath: String) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
}
