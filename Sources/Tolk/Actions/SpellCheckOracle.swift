import AppKit
import TolkCore

/// Dictionary for `LayoutFix` via the system spell checker (local, no network). Main thread only.
@MainActor
final class SpellCheckOracle: LayoutOracle {
    static let shared = SpellCheckOracle()
    private let checker = NSSpellChecker.shared
    private lazy var available: [LayoutLanguage: String] = {
        let langs = checker.availableLanguages
        func pick(_ prefix: String) -> String? { langs.first { $0 == prefix } ?? langs.first { $0.hasPrefix(prefix) } }
        var d: [LayoutLanguage: String] = [:]
        if let l = pick("en_US") ?? pick("en") { d[.en] = l }
        if let l = pick("ru") { d[.ru] = l }
        if let l = pick("uk") { d[.uk] = l }
        return d
    }()

    nonisolated func isKnown(_ word: String, _ language: LayoutLanguage) -> Bool? {
        MainActor.assumeIsolated {
            guard let lang = available[language] else { return nil }
            let r = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
            return r.location == NSNotFound
        }
    }
}
