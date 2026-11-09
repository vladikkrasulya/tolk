// Owned by the "documents" helper. Writes the translation as Word / RTF / TXT / Markdown.
import AppKit
import UniformTypeIdentifiers

enum DocumentExportFormat: Int, CaseIterable {
    case docx, rtf, txt, markdown

    var title: String {
        switch self {
        case .docx: "Word (.docx)"
        case .rtf: "RTF (.rtf)"
        case .txt: "Текст (.txt)"
        case .markdown: "Markdown (.md)"
        }
    }

    var fileExtension: String {
        switch self { case .docx: "docx"; case .rtf: "rtf"; case .txt: "txt"; case .markdown: "md" }
    }

    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .data }
}

enum DocumentExporter {
    /// Paragraphs that go into the file: (source paragraph, translation). Only translated ones.
    typealias Pair = (paragraph: DocParagraph, translation: String)

    static func data(_ pairs: [Pair], format: DocumentExportFormat, bilingual: Bool, keepSourceStyle: Bool) throws -> Data {
        switch format {
        case .txt:
            return Data(plainText(pairs, bilingual: bilingual).utf8)
        case .markdown:
            return Data(markdown(pairs, bilingual: bilingual).utf8)
        case .docx, .rtf:
            let attr = attributed(pairs, bilingual: bilingual, keepSourceStyle: keepSourceStyle)
            let type: NSAttributedString.DocumentType = format == .docx ? .officeOpenXML : .rtf
            return try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: type])
        }
    }

    // MARK: - Plain / Markdown

    static func plainText(_ pairs: [Pair], bilingual: Bool) -> String {
        pairs.map { pair in
            let prefix = pair.paragraph.richPrefix
            let t = prefix + pair.translation
            return bilingual && pair.paragraph.translatable && pair.paragraph.text != pair.translation
                ? prefix + pair.paragraph.text + "\n" + t : t
        }.joined(separator: "\n\n") + "\n"
    }

    static func markdown(_ pairs: [Pair], bilingual: Bool) -> String {
        let blocks: [String] = pairs.map { pair in
            let p = pair.paragraph
            let prefix: String
            if p.prefix.isEmpty, p.style.headingLevel > 0 { prefix = String(repeating: "#", count: p.style.headingLevel) + " " }
            else { prefix = p.markdownPrefix }
            let t = prefix + pair.translation
            guard bilingual else { return t }
            // Code / untranslatable blocks are not repeated.
            if !p.translatable || p.text == pair.translation { return t }
            if p.style.headingLevel > 0 || p.prefix.hasPrefix("#") { return prefix + p.text + "\n\n" + t }
            return "> " + p.text.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" + t
        }
        // Consecutive list items stay one tight list (single line break).
        var out = ""
        for (i, block) in blocks.enumerated() {
            if i > 0 {
                let tight = !bilingual && isListItem(pairs[i - 1].paragraph) && isListItem(pairs[i].paragraph)
                out += tight ? "\n" : "\n\n"
            }
            out += block
        }
        return out + "\n"
    }

    private static func isListItem(_ p: DocParagraph) -> Bool {
        let m = p.markdownPrefix
        return !m.isEmpty && !m.hasPrefix("#") && !m.hasPrefix(">")
    }

    // MARK: - Rich text

    static let bodySize: CGFloat = 12
    static let headingSizes: [CGFloat] = [20, 16, 13.5]

    static func attributed(_ pairs: [Pair], bilingual: Bool, keepSourceStyle: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (n, pair) in pairs.enumerated() {
            let p = pair.paragraph
            let last = n == pairs.count - 1
            let showOriginal = bilingual && p.translatable && p.text != pair.translation
            if showOriginal {
                out.append(paragraph(p.richPrefix + p.text, style: p.style, keepSourceStyle: keepSourceStyle, original: true, spacingAfter: 3))
            }
            let spacing: CGFloat = bilingual ? 12 : (p.style.headingLevel > 0 ? 6 : 8)
            out.append(paragraph(p.richPrefix + pair.translation, style: p.style, keepSourceStyle: keepSourceStyle,
                                 original: false, spacingAfter: spacing, terminate: !last))
        }
        return out
    }

    private static func paragraph(_ text: String, style: ParagraphStyle, keepSourceStyle: Bool, original: Bool,
                                  spacingAfter: CGFloat, terminate: Bool = true) -> NSAttributedString {
        let font = self.font(for: style, keepSourceStyle: keepSourceStyle, original: original)
        let ps = NSMutableParagraphStyle()
        ps.alignment = NSTextAlignment(rawValue: style.alignment) ?? .natural
        ps.paragraphSpacing = spacingAfter
        ps.paragraphSpacingBefore = style.headingLevel > 0 && !original ? 6 : 0
        ps.lineHeightMultiple = 1.1
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: ps]
        attrs[.foregroundColor] = original ? NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1) : NSColor.black
        // Line breaks inside a paragraph stay line breaks (not new paragraphs).
        let body = text.replacingOccurrences(of: "\n", with: "\u{2028}")
        return NSAttributedString(string: body + (terminate ? "\n" : ""), attributes: attrs)
    }

    static func font(for style: ParagraphStyle, keepSourceStyle: Bool, original: Bool) -> NSFont {
        var size = bodySize
        var bold = style.bold
        if keepSourceStyle, let s = style.fontSize, s >= 6, s <= 72 { size = s }
        else if style.headingLevel > 0 { size = headingSizes[min(2, style.headingLevel - 1)]; bold = true }
        if original { size = max(8, size - 1) }
        var family = "Helvetica Neue"
        if keepSourceStyle, let f = style.fontFamily, !f.hasPrefix("."), NSFont(name: f, size: size) != nil
            || NSFontManager.shared.availableMembers(ofFontFamily: f) != nil {
            family = f
        }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if style.italic || original { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size)
            ?? NSFontManager.shared.font(withFamily: "Helvetica Neue", traits: traits, weight: 5, size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}
