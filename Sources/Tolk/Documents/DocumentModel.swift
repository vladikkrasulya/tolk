// Owned by the "documents" helper. Document model + text extraction (PDF text layer / OCR, rich text, plain text).
import AppKit
import PDFKit
import TolkCore
import UniformTypeIdentifiers

/// Rough look of a source paragraph, reused for the preview and the exported file.
struct ParagraphStyle: Sendable, Equatable {
    /// Font family of the paragraph's first run (rich text only).
    var fontFamily: String?
    /// Point size of the first run (rich text only).
    var fontSize: CGFloat?
    var bold = false
    var italic = false
    /// NSTextAlignment raw value.
    var alignment = NSTextAlignment.natural.rawValue
    /// 0 = body text, 1…3 = heading (1 = biggest).
    var headingLevel = 0
}

/// One unit of translation: a paragraph, heading or list item.
struct DocParagraph: Sendable, Equatable {
    /// Text without the list marker.
    var text: String
    /// List marker kept as is ("• ", "1. ", "\t•\t"). Empty for ordinary paragraphs.
    var prefix = ""
    var style = ParagraphStyle()
    /// False for code blocks and paragraphs without words (numbers, symbols): copied to the translation as is.
    var translatable = true
    /// 1-based PDF page, nil for other formats.
    var page: Int?

    var fullText: String { prefix + text }

    /// Prefix for Word / RTF / plain text: Markdown heading marks dropped, Markdown bullets become "• ".
    var richPrefix: String {
        let p = prefix.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("#") { return "" }
        if p == "-" || p == "*" || p == "+" { return "• " }
        if p == ">" { return "" }
        return prefix
    }

    /// Prefix for Markdown: bullets become "- ", numbers stay, tabs removed.
    var markdownPrefix: String {
        let p = prefix.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p.hasPrefix("#") || p == ">" { return p.isEmpty ? "" : p + " " }
        if let c = p.first, "•●▪◦·‣–—-*+✓✔".contains(c) { return "- " }
        return p + " "
    }
}

enum DocumentKind: Sendable, Equatable {
    case pdf, rich, plain, markdown
}

struct ExtractedDocument: Sendable {
    var url: URL
    var name: String
    var kind: DocumentKind
    var paragraphs: [DocParagraph]
    /// PDF page count; nil for other formats.
    var pageCount: Int?
    /// PDF pages read with OCR (no text layer).
    var ocrPages = 0

    var characterCount: Int { paragraphs.reduce(0) { $0 + $1.fullText.count } }
    var translatableCharacters: Int { paragraphs.reduce(0) { $0 + ($1.translatable ? $1.text.count : 0) } }
    /// Page count for the PDF, or an estimate (~1800 characters per page) for text formats.
    var approximatePages: Int { pageCount ?? max(1, Int((Double(characterCount) / 1800).rounded(.up))) }
    /// Source language (by the first ~4000 characters of text).
    var dominantLanguage: Language? {
        var sample = ""
        for p in paragraphs where p.translatable {
            sample += p.text + "\n"
            if sample.count > 4000 { break }
        }
        return sample.filter(\.isLetter).count >= 3 ? LanguageDetector.detect(sample) : nil
    }
}

enum DocumentError: LocalizedError {
    case unsupported(String)
    case unreadable(String, String?)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(name):
            "Формат файла «\(name)» не поддерживается. Подойдут PDF, Word (DOCX, DOC), RTF, ODT, HTML, TXT и Markdown."
        case let .unreadable(name, detail):
            "Не удалось открыть «\(name)»" + (detail.map { ": \($0)" } ?? ".")
        case let .empty(name):
            "В файле «\(name)» не найден текст."
        }
    }
}

/// Reads documents into paragraphs. Everything except HTML runs off the main thread.
enum DocumentExtractor {
    /// PDF page with fewer letters than this in its text layer is treated as a scan (rendered + OCR).
    static let ocrLetterThreshold = 40

    static let pdfExtensions: Set<String> = ["pdf"]
    static let richExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive"]
    static let plainExtensions: Set<String> = ["txt", "text"]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]

    static var allExtensions: Set<String> { pdfExtensions.union(richExtensions).union(plainExtensions).union(markdownExtensions) }

    static var openPanelTypes: [UTType] {
        allExtensions.compactMap { UTType(filenameExtension: $0) } + [.pdf, .rtf, .rtfd, .html, .plainText]
    }

    static func canOpen(_ url: URL) -> Bool { allExtensions.contains(url.pathExtension.lowercased()) }

    /// Progress while reading: (page, of pages, page is being recognized with OCR).
    typealias Progress = @Sendable (Int, Int, Bool) -> Void

    /// Reads the file. HTML is parsed on the main actor (WebKit requirement); the rest in a background task.
    static func extract(_ url: URL, progress: Progress? = nil) async throws -> ExtractedDocument {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        guard allExtensions.contains(ext) else { throw DocumentError.unsupported(name) }
        let doc: ExtractedDocument
        if ext == "html" || ext == "htm" || ext == "webarchive" {
            // WebKit-based import must run on the main thread; HTML pages are small, splitting is quick.
            let paragraphs = try await MainActor.run { richParagraphs(try loadAttributed(url)) }
            doc = ExtractedDocument(url: url, name: name, kind: .rich, paragraphs: paragraphs)
        } else {
            doc = try await Task.detached(priority: .userInitiated) { () throws -> ExtractedDocument in
                if pdfExtensions.contains(ext) { return try extractPDF(url, progress: progress) }
                if markdownExtensions.contains(ext) {
                    return ExtractedDocument(url: url, name: name, kind: .markdown, paragraphs: markdownParagraphs(try readPlain(url)))
                }
                if plainExtensions.contains(ext) {
                    return ExtractedDocument(url: url, name: name, kind: .plain, paragraphs: plainParagraphs(try readPlain(url)))
                }
                return ExtractedDocument(url: url, name: name, kind: .rich, paragraphs: richParagraphs(try loadAttributed(url)))
            }.value
        }
        guard !doc.paragraphs.isEmpty else { throw DocumentError.empty(name) }
        return doc
    }

    // MARK: - Rich text

    static func loadAttributed(_ url: URL) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch url.pathExtension.lowercased() {
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        case "html", "htm":
            options[.documentType] = NSAttributedString.DocumentType.html
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        case "webarchive": options[.documentType] = NSAttributedString.DocumentType.webArchive
        default: break
        }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            throw DocumentError.unreadable(url.lastPathComponent, error.localizedDescription)
        }
    }

    /// Splits rich text into paragraphs; style = attributes of the paragraph's first visible character.
    static func richParagraphs(_ attr: NSAttributedString) -> [DocParagraph] {
        let ns = attr.string as NSString
        var result: [DocParagraph] = []
        var sizes: [CGFloat: Int] = [:] // font size -> characters (to find the body size)
        var listItems: [ObjectIdentifier: Int] = [:] // NSTextList -> items seen (for "1.", "2." markers)
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let raw = ns.substring(with: range)
            // Line separators (U+2028) inside a paragraph become spaces-with-newline; the model keeps them.
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}\u{2029}\u{0C}")))
            guard !text.isEmpty else { continue }
            let firstVisible = (raw as NSString).rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
            let at = range.location + (firstVisible.location == NSNotFound ? 0 : firstVisible.location)
            var style = ParagraphStyle()
            if let font = attr.attribute(.font, at: at, effectiveRange: nil) as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                style.fontFamily = font.familyName
                style.fontSize = font.pointSize
                style.bold = traits.contains(.bold)
                style.italic = traits.contains(.italic)
                sizes[font.pointSize.rounded(), default: 0] += text.count
            }
            var listMarker = ""
            if let ps = attr.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle {
                style.alignment = ps.alignment.rawValue
                // RTF / ODT lists keep the marker in the paragraph style, not in the text.
                if let list = ps.textLists.last {
                    let n = (listItems[ObjectIdentifier(list)] ?? 0) + 1
                    listItems[ObjectIdentifier(list)] = n
                    listMarker = list.marker(forItemNumber: n)
                }
            }
            var (prefix, body) = splitListMarker(text)
            if prefix.isEmpty, !listMarker.isEmpty { prefix = listMarker + "\t" }
            result.append(DocParagraph(text: body, prefix: prefix, style: style, translatable: hasWords(body)))
        }
        // Headings: noticeably bigger than the body size, or short, fully bold lines without a final period.
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        let bigger = Set(sizes.keys.filter { $0 >= body * 1.15 }).sorted(by: >)
        for i in result.indices {
            let p = result[i]
            guard p.prefix.isEmpty, p.text.count <= 200 else { continue }
            if let size = p.style.fontSize?.rounded(), let rank = bigger.firstIndex(of: size) {
                result[i].style.headingLevel = min(3, rank + 1)
            } else if p.style.bold, p.text.count <= 120, !p.text.contains("\n"),
                      let last = p.text.last, !".,;".contains(last) {
                result[i].style.headingLevel = 3
            }
        }
        return result
    }

    // MARK: - Plain text / Markdown

    static func readPlain(_ url: URL) throws -> String {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw DocumentError.unreadable(name, nil) }
        if let s = String(data: data, encoding: .utf8) { return s }
        var converted: NSString?
        _ = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if let converted { return converted as String }
        if let s = String(data: data, encoding: .windowsCP1251) { return s }
        throw DocumentError.unreadable(name, "неизвестная кодировка")
    }

    /// Paragraphs are separated by blank lines; a file without blank lines is split by lines.
    static func plainParagraphs(_ text: String) -> [DocParagraph] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let hasBlankLines = normalized.range(of: "\n[ \t]*\n", options: .regularExpression) != nil
        let parts: [String]
        if hasBlankLines {
            parts = normalized.replacingOccurrences(of: "\n[ \t]*\n\\s*", with: "\u{0}", options: .regularExpression)
                .components(separatedBy: "\u{0}")
        } else {
            parts = normalized.components(separatedBy: "\n")
        }
        return parts.compactMap { part in
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let (prefix, body) = splitListMarker(t)
            return DocParagraph(text: body, prefix: prefix, translatable: hasWords(body))
        }
    }

    /// Markdown: headings (#), list items, fenced code (kept as is), paragraphs (lines joined).
    static func markdownParagraphs(_ text: String) -> [DocParagraph] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [DocParagraph] = []
        var buffer: [String] = []
        var inCode = false
        var code: [String] = []

        func flush() {
            let t = buffer.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            buffer = []
            guard !t.isEmpty else { return }
            result.append(DocParagraph(text: t, translatable: hasWords(t)))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    code.append(line)
                    result.append(DocParagraph(text: code.joined(separator: "\n"), translatable: false))
                    code = []; inCode = false
                } else {
                    flush(); inCode = true; code = [line]
                }
                continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if let m = trimmed.range(of: "^#{1,6}[ \t]+", options: .regularExpression) {
                flush()
                let level = trimmed[m].filter { $0 == "#" }.count
                let body = String(trimmed[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                var p = DocParagraph(text: body, prefix: String(repeating: "#", count: level) + " ", translatable: hasWords(body))
                p.style.headingLevel = min(3, level)
                p.style.bold = true
                result.append(p)
                continue
            }
            if trimmed.range(of: "^([-*+]|\\d{1,3}[.)]|>)[ \t]+", options: .regularExpression) != nil {
                flush()
                let (prefix, body) = splitListMarker(trimmed, markdown: true)
                result.append(DocParagraph(text: body, prefix: prefix, translatable: hasWords(body)))
                continue
            }
            if trimmed.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil
                || trimmed.hasPrefix("|") || trimmed.hasPrefix("<") {
                flush()
                // Rules, tables and raw HTML: translate table/HTML text but keep rules as is.
                result.append(DocParagraph(text: trimmed, translatable: trimmed.hasPrefix("|") && hasWords(trimmed)))
                continue
            }
            buffer.append(line)
        }
        if inCode, !code.isEmpty { result.append(DocParagraph(text: code.joined(separator: "\n"), translatable: false)) }
        flush()
        return result
    }

    // MARK: - PDF

    static func extractPDF(_ url: URL, progress: Progress?) throws -> ExtractedDocument {
        let name = url.lastPathComponent
        guard let pdf = PDFDocument(url: url) else { throw DocumentError.unreadable(name, nil) }
        if pdf.isLocked { throw DocumentError.unreadable(name, "файл защищён паролем") }
        var paragraphs: [DocParagraph] = []
        var ocrPages = 0
        let count = pdf.pageCount
        for i in 0..<count {
            if Task.isCancelled { throw CancellationError() }
            guard let page = pdf.page(at: i) else { continue }
            let text = page.string ?? ""
            let letters = text.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
            if letters < ocrLetterThreshold {
                progress?(i + 1, count, true)
                let ocr: OCRResult? = autoreleasepool {
                    guard let ref = page.pageRef, let img = ImageLoader.render(ref) else { return nil }
                    return try? ImageOCR.recognizeSync(img)
                }
                if let ocr, !ocr.isEmpty {
                    ocrPages += 1
                    for p in ocr.paragraphs {
                        let (prefix, body) = splitListMarker(p.text)
                        paragraphs.append(DocParagraph(text: body, prefix: prefix, translatable: hasWords(body), page: i + 1))
                    }
                    continue
                }
            } else {
                progress?(i + 1, count, false)
            }
            paragraphs += autoreleasepool { pdfPageParagraphs(page, number: i + 1) }
        }
        return ExtractedDocument(url: url, name: name, kind: .pdf, paragraphs: paragraphs, pageCount: count, ocrPages: ocrPages)
    }

    /// Text-layer lines of a page -> the same layout analysis as OCR (blocks, columns, paragraphs).
    static func pdfPageParagraphs(_ page: PDFPage, number: Int) -> [DocParagraph] {
        let box = page.bounds(for: .mediaBox)
        let lines: [LayoutLine] = (page.selection(for: box)?.selectionsByLine() ?? []).compactMap { sel in
            let t = (sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { return nil }
            return LayoutLine(text: t, rect: CGRect(x: b.minX - box.minX, y: box.maxY - b.maxY, width: b.width, height: b.height))
        }
        guard !lines.isEmpty else {
            return plainParagraphs(page.string ?? "").map { var p = $0; p.page = number; return p }
        }
        let heights = lines.map(\.rect.height).sorted()
        let median = heights[heights.count / 2]
        var lineHeight: [String: CGFloat] = [:]
        for l in lines { lineHeight[l.text] = max(lineHeight[l.text] ?? 0, l.rect.height) }
        return TextLayout.paragraphs(from: lines).map { op in
            let (prefix, body) = splitListMarker(op.text)
            var p = DocParagraph(text: body, prefix: prefix, translatable: hasWords(body), page: number)
            // A one-line paragraph in a bigger font is a heading.
            if prefix.isEmpty, let h = lineHeight[op.text], body.count <= 160 {
                if h >= median * 1.6 { p.style.headingLevel = 1; p.style.bold = true }
                else if h >= median * 1.25 { p.style.headingLevel = 2; p.style.bold = true }
            }
            return p
        }
    }

    // MARK: - Helpers

    /// "• text" -> ("• ", "text"); "1. text" -> ("1. ", "text"). Rich-text list markers ("\t•\t") are kept too.
    static func splitListMarker(_ text: String, markdown: Bool = false) -> (String, String) {
        let pattern = markdown
            ? "^([-*+]|\\d{1,3}[.)]|>)[ \t]+"
            : "^[\t ]*([•●▪◦·‣–—\\-*✓✔]|\\d{1,3}[.)]|[a-zа-я][)])[\t ]+"
        if let r = text.range(of: pattern, options: .regularExpression), r.upperBound < text.endIndex {
            return (String(text[r]), String(text[r.upperBound...]))
        }
        return ("", text)
    }

    static func hasWords(_ s: String) -> Bool {
        var n = 0
        for c in s where c.isLetter { n += 1; if n >= 2 { return true } }
        return false
    }
}
