// Chat headers copied from Telegram («Name Surname, [9 лист. 2026 р., 15:03:57]:») are not text to translate.
// The prompt asks the model to leave them alone, but it still transliterated names now and then («Иван Петров» →
// «Ivan Petrov»). This filter makes it certain: header lines of the answer are replaced by the source headers, in order.
import Foundation

public enum ChatHeaderKeeper {
    static let pattern = #"^[^\n\[\]]{2,80},\s\[[^\]\n]{0,40}\d{1,2}:\d{2}(?::\d{2})?[^\]\n]{0,6}\]:"#
    static let regex = try! NSRegularExpression(pattern: pattern)

    /// Header lines of `text`, in order (only the header part, without anything after «]:»).
    public static func headers(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { header(of: $0) }
    }

    static func header(of line: String) -> String? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    /// One finished line of the answer: its header (if it has one) swapped for the next source header.
    static func fix(line: String, sources: [String], next: inout Int) -> String {
        guard next < sources.count, let h = header(of: line) else { return line }
        defer { next += 1 }
        return sources[next] + line.dropFirst(h.count)
    }

    /// Whole-text variant (tests, non-streaming callers).
    public static func restore(_ translation: String, source: String) -> String {
        let src = headers(in: source)
        guard !src.isEmpty else { return translation }
        var next = 0
        return translation.components(separatedBy: "\n").map { fix(line: $0, sources: src, next: &next) }.joined(separator: "\n")
    }

    /// Streaming variant: texts without headers pass through untouched; with headers the answer is released line by line.
    public static func stream(_ upstream: AsyncThrowingStream<String, Error>, source: String) -> AsyncThrowingStream<String, Error> {
        let src = headers(in: source)
        guard !src.isEmpty else { return upstream }
        return AsyncThrowingStream { c in
            let task = Task {
                do {
                    var pending = "", next = 0
                    for try await chunk in upstream {
                        try Task.checkCancellation()
                        pending += chunk
                        while let nl = pending.firstIndex(of: "\n") {
                            let line = String(pending[..<nl])
                            pending = String(pending[pending.index(after: nl)...])
                            c.yield(fix(line: line, sources: src, next: &next) + "\n")
                        }
                    }
                    if !pending.isEmpty { c.yield(fix(line: pending, sources: src, next: &next)) }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

extension SelfTest {
    static func chatHeaders(_ check: Check) {
        let src = "Иван Петров, [10 ноя 2026, 09:12]:\nМы вчера отправили акт.\n\nJavier Corchuelo, [9 лист. 2026 р., 15:03:57]:\nОк"
        check(ChatHeaderKeeper.headers(in: src) == ["Иван Петров, [10 ноя 2026, 09:12]:", "Javier Corchuelo, [9 лист. 2026 р., 15:03:57]:"], "header: found in source")
        let out = "Ivan Petrov, [Nov 10, 2026, 09:12]:\nWe sent the statement yesterday.\n\nJavier Corchuelo, [Nov 9, 2026, 3:03:57 PM]:\nOK"
        check(ChatHeaderKeeper.restore(out, source: src) == "Иван Петров, [10 ноя 2026, 09:12]:\nWe sent the statement yesterday.\n\nJavier Corchuelo, [9 лист. 2026 р., 15:03:57]:\nOK", "header: restored in order")
        check(ChatHeaderKeeper.restore("Ivan Petrov, [Nov 10, 2026, 09:12]: We sent it.", source: "Иван Петров, [10 ноя 2026, 09:12]:\nОтправили.") == "Иван Петров, [10 ноя 2026, 09:12]: We sent it.", "header: text on the header line is kept")
        check(ChatHeaderKeeper.restore("Call at 10:30, [urgent]: yes", source: "Созвон в 10:30, срочно") == "Call at 10:30, [urgent]: yes", "header: no source headers, nothing touched")
        check(ChatHeaderKeeper.headers(in: "Смотри, [это важно]: позвони в 10").isEmpty, "header: a bracket without a time is not a header")
    }
}
