// A short hash of the rules file (style + glossary) of a profile. Caches of finished translations include it in their
// key, so «Add to glossary» or an edit of the file invalidates stale entries. Re-reads the file only when its
// modification time or size changes.
import Foundation
import CryptoKit

public enum RulesFingerprint {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (stamp: String, hash: String)] = [:]

    /// 16 hex chars; "none" when the file does not exist (built-in rules are then used and never change at run time).
    public static func of(path: String) -> String {
        let p = expandPath(path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: p)
        guard let attrs else { return "none" }
        let stamp = "\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\((attrs[.size] as? NSNumber)?.intValue ?? 0)"
        lock.lock(); defer { lock.unlock() }
        if let c = cache[p], c.stamp == stamp { return c.hash }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data()
        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        cache[p] = (stamp, hash)
        return hash
    }
}

extension RulesStore {
    /// Fingerprint of the active rules file (style block and glossary).
    public var rulesFingerprint: String { RulesFingerprint.of(path: path) }
}

extension DefaultTranslationEngine {
    public var rulesFingerprint: String { rules.rulesFingerprint }
}
