// Checks for AutocompleteServerLogic.swift and the autocomplete power fields of TolkConfig.
import Foundation

extension SelfTest {
    static func autocompleteServer(_ check: Check) {
        // Old config without the new keys: defaults, nothing else changes.
        let old = #"{"autocomplete": true, "autocompleteFrequency": "often"}"#
        let c = (try? JSONDecoder().decode(TolkConfig.self, from: Data(old.utf8))) ?? TolkConfig()
        check(c.autocomplete && c.autocompleteFrequency == "often", "ac config: old keys kept")
        check(!c.autocompleteBatteryRare && !c.autocompleteBatteryNoScreen && !c.autocompleteBatteryShort, "ac config: battery switches off by default")
        check(c.autocompleteScreenContext, "ac config: screen context on by default (as before)")
        var n = TolkConfig(); n.autocompleteBatteryShort = true; n.autocompleteScreenContext = false
        let back = (try? JSONDecoder().decode(TolkConfig.self, from: JSONEncoder().encode(n))) ?? TolkConfig()
        check(back.autocompleteBatteryShort && !back.autocompleteScreenContext, "ac config: new fields round-trip")

        // Power profile.
        func prof(_ f: String, _ l: String, _ s: Bool, bat: Bool, r: Bool, ns: Bool, sh: Bool) -> PowerProfile {
            PowerProfile.effective(frequency: f, length: l, screenContext: s, onBattery: bat, batteryRare: r, batteryNoScreen: ns, batteryShort: sh)
        }
        check(prof("often", "long", true, bat: false, r: true, ns: true, sh: true) == PowerProfile(frequency: "often", length: "long", screenContext: true), "power: on AC nothing changes")
        check(prof("often", "long", true, bat: true, r: false, ns: false, sh: false) == PowerProfile(frequency: "often", length: "long", screenContext: true), "power: battery, all switches off → no change")
        check(prof("often", "long", true, bat: true, r: true, ns: true, sh: true) == PowerProfile(frequency: "rare", length: "short", screenContext: false), "power: battery, all on")
        check(prof("normal", "medium", true, bat: true, r: true, ns: false, sh: false).frequency == "rare", "power: rare only")
        check(prof("normal", "medium", true, bat: true, r: false, ns: true, sh: false) == PowerProfile(frequency: "normal", length: "medium", screenContext: false), "power: no screen only")
        check(prof("rare", "short", false, bat: true, r: true, ns: true, sh: true) == PowerProfile(frequency: "rare", length: "short", screenContext: false), "power: already minimal")

        // Whose server is on the port.
        let rec = ServerRecord(pid: 500, port: 8178, model: "m.gguf")
        check(ServerLifecycle.decide(listenerPid: nil, listenerIsLlama: false, record: rec, port: 8178) == .startOwn, "port: free → start own")
        check(ServerLifecycle.decide(listenerPid: 500, listenerIsLlama: true, record: rec, port: 8178) == .killOrphanThenStart(500), "port: ours (pid file matches) → orphan")
        check(ServerLifecycle.decide(listenerPid: 500, listenerIsLlama: true, record: nil, port: 8178) == .portBusy, "port: llama-server without pid file → foreign")
        check(ServerLifecycle.decide(listenerPid: 777, listenerIsLlama: true, record: rec, port: 8178) == .portBusy, "port: other pid than recorded → foreign")
        check(ServerLifecycle.decide(listenerPid: 500, listenerIsLlama: false, record: rec, port: 8178) == .portBusy, "port: pid reused by a non-llama process → foreign")
        check(ServerLifecycle.decide(listenerPid: 500, listenerIsLlama: true, record: rec, port: 8195) == .portBusy, "port: record for another port → foreign")

        // Two Tolk instances: a live other owner is never an orphan; a dead or unknown owner is.
        let alive: (Int32) -> Bool = { $0 == 900 }
        let owned = ServerRecord(pid: 500, port: 8178, model: "m.gguf", owner: 900)
        check(ServerLifecycle.decide(listenerPid: 500, listenerIsLlama: true, record: owned, port: 8178, myPid: 1, isAlive: alive) == .ownedByOtherTolk(900), "port: live other Tolk owns it → hands off")
        check(ServerLifecycle.decide(listenerPid: 500, listenerIsLlama: true, record: owned, port: 8178, myPid: 900, isAlive: alive) == .killOrphanThenStart(500), "port: owner is me → mine")
        check(ServerLifecycle.decide(listenerPid: 500, listenerIsLlama: true, record: owned, port: 8178, myPid: 1, isAlive: { _ in false }) == .killOrphanThenStart(500), "port: owner dead → orphan")
        check(ServerLifecycle.decide(listenerPid: 500, listenerIsLlama: true, record: rec, port: 8178, myPid: 1, isAlive: alive) == .killOrphanThenStart(500), "port: old record without owner → orphan")
        let ownedPath = NSTemporaryDirectory() + "tolk-selftest-owned-\(getpid()).pid"
        ServerLifecycle.writeRecord(owned, at: ownedPath)
        ServerLifecycle.removeRecord(at: ownedPath, myPid: 1, isAlive: alive)
        check(ServerLifecycle.readRecord(at: ownedPath) == owned, "pid file: another live Tolk's record is not removed")
        ServerLifecycle.removeRecord(at: ownedPath, myPid: 900, isAlive: alive)
        check(ServerLifecycle.readRecord(at: ownedPath) == nil, "pid file: own record is removed")
        let procs = [SingleInstance.Proc(pid: 10, bundleID: "com.apple.finder", executable: "Finder"),
                     SingleInstance.Proc(pid: 20, bundleID: "local.vk.tolk", executable: "Tolk"),
                     SingleInstance.Proc(pid: 30, bundleID: nil, executable: "Tolk")]
        check(SingleInstance.otherInstance(in: procs, myPid: 99) == 20, "instances: finds the other Tolk")
        check(SingleInstance.otherInstance(in: procs, myPid: 20) == 30, "instances: debug binary without bundle id counts")
        check(SingleInstance.otherInstance(in: [procs[0], procs[1]], myPid: 20) == nil, "instances: alone → nil")

        // Restart schedule.
        check(ServerLifecycle.retryDelay(afterFailures: 0) == nil, "retry: no failures, no delay")
        check([1, 2, 3].map { ServerLifecycle.retryDelay(afterFailures: $0) } == [2, 10, 60], "retry: 2, 10, 60 s")
        check(ServerLifecycle.retryDelay(afterFailures: 4) == nil, "retry: stops after three")

        // Pid file round trip.
        let tmp = NSTemporaryDirectory() + "tolk-selftest-\(getpid()).pid"
        ServerLifecycle.writeRecord(rec, at: tmp)
        check(ServerLifecycle.readRecord(at: tmp) == rec, "pid file: round trip")
        ServerLifecycle.removeRecord(at: tmp)
        check(ServerLifecycle.readRecord(at: tmp) == nil, "pid file: removed")
    }
}
