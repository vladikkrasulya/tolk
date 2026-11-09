// STUB — owned by the "image" session.
import AppKit
import TolkCore

/// "Фото и скриншоты" page: drop/paste/open an image -> OCR (Vision) -> translation.
final class ImageTranslateViewController: NSViewController {
    init(engine: TranslationEngine) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView() }
}

/// Global hotkey -> user selects a screen area -> OCR -> `onText(text, point)` (AppDelegate shows the popup).
final class ScreenCaptureController {
    var onText: ((_ text: String, _ point: NSPoint) -> Void)?
    /// Registers the global hotkey; returns false if registration failed.
    @discardableResult func start() -> Bool { false }
    /// Starts an area selection immediately (menu item).
    func captureNow() {}
}
