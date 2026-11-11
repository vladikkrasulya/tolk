import Foundation

/// The system prompt of a translation, for the settings page («Проверка: весь запрос целиком»).
public enum PromptPreview {
    public static func system(for r: ResolvedRequest, rules: String) -> String { Prompt.system(for: r, rules: rules) }
}
