// Owned by the "image" session. Loads images/PDF pages from files, the pasteboard and drags.
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One page to recognize (a photo, a screenshot or a PDF page). The image is upright (EXIF applied).
struct ImagePage {
    var image: CGImage
    var name: String
}

enum ImageLoaderError: LocalizedError {
    case unsupported(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(name): "Формат файла «\(name)» не поддерживается. Подойдут HEIC, JPEG, PNG, TIFF, WebP и PDF."
        case let .unreadable(name): "Не удалось открыть «\(name)»."
        }
    }
}

enum ImageLoader {
    /// Longest side for OCR. iPhone 48 MP photos are downscaled; book text stays readable.
    static let maxPixelSize = 4096
    /// PDF pages rendered per document (protects against 500-page books).
    static let maxPDFPages = 40
    /// Long side of a rendered PDF page in pixels.
    static let pdfPixels: CGFloat = 2400

    static let supportedTypes: [UTType] = [.image, .pdf]

    static func canOpen(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    /// Pages from one file: a single upright image, or every page of a PDF (up to `maxPDFPages`).
    static func pages(from url: URL) throws -> [ImagePage] {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            guard let doc = CGPDFDocument(url as CFURL) else { throw ImageLoaderError.unreadable(name) }
            let count = min(doc.numberOfPages, maxPDFPages)
            var result: [ImagePage] = []
            for i in 0..<count {
                guard let page = doc.page(at: i + 1), let img = render(page) else { continue }
                result.append(ImagePage(image: img, name: count > 1 ? "\(name), стр. \(i + 1)" : name))
            }
            if result.isEmpty { throw ImageLoaderError.unreadable(name) }
            return result
        }
        guard type == nil || type!.conforms(to: .image) else { throw ImageLoaderError.unsupported(name) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = upright(src) else {
            throw ImageLoaderError.unreadable(name)
        }
        return [ImagePage(image: img, name: name)]
    }

    static func image(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return upright(src)
    }

    static func image(from nsImage: NSImage) -> CGImage? {
        if let tiff = nsImage.tiffRepresentation, let img = image(from: tiff) { return img }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Image files or raw image data on a pasteboard (Finder, Preview, screenshots via ⌘⌃⇧4, browsers).
    static func pages(from pasteboard: NSPasteboard) -> (pages: [ImagePage], errors: [String]) {
        var pages: [ImagePage] = []
        var errors: [String] = []
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        for url in urls {
            do { pages += try Self.pages(from: url) }
            catch { errors.append(error.localizedDescription) }
        }
        if !pages.isEmpty || !errors.isEmpty { return (pages, errors) }

        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                     NSPasteboard.PasteboardType("public.heic"), .pdf] {
            guard let data = pasteboard.data(forType: type) else { continue }
            if type == .pdf, let provider = CGDataProvider(data: data as CFData),
               let doc = CGPDFDocument(provider), let page = doc.page(at: 1), let img = render(page) {
                return ([ImagePage(image: img, name: "Из буфера обмена")], [])
            }
            if let img = image(from: data) { return ([ImagePage(image: img, name: "Из буфера обмена")], []) }
        }
        if let ns = NSImage(pasteboard: pasteboard), let img = image(from: ns) {
            return ([ImagePage(image: img, name: "Из буфера обмена")], [])
        }
        return ([], [])
    }

    static func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: canOpen) { return true }
        return NSImage.canInit(with: pasteboard)
    }

    // MARK: - Private

    private static func upright(_ src: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? maxPixelSize
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? maxPixelSize
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // apply EXIF orientation (iPhone photos)
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Renders a PDF page upright on white, ~2400 px on the long side (enough for small print).
    static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(6, max(1.5, pdfPixels / max(size.width, size.height)))
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }
}
