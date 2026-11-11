// Finds the caret on screen when the app does not report it (Chrome <textarea>, plain contenteditable):
// a snapshot of the field is recognized (Vision) and the line that ends with the last typed characters is
// taken — its right edge is where the caret is. Suggestions are only shown at the end of the text, so the
// typed tail is always the last thing in its line.
import AppKit
import Vision
import TolkCore

enum CaretLocator {
    struct Line { let text: String; let rect: CGRect }   // rect: image pixels, top-left origin

    /// `field`: the field's frame in Cocoa screen coordinates. Returns the caret rectangle (Cocoa), or nil when
    /// the typed tail was not found (then the caller keeps the corner of the field).
    static func locate(field: NSRect, textBefore: String) async -> NSRect? {
        guard field.width > 40, field.height > 12,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(field) }) else { return nil }
        let clipped = field.intersection(screen.frame)
        guard clipped.width > 40, clipped.height > 12,
              let image = try? await ScreenCaptureController.snapshot(clipped, on: screen) else { return nil }
        let lines: [Line] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: (try? recognize(image)) ?? []) }
        }
        guard let hit = match(lines: lines, textBefore: textBefore) else { return nil }
        let sx = clipped.width / CGFloat(image.width), sy = clipped.height / CGFloat(image.height)
        let h = max(12, min(40, hit.rect.height * sy * 1.15))
        // A typed trailing space is not part of the recognized line: step over it.
        let space = (textBefore.last == " " || textBefore.last == "\u{00A0}") ? h * 0.28 : 0
        let x = clipped.minX + hit.rect.maxX * sx + space + 1
        let midY = clipped.maxY - hit.rect.midY * sy
        return NSRect(x: x, y: midY - h / 2, width: 1, height: h)
    }

    /// The lowest line whose end matches the end of the typed text (letters and digits only, case-insensitive;
    /// one recognition slip is tolerated for longer tails).
    static func match(lines: [Line], textBefore: String) -> Line? {
        let typed = norm(textBefore)
        guard typed.count >= 3 else { return nil }
        for k in [14, 10, 7, 5, 3] where typed.count >= k {
            let tail = Array(typed.suffix(k))
            let hits = lines.filter { l in
                let n = Array(norm(l.text).suffix(k))
                guard n.count == k else { return false }
                let diff = zip(n, tail).filter { $0 != $1 }.count
                return diff == 0 || (k >= 7 && diff <= 1)
            }
            if let best = hits.max(by: { $0.rect.maxY < $1.rect.maxY }) { return best }
        }
        return nil
    }

    static func norm(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 == "ё" ? "е" : $0 })
    }

    private static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // the exact characters matter here, not nice words
        request.revision = VNRecognizeTextRequestRevision3
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        let langs = ImageOCR.preferredLanguages.prefix(3).filter { supported.contains($0) }
        if !langs.isEmpty { request.recognitionLanguages = Array(langs) }
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return Line(text: ImageOCR.fixHomoglyphs(cand.string),
                        rect: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
    }
}
