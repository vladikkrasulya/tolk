// Extension points of AutocompleteController. Each feature plugs in from its own file:
//   instant suggestions (emoji, autocorrect) — answered without the model, before it is asked;
//   prompt extras (instructions, glossary, clipboard, style examples, length) — added to the model prompt;
//   accepted / sent text — for learning the user's style.
import AppKit

/// A suggestion that replaces the last `replaceCount` characters before the caret with `text`
/// (emoji for ":smile", the fixed word for a typo). `display` is what the ghost text shows.
struct InstantSuggestion {
    var replaceCount: Int
    var text: String
    var display: String
    /// While shown, the model is not asked (e.g. a suspected typo).
    var blocksModel: Bool = true
}

/// Extra material for the model prompt. Every field is optional.
struct PromptExtras {
    /// Writing instructions: global + per-app + tone, plus glossary terms relevant to the text.
    var instructions: String?
    /// Recently copied text, if fresh.
    var clipboard: String?
    /// The user's own earlier messages in a similar situation (style examples).
    var examples: [String] = []
    /// Max words in a suggestion (nil = default).
    var maxWords: Int?
}

/// What the user took or sent; for learning their style.
struct AcceptedText {
    enum Kind { case word, all, sent }
    var kind: Kind
    var bundleID: String?
    /// For .word/.all: text before the caret when the suggestion was shown. For .sent: the whole message.
    var textBefore: String
    var accepted: String
}

/// Synchronous providers called before the model. First non-nil wins.
@MainActor protocol InstantSuggestionProvider: AnyObject {
    func suggestion(for field: FocusedField) -> InstantSuggestion?
}
