// CSV "Термин,Перевод,Комментарий" for sharing a glossary (Excel / Numbers / Google Sheets).
import Foundation

public enum GlossaryCSV {
    public static let header = ["Термин", "Перевод", "Комментарий"]

    /// UTF-8 with BOM (so Excel shows Cyrillic), comma-separated, CRLF, RFC 4180 quoting.
    public static func export(_ entries: [GlossaryEntry]) -> Data {
        var rows = [header]
        rows += entries.filter { !$0.term.glTrimmed.isEmpty }.map { [$0.term, $0.translation, $0.comment] }
        let text = rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data("\u{FEFF}".utf8) + Data(text.utf8)
    }

    /// Accepts comma, semicolon (Excel in RU locale) or tab separators; header row optional.
    public static func parse(_ data: Data) -> [GlossaryEntry] {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else { return [] }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let sep: Character = [",", ";", "\t"].max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","
        var rows = parseRows(text, sep: sep)
        if let first = rows.first?.first?.glTrimmed.lowercased(),
           ["термин", "term", "source", "оригинал", "термін"].contains(first) {
            rows.removeFirst()
        }
        return rows.compactMap { r in
            let term = r.first?.glTrimmed ?? ""
            guard !term.isEmpty else { return nil }
            return GlossaryEntry(term: term,
                                 translation: r.count > 1 ? r[1].glTrimmed : "",
                                 comment: r.count > 2 ? r[2].glTrimmed : "")
        }
    }

    static func quote(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func parseRows(_ text: String, sep: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if quoted {
                if c == "\"" {
                    let n = text.index(after: i)
                    if n < text.endIndex, text[n] == "\"" { field.append("\""); i = n } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i = text.index(after: i)
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
