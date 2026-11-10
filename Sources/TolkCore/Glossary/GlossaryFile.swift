// `rules.md` on disk: load, atomic save with a one-time backup, merge with changes made
// elsewhere (popup "В глоссарий" -> RulesStore.addTerm, VS Code), and a file watcher.
import Foundation

public final class GlossaryFile: @unchecked Sendable {
    public let path: String
    public var backupPath: String { path + ".bak" }

    /// Text last read from / written to disk; the base for detecting external changes.
    private var baseText: String = ""
    private let lock = NSLock()

    public init(path: String) { self.path = expandPath(path) }

    /// Reads the file (missing file = empty document with standard sections).
    public func load() -> GlossaryDocument {
        let text = readDisk()
        lock.lock(); baseText = text; lock.unlock()
        return text.isEmpty ? GlossaryDocument() : GlossaryDocument(markdown: text)
    }

    /// True if the file on disk differs from what we last loaded or wrote.
    public func changedOnDisk() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readDisk() != baseText
    }

    public struct SaveResult {
        /// The document as written (may include entries merged in from an external change).
        public var document: GlossaryDocument
        /// Entries that appeared on disk in the meantime and were merged in.
        public var mergedFromDisk: Int
    }

    /// Writes `doc`. If the file changed on disk since the last load/save, terms added there
    /// (and the style, if we did not touch it) are merged in first, so nothing from the popup is lost.
    @discardableResult
    public func save(_ doc: GlossaryDocument) throws -> SaveResult {
        lock.lock(); defer { lock.unlock() }
        var doc = doc
        var merged = 0
        let disk = readDisk()
        if disk != baseText {
            let base = GlossaryDocument(markdown: baseText)
            let theirs = GlossaryDocument(markdown: disk)
            let baseKeys = Set(base.entries.map(Self.key))
            let ours = Set(doc.entries.map(Self.key))
            let added = theirs.entries.filter { !baseKeys.contains(Self.key($0)) && !ours.contains(Self.key($0)) }
            doc.entries += added.map { GlossaryEntry(term: $0.term, translation: $0.translation, comment: $0.comment) }
            merged = added.count
            if doc.style.glTrimmed == base.style.glTrimmed, theirs.style.glTrimmed != base.style.glTrimmed {
                doc.style = theirs.style
            }
        }
        let out = doc.markdown()
        guard out != disk else {
            baseText = disk
            return SaveResult(document: doc, mergedFromDisk: merged)
        }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: path), !fm.fileExists(atPath: backupPath) {
            try fm.copyItem(atPath: path, toPath: backupPath)
        }
        try out.write(to: url, atomically: true, encoding: .utf8) // temp file + rename
        baseText = out
        // Ids are kept so the UI can keep its selection; layout of `doc` stays valid for the next save.
        return SaveResult(document: doc, mergedFromDisk: merged)
    }

    private static func key(_ e: GlossaryEntry) -> String {
        e.termKey + "\u{1}" + e.translation.glTrimmed.lowercased()
    }

    private func readDisk() -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
}

/// Watches one file, surviving atomic saves (rename over the old inode) by also watching its folder.
/// `onChange` fires on the main queue, debounced.
public final class GlossaryFileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "tolk.glossary.watch")
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(path: String, onChange: @escaping () -> Void) {
        self.path = expandPath(path)
        self.onChange = onChange
        queue.async { self.startDir(); self.startFile() }
    }

    deinit { dirSource?.cancel(); fileSource?.cancel() }

    public func stop() { queue.async { self.dirSource?.cancel(); self.fileSource?.cancel(); self.dirSource = nil; self.fileSource = nil } }

    private func startDir() {
        let dir = (path as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        s.setEventHandler { [weak self] in self?.startFile(); self?.fire() }
        s.setCancelHandler { close(fd) }
        s.resume()
        dirSource = s
    }

    private func startFile() {
        fileSource?.cancel(); fileSource = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            if !s.data.intersection([.delete, .rename]).isEmpty { self.startFile() }
            self.fire()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        fileSource = s
    }

    private func fire() {
        pending?.cancel()
        let w = DispatchWorkItem { [onChange] in DispatchQueue.main.async(execute: onChange) }
        pending = w
        queue.asyncAfter(deadline: .now() + 0.25, execute: w)
    }
}
