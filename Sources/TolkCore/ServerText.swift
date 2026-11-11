// One source of the user-facing wording for «the home model server is unavailable / a fallback translates».
// Menu line, status line, popup, page notices and quick-action HUD all take their text from here, so the same
// state never gets three different phrases. Pure functions (covered by the self-test).
import Foundation

public enum ServerText {
    /// How the home server is called in every window.
    public static let server = "Сервер"
    /// The state itself: «Сервер недоступен».
    public static var unavailable: String { "\(server) недоступен" }

    /// While switching: «Сервер недоступен — переключаюсь на запасной перевод». `name` = the failed provider when it is
    /// not the home server (rare), `fromHome` = it was.
    public static func switching(fromHome: Bool = true, name: String = "") -> String {
        "\(fromHome ? server : name) недоступен — переключаюсь на запасной перевод"
    }

    /// After the switch: «Сервер недоступен — перевод от Google».
    public static func switched(fromHome: Bool = true, name: String = "", to provider: String) -> String {
        "\(fromHome ? server : name) недоступен — перевод от \(provider)"
    }

    /// Menu-bar line under the Tolk icon.
    public static func menuLine(available: Bool, model: String, fallback: String?) -> String {
        if available { return "● Переводит \(model) на сервере" }
        guard let fallback else { return "○ \(unavailable)" }
        return "○ \(unavailable) — переводит \(fallback)"
    }
    public static let menuChecking = "Проверяю сервер…"

    /// Short reason in the status line under a translation (orange).
    public static func statusReason(_ raw: String) -> String {
        let l = raw.lowercased()
        if l.contains("таймаут") || l.contains("timed out") || l.contains("не успел") { return "\(server) не успел ответить" }
        if l.contains("сервер") || l.contains("не отвечает") || l.contains("недоступ") || l.contains("не ответил") { return unavailable }
        return raw
    }

    /// Quick-action HUD after the engine fell back: «Сервер недоступен — переводю… (Google, тон: чат)».
    public static func hudFallback(progress: String) -> String { "\(unavailable) — \(progress)" }
    /// A quick action that cannot work without the home model.
    public static func needsServer(_ what: String) -> String { "\(unavailable) — \(what) без него нельзя" }

    /// A function that only the home model does (variants, rewrite, explain) while a fallback translates.
    public static func homeOnly(_ feature: String) -> String {
        "\(feature) делает домашняя модель, а сервер сейчас недоступен — перевод от запасного сервиса."
    }

}

/// The one wording for Esc everywhere: «закрыть» for a window, «отмена» for something running.
public enum EscText {
    /// Footer / hint of a window.
    public static let closeHint = "Esc — закрыть"
    /// Tooltip of a close button.
    public static let closeTip = "Закрыть (Esc)"
    /// Same, for a window that keeps the unsent draft.
    public static let closeKeepingDraftTip = "Закрыть (Esc) — черновик сохранится"
    /// HUD / overlay while an operation runs.
    public static let cancelHint = "Esc — отмена"
}
