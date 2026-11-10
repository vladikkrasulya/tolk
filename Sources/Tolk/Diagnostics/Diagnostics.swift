// Crash reports and a small app log, so a crash can be sent to the developer in one click.
//
//   ~/Library/Logs/Tolk/tolk.log        — app events (rotated at 512 KB)
//   ~/Library/Logs/Tolk/stderr.log      — this run's stderr: Swift "Fatal error: …" messages land here
//   ~/Library/Logs/Tolk/crash-*.txt     — written by the signal handler (signal + backtrace)
//
// On the next launch, if the previous run crashed, `Diagnostics.offerReportIfCrashed()` shows an alert
// with «Скопировать отчёт».
import AppKit
import Darwin

enum Diagnostics {
    static let dir: URL = {
        var d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tolk", isDirectory: true)
        #if DEBUG
        // The smoke run must never write into the user's real log directory.
        if ProcessInfo.processInfo.environment["TOLK_SMOKE"] != nil {
            d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tolk-smoke-logs", isDirectory: true)
        }
        #endif
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var logURL: URL { dir.appendingPathComponent("tolk.log") }
    static var stderrURL: URL { dir.appendingPathComponent("stderr.log") }
    static var previousStderrURL: URL { dir.appendingPathComponent("stderr.prev.log") }
    /// Exists while the app runs; removed on normal quit. Left behind = the previous run did not quit normally.
    static var runningMarker: URL { dir.appendingPathComponent(".running") }

    static var version: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = i?["CFBundleVersion"] as? String ?? "-"
        let c = i?["TolkGitCommit"] as? String ?? "local"
        return "\(v) (сборка \(b), \(c))"
    }

    // MARK: - Install

    private static var crashFD: Int32 = -1

    static func install() {
        let fm = FileManager.default
        // Crashed = the previous run left its marker AND a crash file was written after that run started
        // (a plain kill or a power cut leaves the marker but no crash record — not worth an alert).
        var crashedLastTime = false
        if let markerDate = (try? fm.attributesOfItem(atPath: runningMarker.path))?[.creationDate] as? Date,
           let crash = latestCrashFile(),
           let crashDate = (try? crash.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           crashDate >= markerDate {
            crashedLastTime = true
        }
        UserDefaults.standard.set(crashedLastTime, forKey: "tolk.diag.previousRunCrashed")
        try? fm.removeItem(at: runningMarker)

        // Keep the previous run's stderr (it holds the Swift fatal error message), then capture this run's.
        try? fm.removeItem(at: previousStderrURL)
        try? fm.moveItem(at: stderrURL, to: previousStderrURL)
        if isatty(STDERR_FILENO) == 0 {
            freopen(stderrURL.path, "w", stderr)
            setvbuf(stderr, nil, _IONBF, 0)
        }

        fm.createFile(atPath: runningMarker.path, contents: Data())

        // Pre-open the crash file: only async-signal-safe calls are allowed inside the handler.
        let crashPath = dir.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970)).txt").path
        crashFD = open(crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        let header = "Tolk \(version) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nStarted: \(Date())\n"
        _ = header.withCString { write(crashFD, $0, strlen($0)) }

        for sig in [SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, crashSignalHandler)
        }
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.log("UNCAUGHT EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n" +
                            exception.callStackSymbols.joined(separator: "\n"))
        }
        log("launch \(version), args: \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        cleanupOldCrashFiles(keeping: crashPath)
    }

    /// Normal quit: the run did not crash.
    static func markCleanExit() {
        log("quit")
        try? FileManager.default.removeItem(at: runningMarker)
        if crashFD >= 0 {
            close(crashFD); crashFD = -1
            // An empty crash file (only the header) is not a crash — remove it.
            cleanupOldCrashFiles(keeping: nil, removeHeaderOnly: true)
        }
    }

    fileprivate static func writeCrash(signal sig: Int32) {
        guard crashFD >= 0 else { return }
        var msg = "\n*** CRASH: signal \(sig) "
        switch sig {
        case SIGTRAP: msg += "(SIGTRAP — Swift runtime error, see stderr above/below)"
        case SIGABRT: msg += "(SIGABRT)"
        case SIGSEGV: msg += "(SIGSEGV)"
        case SIGBUS: msg += "(SIGBUS)"
        default: break
        }
        msg += "\n"
        _ = msg.withCString { write(crashFD, $0, strlen($0)) }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = backtrace(&frames, 64)
        backtrace_symbols_fd(&frames, n, crashFD)
        fsync(crashFD)
    }

    // MARK: - Log

    private static let queue = DispatchQueue(label: "tolk.log")

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 512_000 {
                let old = dir.appendingPathComponent("tolk.old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: logURL, to: old)
            }
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
    }

    // MARK: - Report

    /// Everything the developer needs, as plain text for the chat.
    static func report(includeCrash: Bool) -> String {
        var parts = ["=== Tolk \(version) — отчёт ===",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Host.current().localizedName ?? "")",
                     "Время: \(Date())"]
        if includeCrash, let crash = latestCrashFile(), let text = try? String(contentsOf: crash, encoding: .utf8),
           text.contains("*** CRASH") {
            parts += ["", "--- crash (\(crash.lastPathComponent)) ---", text]
        }
        if let err = try? String(contentsOf: includeCrash ? previousStderrURL : stderrURL, encoding: .utf8),
           !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts += ["", "--- stderr ---", String(err.suffix(6000))]
        }
        if let log = try? String(contentsOf: logURL, encoding: .utf8) {
            parts += ["", "--- последние события ---", log.split(separator: "\n").suffix(60).joined(separator: "\n")]
        }
        return parts.joined(separator: "\n")
    }

    /// Shows «Tolk неожиданно закрылся…» once after a crash.
    @MainActor
    static func offerReportIfCrashed() {
        guard UserDefaults.standard.bool(forKey: "tolk.diag.previousRunCrashed") else { return }
        UserDefaults.standard.set(false, forKey: "tolk.diag.previousRunCrashed")
        let text = report(includeCrash: true)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Tolk неожиданно закрылся в прошлый раз"
        alert.informativeText = "Скопируйте отчёт и отправьте его разработчику — по нему можно найти и исправить ошибку. В отчёте нет переводимых текстов, только техническая информация."
        alert.addButton(withTitle: "Скопировать отчёт")
        alert.addButton(withTitle: "Показать файлы")
        alert.addButton(withTitle: "Закрыть")
        switch alert.runModal() {
        case .alertFirstButtonReturn: copy(text)
        case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([latestCrashFile() ?? logURL])
        default: break
        }
    }

    /// Menu «Сообщить о проблеме…»: copies the current log and state.
    @MainActor
    static func copyProblemReport() {
        copy(report(includeCrash: false))
        let alert = NSAlert()
        alert.messageText = "Отчёт скопирован"
        alert.informativeText = "Вставьте его в сообщение разработчику (⌘V) и опишите, что произошло."
        alert.addButton(withTitle: "Ок")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func latestCrashFile() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("crash-") }
            .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("*** CRASH") == true }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    private static func cleanupOldCrashFiles(keeping current: String?, removeHeaderOnly: Bool = false) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let crashes = files.filter { $0.lastPathComponent.hasPrefix("crash-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for (i, f) in crashes.enumerated() {
            let isCurrent = f.path == current
            let headerOnly = (try? String(contentsOf: f, encoding: .utf8))?.contains("*** CRASH") != true
            if (removeHeaderOnly && headerOnly) || (!isCurrent && headerOnly) || i >= 10 {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}

/// C signal handler: write the crash, then re-raise with the default action so macOS also records it.
private func crashSignalHandler(_ sig: Int32) {
    Diagnostics.writeCrash(signal: sig)
    signal(sig, SIG_DFL)
    raise(sig)
}
