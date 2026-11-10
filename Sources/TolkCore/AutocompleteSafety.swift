// Pure safety rules of the system-wide autocomplete (no AppKit): which apps and fields are never touched,
// whether a suggestion may still be inserted into the field the user is in now, and how often a typo
// fix may be refused before it is silenced. Checked by `tolk-cli --self-test`.
import Foundation

public enum AutocompleteSafety {
    // MARK: Apps

    /// Never read or suggested into, whatever the user's list says; merged with `autocompleteOffApps`.
    public static let builtinOffApps: Set<String> = [
        // Password managers
        "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "org.keepassx.keepassxc", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "com.enpass.Enpass",
        // Terminals and editors (kept in sync with TolkConfig.defaultAutocompleteOffApps, but never removable)
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    public static func isOffApp(_ bundleID: String?, userList: Set<String>) -> Bool {
        guard let bundleID else { return false }
        return builtinOffApps.contains(bundleID) || userList.contains(bundleID)
    }

    // MARK: Password fields

    /// Role / subrole / role description / labels of the focused AX element. Anything that looks like a password
    /// field (not only `AXSecureTextField`) is refused.
    public static func looksLikeSecureField(role: String, subrole: String, roleDescription: String, labels: [String] = []) -> Bool {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return true }
        let rd = roleDescription.lowercased()
        for k in ["secure", "password", "парол", "защищ", "passcode", "пароль"] where rd.contains(k) { return true }
        for l in labels {
            let s = l.lowercased()
            for k in ["password", "passwd", "passcode", "парол", "пин-код", "cvv", "cvc"] where s.contains(k) { return true }
        }
        return false
    }

    // MARK: Snapshots

    /// What a suggestion was built for.
    public struct FieldSnapshot: Equatable {
        public var pid: Int32
        public var bundleID: String?
        public var textBefore: String
        public init(pid: Int32, bundleID: String?, textBefore: String) {
            self.pid = pid; self.bundleID = bundleID; self.textBefore = textBefore
        }
    }

    public enum Decision: Equatable {
        case apply
        case skip(String)
    }

    /// Same cap as `FocusedField.contextLimit`: the field reports only the tail of the text, which slides as the user types.
    public static let contextLimit = 1500

    /// May the suggestion shown for `shown` be inserted now, given a fresh read `now`?
    /// `now == nil` (read failed or ran out of time) means skip. `sameElement` is the AX element identity check.
    /// With `requireLineEnd` the caret must still be at the end of its line (rest of the line is blank).
    public static func decide(shown: FieldSnapshot, now: FieldSnapshot?, restOfLine: String = "",
                              sameElement: Bool = true, requireLineEnd: Bool = true) -> Decision {
        guard let now else { return .skip("no-read") }
        if now.pid != shown.pid { return .skip("pid") }
        if now.bundleID != shown.bundleID { return .skip("bundle") }
        if !sameElement { return .skip("element") }
        if now.textBefore.suffix(contextLimit) != shown.textBefore.suffix(contextLimit) { return .skip("text") }
        if requireLineEnd, !restOfLine.allSatisfy({ $0.isWhitespace }) { return .skip("rest-of-line") }
        return .apply
    }

    // MARK: Typo-fix rejections

    /// Counts refusals of a typo fix per word. A refusal is explicit (Esc) or implicit (the user typed past the
    /// fix); the word is silenced only after `threshold` refusals in a row. Accepting a fix, or the word being
    /// offered again and accepted, resets the count. The set of silenced words is capped (oldest dropped).
    public struct RejectionTracker {
        public let threshold: Int
        public let capacity: Int
        private var counts: [String: Int] = [:]
        private var silenced: [String] = []   // oldest first

        public init(threshold: Int = 3, capacity: Int = 200) {
            self.threshold = max(1, threshold); self.capacity = max(1, capacity)
        }

        public func isSilenced(_ word: String) -> Bool { silenced.contains(word.lowercased()) }
        public var silencedWords: [String] { silenced }
        public var pendingCount: Int { counts.count }

        public mutating func reject(_ word: String) {
            let key = word.lowercased()
            guard !silenced.contains(key) else { return }
            let n = (counts[key] ?? 0) + 1
            if n >= threshold {
                counts[key] = nil
                silenced.append(key)
                if silenced.count > capacity { silenced.removeFirst(silenced.count - capacity) }
            } else {
                counts[key] = n
                if counts.count > capacity { counts = counts.filter { $0.key == key } }
            }
        }

        public mutating func accepted(_ word: String) { counts[word.lowercased()] = nil }
        public mutating func reset() { counts = [:]; silenced = [] }
    }
}

extension SelfTest {
    static func autocompleteSafety(_ check: Check) {
        typealias S = AutocompleteSafety
        // Apps
        check(S.isOffApp("com.1password.1password", userList: []), "safety: 1Password always off")
        check(S.isOffApp("com.apple.keychainaccess", userList: []), "safety: Keychain Access always off")
        check(S.isOffApp("com.apple.Terminal", userList: []), "safety: Terminal off even with an empty user list")
        check(S.isOffApp("com.example.custom", userList: ["com.example.custom"]), "safety: user list is merged")
        check(!S.isOffApp("com.apple.TextEdit", userList: ["com.example.custom"]), "safety: ordinary app is allowed")
        check(!S.isOffApp(nil, userList: []), "safety: no bundle id is not off")
        // Secure fields
        check(S.looksLikeSecureField(role: "AXTextField", subrole: "AXSecureTextField", roleDescription: ""), "safety: secure subrole")
        check(S.looksLikeSecureField(role: "AXTextField", subrole: "", roleDescription: "secure text field"), "safety: secure role description")
        check(S.looksLikeSecureField(role: "AXTextField", subrole: "", roleDescription: "защищённое поле пароля"), "safety: RU role description")
        check(S.looksLikeSecureField(role: "AXTextField", subrole: "", roleDescription: "text field", labels: ["Enter password"]), "safety: password label")
        check(!S.looksLikeSecureField(role: "AXTextArea", subrole: "", roleDescription: "text entry area", labels: ["Message"]), "safety: normal field")
        // Decisions
        let shown = S.FieldSnapshot(pid: 10, bundleID: "a.b", textBefore: "Hello wor")
        check(S.decide(shown: shown, now: shown) == .apply, "safety: same field applies")
        check(S.decide(shown: shown, now: nil) == .skip("no-read"), "safety: failed read skips")
        check(S.decide(shown: shown, now: .init(pid: 11, bundleID: "a.b", textBefore: "Hello wor")) == .skip("pid"), "safety: other pid skips")
        check(S.decide(shown: shown, now: .init(pid: 10, bundleID: "c.d", textBefore: "Hello wor")) == .skip("bundle"), "safety: other bundle skips")
        check(S.decide(shown: shown, now: .init(pid: 10, bundleID: "a.b", textBefore: "Hello wo")) == .skip("text"), "safety: changed text skips")
        check(S.decide(shown: shown, now: shown, sameElement: false) == .skip("element"), "safety: other element skips")
        check(S.decide(shown: shown, now: shown, restOfLine: "x") == .skip("rest-of-line"), "safety: text after caret skips")
        check(S.decide(shown: shown, now: shown, restOfLine: "  ") == .apply, "safety: blank rest of line applies")
        check(S.decide(shown: shown, now: shown, restOfLine: "x", requireLineEnd: false) == .apply, "safety: line end not required")
        let long = String(repeating: "a", count: 1500) + "b"
        check(S.decide(shown: .init(pid: 1, bundleID: nil, textBefore: long),
                       now: .init(pid: 1, bundleID: nil, textBefore: String(long.suffix(1500)))) == .apply, "safety: sliding 1500-char window equals")
        // Rejections
        var t = S.RejectionTracker(threshold: 3, capacity: 3)
        t.reject("Teh"); t.reject("teh")
        check(!t.isSilenced("teh"), "safety: two refusals do not silence")
        t.accepted("teh"); t.reject("teh"); t.reject("teh")
        check(!t.isSilenced("teh"), "safety: acceptance resets the count")
        t.reject("teh")
        check(t.isSilenced("TEH"), "safety: third refusal in a row silences")
        for w in ["aaa", "bbb", "ccc", "ddd"] { for _ in 0..<3 { t.reject(w) } }
        check(t.silencedWords.count == 3 && !t.isSilenced("teh") && t.isSilenced("ddd"), "safety: silenced list is capped, oldest dropped")
        t.reset()
        check(t.silencedWords.isEmpty, "safety: reset clears")
    }
}
