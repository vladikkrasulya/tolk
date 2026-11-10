import AppKit
import TolkCore

/// Small non-activating plate near the mouse cursor: spinner + status, or a short result message.
/// Never takes focus and ignores the mouse, so the user's app keeps the keyboard and the selection.
@MainActor
final class QuickActionHUD {
    enum Kind { case progress, success, info, error }

    private var panel: NSPanel?
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: EscText.cancelHint)
    private var hideWork: DispatchWorkItem?
    private var anchor: NSPoint = .zero

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows a spinner with `text`. `at` = screen point (mouse) — kept for later updates.
    func showProgress(_ text: String, at point: NSPoint? = nil) {
        if let point { anchor = point }
        show(text, kind: .progress, autoHide: nil)
    }

    /// Updates the text without moving the plate.
    func update(_ text: String) {
        guard isVisible else { return }
        label.stringValue = text
        layout()
    }

    func showMessage(_ text: String, kind: Kind, at point: NSPoint? = nil) {
        if let point { anchor = point }
        let duration: TimeInterval
        switch kind {
        case .success: duration = 0.8
        case .info: duration = 1.4
        case .error: duration = 3.0
        case .progress: duration = 0
        }
        show(text, kind: kind, autoHide: duration > 0 ? duration : nil)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        spinner.stopAnimation(nil)
        panel?.orderOut(nil)
    }

    // MARK: - Private

    private func show(_ text: String, kind: Kind, autoHide: TimeInterval?) {
        build()
        hideWork?.cancel()
        hideWork = nil
        label.stringValue = text
        hint.isHidden = kind != .progress
        spinner.isHidden = kind != .progress
        icon.isHidden = kind == .progress
        if kind == .progress { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        switch kind {
        case .success: setIcon("checkmark.circle.fill", .systemGreen)
        case .info: setIcon("info.circle.fill", .secondaryLabelColor)
        case .error: setIcon("exclamationmark.triangle.fill", .systemOrange)
        case .progress: break
        }
        layout()
        panel?.orderFrontRegardless()
        if let autoHide {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: w)
        }
    }

    private func setIcon(_ symbol: String, _ color: NSColor) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
    }

    private func layout() {
        guard let panel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let w = min(max(size.width, 120), 460), h = max(size.height, 32)
        // Below-right of the cursor, kept on the screen that contains it.
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.x + 14, y: anchor.y - 18 - h)
        if let vf = screen?.visibleFrame {
            if origin.x + w > vf.maxX - 8 { origin.x = vf.maxX - 8 - w }
            if origin.x < vf.minX + 8 { origin.x = vf.minX + 8 }
            if origin.y < vf.minY + 8 { origin.y = anchor.y + 18 } // no room below → above the cursor
            if origin.y + h > vf.maxY - 8 { origin.y = vf.maxY - 8 - h }
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
    }

    private func build() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .utilityWindow

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.maskImage = Self.roundedMask(radius: 10)
        p.contentView = effect

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [spinner, icon, label, hint])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel = p
    }

    /// Stretchable rounded-rect mask (corners stay round at any size).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}
