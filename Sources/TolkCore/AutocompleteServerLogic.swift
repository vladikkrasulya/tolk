// Pure logic of the autocomplete model server: who owns the port, the restart schedule, the power-saving profile,
// and how the llama-server process is launched so that it dies together with its parent.
// No AppKit — everything here is covered by `tolk-cli --self-test` (SelfTest+Autocomplete.swift).
import Foundation

/// What Tolk wrote about the server it started: pid of the llama-server process that listens on the port, and its model.
public struct ServerRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var port: Int
    public var model: String
    /// pid of the Tolk process that started the server (nil in records written by older versions).
    public var owner: Int32?
    public init(pid: Int32, port: Int, model: String, owner: Int32? = nil) {
        self.pid = pid; self.port = port; self.model = model; self.owner = owner
    }
}

public enum PortDecision: Equatable, Sendable {
    case startOwn                 // port is free
    case killOrphanThenStart(Int32) // a llama-server left by a previous Tolk: stop it, start ours
    case portBusy                 // somebody else's process: never use it, show «порт занят»
    case ownedByOtherTolk(Int32)  // a live OTHER Tolk started it: leave it alone, no kill, no retries
}

public enum ServerLifecycle {
    /// `listenerPid` — pid listening on the port (nil = nobody); `listenerIsLlama` — its executable is llama-server.
    /// The pid file is the proof that Tolk started it: pid, port and (a llama-server) must all match.
    /// `myPid` / `isAlive`: the server of a LIVE other Tolk is never an orphan (two Tolk instances used to kill each
    /// other's llama-server every 2 s); it is an orphan only when its owner is gone (or the record has no owner).
    public static func decide(listenerPid: Int32?, listenerIsLlama: Bool, record: ServerRecord?, port: Int,
                              myPid: Int32 = getpid(), isAlive: (Int32) -> Bool = processAlive) -> PortDecision {
        guard let pid = listenerPid else { return .startOwn }
        guard let r = record, r.pid == pid, r.port == port, listenerIsLlama else { return .portBusy }
        if let owner = r.owner, owner != myPid, isAlive(owner) { return .ownedByOtherTolk(owner) }
        return .killOrphanThenStart(pid)
    }

    public static func processAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Pauses before automatic restarts after the server process dies / fails to load: 2, 10, 60 s, then stop.
    public static let retryDelays: [TimeInterval] = [2, 10, 60]
    public static func retryDelay(afterFailures n: Int) -> TimeInterval? {
        n >= 1 && n <= retryDelays.count ? retryDelays[n - 1] : nil
    }

    /// `sh -c` wrapper: runs the real command and kills it when the parent (Tolk) disappears — even after `kill -9`.
    /// Why this and not kqueue/NOTE_EXIT in a helper: no extra binary to build and sign (the app is built without Xcode),
    /// `$PPID` is fixed when the shell starts, and a 2 s `kill -0` poll costs nothing measurable.
    /// The watcher subshell outlives a killed wrapper, so the child dies in every case.
    public static func wrapperArguments(command: [String]) -> [String] {
        let script = #"""
        trap 'kill $c $w 2>/dev/null; exit 143' TERM INT HUP
        "$@" & c=$!
        ( while kill -0 $PPID 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 2; done; kill $c 2>/dev/null ) & w=$!
        wait $c; code=$?
        kill $w 2>/dev/null
        exit $code
        """#
        return ["-c", script, "sh"] + command
    }

    public static var recordPath: String {
        NSString(string: "~/Library/Application Support/Tolk/llama-server.pid").expandingTildeInPath
    }

    public static func readRecord(at path: String = recordPath) -> ServerRecord? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ServerRecord.self, from: d)
    }

    public static func writeRecord(_ r: ServerRecord, at path: String = recordPath) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    /// Never deletes the record of a live OTHER Tolk (it still manages that server).
    public static func removeRecord(at path: String = recordPath, myPid: Int32 = getpid(), isAlive: (Int32) -> Bool = processAlive) {
        if let r = readRecord(at: path), let owner = r.owner, owner != myPid, isAlive(owner) { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: Process inspection (blocking, short: call off the main thread)

    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func listener(onPort port: Int) -> (pid: Int32, isLlama: Bool)? {
        let out = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        guard let pid = out.split(separator: "\n").first.flatMap({ Int32($0) }) else { return nil }
        let comm = run("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
        return (pid, (comm as NSString).lastPathComponent.hasPrefix("llama-server"))
    }

    /// SIGTERM, up to 3 s of waiting, then SIGKILL.
    public static func terminate(pid: Int32) {
        kill(pid, SIGTERM)
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
    }
}

/// A second Tolk (installed + debug build, or a double launch) must not fight the first one for the model server,
/// the event taps and the hotkeys: it finds the other instance and stops.
public enum SingleInstance {
    public struct Proc: Sendable { public var pid: Int32; public var bundleID: String?; public var executable: String?
        public init(pid: Int32, bundleID: String?, executable: String?) { self.pid = pid; self.bundleID = bundleID; self.executable = executable } }

    /// pid of another running Tolk (same bundle id, or an executable named «Tolk» — a bare debug binary has no bundle id).
    public static func otherInstance(in running: [Proc], myPid: Int32, bundleID: String = "local.vk.tolk") -> Int32? {
        running.first { $0.pid != myPid && ($0.bundleID == bundleID || $0.executable == "Tolk") }?.pid
    }
}

/// Power-saving profile: what autocomplete does on battery (each switch is off by default).
public struct PowerProfile: Equatable, Sendable {
    public var frequency: String
    public var length: String
    public var screenContext: Bool    // OCR of a screen snapshot allowed

    public static func effective(frequency: String, length: String, screenContext: Bool, onBattery: Bool,
                                 batteryRare: Bool, batteryNoScreen: Bool, batteryShort: Bool) -> PowerProfile {
        var p = PowerProfile(frequency: frequency, length: length, screenContext: screenContext)
        guard onBattery else { return p }
        if batteryRare, frequency == "often" || frequency == "normal" { p.frequency = "rare" }
        if batteryNoScreen { p.screenContext = false }
        if batteryShort { p.length = "short" }
        return p
    }
}
