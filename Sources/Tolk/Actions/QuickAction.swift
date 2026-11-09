// Owned by the "quick actions" session.
import Carbon.HIToolbox
import TolkCore

/// One quick action: take the selection in any app → run it through the engine → paste the result in place.
/// To add a new action (e.g. "translate to German and replace"): add a `static let` and put it into `all`.
/// Hotkey storage, registration, HUD and the settings page pick it up from `all` automatically.
struct QuickAction: Hashable, Sendable {
    /// Stable key for UserDefaults — never rename.
    let id: String
    /// Title for settings / menus.
    let title: String
    let mode: TextMode
    /// Fixed target language; nil = engine default direction (RU/UA → EN, anything else → RU).
    let target: Language?
    /// HUD verb while working: "Перевожу".
    let progressVerb: String
    let defaultHotKey: HotKeyCombo?

    /// Polish has no Google fallback — the engine fails if Qwen is down.
    var needsQwen: Bool { mode == .polish }

    func request(text: String, tone: Tone) -> TranslationRequest {
        TranslationRequest(text: text, source: nil, target: target, tone: tone, mode: mode)
    }

    static let translateReplace = QuickAction(
        id: "translateReplace", title: "Перевести и заменить", mode: .translate, target: nil,
        progressVerb: "Перевожу",
        defaultHotKey: HotKeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)))

    static let polishReplace = QuickAction(
        id: "polishReplace", title: "Причесать и заменить", mode: .polish, target: nil,
        progressVerb: "Причёсываю",
        defaultHotKey: HotKeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey)))

    /// Order = order on the settings page.
    static let all: [QuickAction] = [.translateReplace, .polishReplace]

    static func with(id: String) -> QuickAction? { all.first { $0.id == id } }
}

/// Russian texts of the HUD (pure functions — covered by the self-test).
enum QuickActionText {
    static func toneName(_ tone: Tone) -> String {
        switch tone { case .auto: "авто"; case .chat: "чат"; case .formal: "письмо" }
    }

    /// "Перевожу… (Qwen, тон: чат)"; provider nil while the engine has not started yet.
    static func progress(verb: String, provider: String?, tone: Tone) -> String {
        var parts: [String] = []
        if let provider, !provider.isEmpty { parts.append(providerName(provider)) }
        parts.append("тон: \(toneName(tone))")
        return "\(verb)… (\(parts.joined(separator: ", ")))"
    }

    /// After the engine fell back to Google.
    static func fallback(verb: String, provider: String, tone: Tone) -> String {
        "Модель на vkbox недоступна — " + progress(verb: verb.lowercased(), provider: provider, tone: tone)
    }

    static func providerName(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("qwen") || s.contains("ollama") { return "Qwen" }
        if s.contains("google") { return "Google" }
        return raw
    }

    static let noSelection = "Нет выделенного текста"
    static let busy = "Подождите — предыдущее действие ещё идёт"
    static let done = "Готово ✓"
    static let noAccessibility = "Нужен доступ «Универсальный доступ» для Tolk"
    static let qwenDown = "Модель на vkbox недоступна — причесать текст без неё нельзя"
    static let appChanged = "Окно сменилось — текст не вставлен"
    static let empty = "Пустой ответ — ничего не вставлено"
    static func timeout(_ seconds: Int) -> String { "Нет ответа за \(seconds) с — отменено" }
}
