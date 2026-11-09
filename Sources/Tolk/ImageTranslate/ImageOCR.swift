// Owned by the "image" session. Offline OCR (Vision) + layout analysis: lines -> paragraphs in reading order.
import AppKit
import Vision

/// One recognized paragraph. `rect` is in image pixels, top-left origin.
struct OCRParagraph: Sendable, Equatable {
    var text: String
    var rect: CGRect
    /// Separator to put before the next paragraph: "\n" for list items, "\n\n" otherwise.
    var separatorAfter: String = "\n\n"
}

struct OCRResult: Sendable, Equatable {
    var paragraphs: [OCRParagraph]
    var imageSize: CGSize

    var isEmpty: Bool { paragraphs.isEmpty }

    /// Plain text: paragraphs in reading order, line breaks inside a paragraph removed.
    var text: String {
        var out = ""
        for (i, p) in paragraphs.enumerated() {
            out += p.text
            if i < paragraphs.count - 1 { out += p.separatorAfter }
        }
        return out
    }

    static let empty = OCRResult(paragraphs: [], imageSize: .zero)
}

enum ImageOCR {
    /// Hints for Vision, in priority order. Unsupported codes are filtered out at runtime
    /// (Ukrainian/Russian need macOS 13+ "accurate" revision 3).
    static let preferredLanguages = [
        "ru-RU", "uk-UA", "en-US", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "pl-PL",
        "cs-CZ", "nl-NL", "ro-RO", "tr-TR", "sv-SE", "da-DK", "nb-NO", "fi-FI", "id-ID", "vi-VT",
    ]

    nonisolated(unsafe) private static var warmedUp = false

    /// The first recognition after a new build takes up to a minute (Vision prepares its model);
    /// later ones take well under a second. Call once at launch so the user never waits for that.
    static func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        DispatchQueue.global(qos: .utility).async {
            let ctx = CGContext(data: nil, width: 320, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.setFillColor(gray: 1, alpha: 1)
            ctx?.fill(CGRect(x: 0, y: 0, width: 320, height: 64))
            if let img = ctx?.makeImage() { _ = try? recognizeSync(img) }
        }
    }

    /// Recognizes text off the main thread. Works fully offline.
    static func recognize(_ image: CGImage, languages: [String]? = nil) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try recognizeSync(image, languages: languages)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    static func recognizeSync(_ image: CGImage, languages: [String]? = nil) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3
        request.automaticallyDetectsLanguage = true
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        let langs = (languages ?? preferredLanguages).filter { supported.contains($0) }
        if !langs.isEmpty { request.recognitionLanguages = langs }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let w = CGFloat(image.width), h = CGFloat(image.height)
        let lines: [LayoutLine] = (request.results ?? []).compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let text = fixHomoglyphs(cand.string.trimmingCharacters(in: .whitespacesAndNewlines))
            // Photos produce specks recognized as single characters with low confidence.
            guard !text.isEmpty, cand.confidence >= 0.3 || text.count > 2 else { return nil }
            let b = obs.boundingBox
            let rect = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            return LayoutLine(text: text, rect: rect)
        }
        return OCRResult(paragraphs: TextLayout.paragraphs(from: lines), imageSize: CGSize(width: w, height: h))
    }
}

extension ImageOCR {
    private static let latinToCyrillic: [Character: Character] = [
        "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "K": "К", "M": "М", "O": "О", "P": "Р", "T": "Т",
        "X": "Х", "a": "а", "c": "с", "e": "е", "o": "о", "p": "р", "x": "х", "y": "у",
    ]

    /// Vision sometimes reads a Cyrillic word in a mixed line as Latin look-alikes ("Море" -> "Mope").
    /// A word made only of look-alike letters right after a Cyrillic word is turned back into Cyrillic.
    static func fixHomoglyphs(_ line: String) -> String {
        var words = line.components(separatedBy: " ")
        var prevCyrillic = false
        for i in words.indices {
            let letters = words[i].filter(\.isLetter)
            guard !letters.isEmpty else { continue }
            let isCyr = letters.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
            if !isCyr, prevCyrillic, letters.allSatisfy({ latinToCyrillic[$0] != nil }) {
                words[i] = String(words[i].map { latinToCyrillic[$0] ?? $0 })
                prevCyrillic = true
            } else {
                prevCyrillic = isCyr
            }
        }
        return words.joined(separator: " ")
    }
}

// MARK: - Layout analysis

struct LayoutLine: Equatable {
    var text: String
    var rect: CGRect // top-left origin
}

/// Turns Vision's text lines into paragraphs:
/// 1. lines that sit under each other with a similar font size form a block (column fragment);
/// 2. blocks are ordered by a recursive XY-cut (rows, then columns) — handles two-column pages;
/// 3. a block is split into paragraphs by extra vertical gap, first-line indent, a short line
///    ending a sentence, or a list marker; lines inside a paragraph are joined (hyphenation undone).
enum TextLayout {
    static func paragraphs(from lines: [LayoutLine]) -> [OCRParagraph] {
        guard !lines.isEmpty else { return [] }
        let blocks = order(groupIntoBlocks(lines))
        var result: [OCRParagraph] = []
        for block in blocks {
            result.append(contentsOf: split(block))
        }
        return result
    }

    // MARK: Step 1 — blocks

    struct Block {
        var lines: [LayoutLine]
        var rect: CGRect
        var lineHeight: CGFloat { lines.map(\.rect.height).sorted()[lines.count / 2] }
    }

    static func groupIntoBlocks(_ lines: [LayoutLine]) -> [Block] {
        let sorted = lines.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        var blocks: [Block] = []
        for line in sorted {
            var best: Int?
            var bestGap = CGFloat.infinity
            for (i, block) in blocks.enumerated() {
                guard let last = block.lines.last else { continue }
                let hLine = line.rect.height, hBlock = block.lineHeight
                let hMin = min(hLine, hBlock), hMax = max(hLine, hBlock)
                guard hMax / max(hMin, 1) < 1.6 else { continue } // different font size
                let gap = line.rect.minY - last.rect.maxY
                guard gap > -0.4 * hMin, gap < 1.4 * hMax else { continue }
                let overlap = min(block.rect.maxX, line.rect.maxX) - max(block.rect.minX, line.rect.minX)
                guard overlap > 0.5 * min(line.rect.width, block.rect.width) else { continue }
                // Two lines side by side on the same row are never one block.
                if gap < 0, min(last.rect.maxX, line.rect.maxX) - max(last.rect.minX, line.rect.minX) <= 0 { continue }
                if gap < bestGap { bestGap = gap; best = i }
            }
            if let i = best {
                blocks[i].lines.append(line)
                blocks[i].rect = blocks[i].rect.union(line.rect)
            } else {
                blocks.append(Block(lines: [line], rect: line.rect))
            }
        }
        return blocks
    }

    // MARK: Step 2 — reading order (XY-cut)

    static func order(_ blocks: [Block]) -> [Block] {
        guard blocks.count > 1 else { return blocks }
        let unit = max(1, blocks.map(\.lineHeight).sorted()[blocks.count / 2])
        let rows = cut(blocks, vertical: false)
        let cols = cut(blocks, vertical: true)
        let rowGap = rows.count > 1 ? rows.gap / unit : -1
        let colGap = cols.count > 1 && cols.gap > 0.5 * unit ? cols.gap / unit : -1
        if rowGap < 0 && colGap < 0 {
            return blocks.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        }
        let groups = colGap > rowGap ? cols.groups : rows.groups
        return groups.flatMap { order($0) }
    }

    /// Splits blocks wherever there is an empty band across all of them (rows when `vertical` is false).
    private static func cut(_ blocks: [Block], vertical: Bool) -> (groups: [[Block]], gap: CGFloat, count: Int) {
        let lo: (Block) -> CGFloat = { vertical ? $0.rect.minX : $0.rect.minY }
        let hi: (Block) -> CGFloat = { vertical ? $0.rect.maxX : $0.rect.maxY }
        let sorted = blocks.sorted { lo($0) < lo($1) }
        var groups: [[Block]] = [[sorted[0]]]
        var reach = hi(sorted[0])
        var maxGap: CGFloat = 0
        for b in sorted.dropFirst() {
            let gap = lo(b) - reach
            if gap > 0 {
                maxGap = max(maxGap, gap)
                groups.append([b])
            } else {
                groups[groups.count - 1].append(b)
            }
            reach = max(reach, hi(b))
        }
        return (groups, maxGap, groups.count)
    }

    // MARK: Step 3 — paragraphs inside a block

    static func split(_ block: Block) -> [OCRParagraph] {
        let lines = block.lines
        let h = block.lineHeight
        let gaps = zip(lines, lines.dropFirst()).map { $1.rect.minY - $0.rect.maxY }
        let typicalGap = gaps.isEmpty ? 0 : gaps.sorted()[(gaps.count - 1) / 2] // lower median
        let left = lines.map(\.rect.minX).sorted()[lines.count / 2] // typical left edge
        let right = block.rect.maxX

        var paragraphs: [OCRParagraph] = []
        var current: [LayoutLine] = []
        var separator = "\n\n"

        func flush(_ sep: String) {
            guard !current.isEmpty else { return }
            let rect = current.dropFirst().reduce(current[0].rect) { $0.union($1.rect) }
            paragraphs.append(OCRParagraph(text: join(current.map(\.text)), rect: rect, separatorAfter: sep))
            current = []
        }

        for (i, line) in lines.enumerated() {
            if let prev = current.last {
                let gap = gaps[i - 1]
                let bigGap = gap > max(typicalGap * 1.7, typicalGap + 0.45 * h) || gap > 0.8 * h
                let indented = line.rect.minX > left + 0.9 * h && prev.rect.minX <= left + 0.5 * h
                let prevShort = prev.rect.maxX < right - 2.5 * h && endsSentence(prev.text)
                let listItem = startsListItem(line.text)
                if listItem && !bigGap {
                    separator = "\n"; flush(separator)
                } else if bigGap || indented || prevShort {
                    separator = "\n\n"; flush(separator)
                }
            }
            current.append(line)
        }
        flush("\n\n")
        return paragraphs
    }

    /// Joins the lines of one paragraph, undoing end-of-line hyphenation ("пере-" + "вод").
    static func join(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            guard !out.isEmpty else { out = line; continue }
            if let last = out.last, "-‐¬\u{00AD}".contains(last),
               out.dropLast().last?.isLetter == true,
               line.first?.isLowercase == true {
                out.removeLast()
                out += line
            } else {
                out += " " + line
            }
        }
        return out
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let c = s.last else { return false }
        return ".!?:;…»\"”)".contains(c)
    }

    static func startsListItem(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        if "•●▪◦·–—-*✓✔".contains(first), s.dropFirst().first == " " { return true }
        // "1." / "2)" / "a)"
        let head = s.prefix(4)
        if let idx = head.firstIndex(where: { $0 == "." || $0 == ")" }), idx > head.startIndex {
            let marker = head[head.startIndex..<idx]
            let next = s[s.index(after: idx)...].first
            if next == " ", marker.allSatisfy(\.isNumber) || (marker.count == 1 && marker.first!.isLetter && head[idx] == ")") {
                return true
            }
        }
        return false
    }
}
