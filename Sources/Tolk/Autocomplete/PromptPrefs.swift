// Prompt extras from settings: instructions (global + per app + tone + glossary hits), clipboard, length.
// Plugged in by the [prefs] section of AutocompleteFeatures. `examples` are left to the style feature,
// which wraps `c.promptExtras` in its own section (base = whatever is already set).
import AppKit
import TolkCore

@MainActor
final class PromptPrefs {
    private let config: TolkConfig
    private let rules: RulesStore?

    init(config: TolkConfig) {
        self.config = config
        rules = config.autocompleteUseGlossary ? RulesStore(path: config.effectiveRulesPath) : nil
    }

    static func maxWords(for length: String) -> Int {
        switch length { case "short": 3; case "long": 12; default: 6 }
    }

    /// Russian needs ~2 tokens per word; keep a floor for short answers.
    static func maxTokens(forWords w: Int) -> Int { max(14, w * 2 + 3) }

    func extras(for field: FocusedField) -> PromptExtras {
        var e = PromptExtras()
        e.maxWords = Self.maxWords(for: config.autocompleteLength)
        e.instructions = instructions(for: field)
        if config.autocompleteClipboard { e.clipboard = ClipboardWatcher.shared.freshText(excluding: field.textBefore) }
        return e
    }

    func instructions(for field: FocusedField) -> String? {
        var lines: [String] = []
        let general = config.autocompleteInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !general.isEmpty { lines.append(general) }
        if let id = field.bundleID,
           let app = config.autocompleteAppInstructions[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            lines.append(app)
        }
        if config.autocompleteUseGlossary {
            switch config.tone(forApp: field.bundleID) {
            case .chat: lines.append("Casual, conversational tone (informal «ты» in Russian).")
            case .formal: lines.append("Polite, formal, businesslike tone (formal «Вы» in Russian).")
            case .auto: break
            }
            let terms = glossaryLines(for: field.textBefore + "\n" + (ClipboardWatcher.shared.currentText ?? ""))
            if !terms.isEmpty { lines.append("Preferred terms: " + terms.joined(separator: " ")) }
        }
        return lines.isEmpty ? nil : lines.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }

    /// Only the glossary lines that match the text (max 10), as "a → b;".
    private func glossaryLines(for text: String) -> [String] {
        guard let rules else { return [] }
        let block = rules.promptBlock(for: text)
        guard let last = block.components(separatedBy: "\n\n").last else { return [] }
        let rows = last.components(separatedBy: "\n")
        guard let head = rows.first?.lowercased(), head.hasPrefix("#"),
              head.contains("глоссар") || head.contains("глосар") || head.contains("glossary") else { return [] }
        return rows.dropFirst().prefix(10).map {
            var t = $0.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") { t.removeFirst(2) }
            return t.hasSuffix(";") ? t : t + ";"
        }.filter { $0.count > 1 }
    }
}

/// Remembers when the pasteboard last changed, to offer only recent, harmless text.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private var count = NSPasteboard.general.changeCount
    private var changedAt = Date.distantPast
    private var timer: Timer?
    static let maxAge: TimeInterval = 120
    static let maxChars = 500

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let c = NSPasteboard.general.changeCount
        if c != count { count = c; changedAt = Date() }
    }

    /// Tolk's own pasteboard change (paste-insert and restoring the clipboard): not a copy by the user.
    func noteOwnChange(_ newCount: Int) { count = newCount }

    var currentText: String? { freshText(excluding: "") }

    func freshText(excluding typed: String) -> String? {
        poll()
        guard Date().timeIntervalSince(changedAt) <= Self.maxAge else { return nil }
        let pb = NSPasteboard.general
        let types = pb.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return nil }
        guard var s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s.count < Self.maxChars, !Self.looksSecret(s) else { return nil }
        s = s.replacingOccurrences(of: "\r", with: "")
        if typed.contains(s) { return nil }
        return s
    }

    nonisolated static func looksSecret(_ s: String) -> Bool {
        let l = s.lowercased()
        for p in ["sk-", "ghp_", "gho_", "github_pat_", "xox", "akia", "eyj", "bearer ", "-----begin", "password", "пароль", "token", "api_key", "secret"]
            where l.hasPrefix(p) || l.contains(p + " ") || (p.count > 5 && l.contains(p)) { return true }
        // One long token with letters+digits (or symbols) and no spaces: key/password-like.
        if !s.contains(" "), !s.contains("\n"), s.count >= 12 {
            let hasDigit = s.contains { $0.isNumber }, hasLetter = s.contains { $0.isLetter }
            let hasSym = s.contains { !$0.isLetter && !$0.isNumber }
            if hasLetter && hasDigit { return true }
            if hasLetter && hasSym && !s.contains("/") && !s.contains(".") { return true }
        }
        return false
    }
}
