import Foundation

/// What the popup hands to the big window («Открыть в окне», «Варианты»): everything that goes into the translation
/// request, so the window makes the *same* request and the translation comes from the cache (no new model call).
public struct PopupHandoff: Sendable, Equatable {
    public var text: String
    public var source: Language?
    public var target: Language?
    /// Tone the request was made with (the popup's «Авто» already resolved to the app's tone).
    public var requestTone: Tone
    /// Tone shown on the popup's switch (may be «Авто»): the window shows the same segment.
    public var displayTone: Tone
    public var threadContext: String?

    public init(text: String, source: Language?, target: Language?, requestTone: Tone, displayTone: Tone, threadContext: String?) {
        self.text = text; self.source = source; self.target = target
        self.requestTone = requestTone; self.displayTone = displayTone; self.threadContext = threadContext
    }

    /// The one place that builds the request, used by the popup itself and by the window opened from it.
    public func request() -> TranslationRequest {
        var r = TranslationRequest(text: text, source: source, target: target, tone: requestTone)
        if let t = threadContext, !t.isEmpty { r.threadContext = t }
        return r
    }
}
