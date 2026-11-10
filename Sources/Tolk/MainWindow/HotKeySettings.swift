import AppKit
import Carbon.HIToolbox
import SwiftUI
import TolkCore

/// Settings section «Горячие клавиши»: one recorder row per global shortcut (quick actions + «Перевод при наборе»).
struct HotKeysSection: View {
    var body: some View {
        Section {
            ForEach(HotKeyEntry.all) { HotKeyRecorderRow(entry: $0) }
            Text("Нужен ⌃ или ⌥ в сочетании. Esc во время записи — отмена, ⌫ — выключить сочетание. Снимок экрана (⌥⇧S) задан отдельно.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Горячие клавиши")
        }
    }
}

struct HotKeyEntry: Identifiable {
    let id: String
    let title: String
    let defaultCombo: HotKeyCombo?

    @MainActor static var all: [HotKeyEntry] {
        QuickAction.all.map { HotKeyEntry(id: $0.id, title: $0.title, defaultCombo: $0.defaultHotKey) }
            + [HotKeyEntry(id: QuickActionHotKeyStore.typeTranslateID, title: "Перевод при наборе (вкл/выкл)",
                           defaultCombo: TypeTranslateController.defaultHotKey)]
    }

    /// Bindings of every other shortcut (for the conflict check), the screenshot one included.
    @MainActor static func bindings() -> [HotKeyBinding] {
        let store = QuickActionHotKeyStore()
        var out = all.compactMap { e -> HotKeyBinding? in
            guard let c = store.hotKey(id: e.id, default: e.defaultCombo) else { return nil }
            return HotKeyBinding(id: e.id, keyCode: c.keyCode, modifiers: c.modifiers)
        }
        out.append(HotKeyBinding(id: "capture", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey)))
        return out
    }
}

struct HotKeyRecorderRow: View {
    let entry: HotKeyEntry
    private let store = QuickActionHotKeyStore()
    @State private var combo: HotKeyCombo?
    @State private var recording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.title)
                Spacer()
                Button(recording ? "Нажмите сочетание…" : (combo?.display ?? "Выключено")) { toggleRecording() }
                    .help("Нажмите, затем сочетание клавиш")
                    .frame(minWidth: 130)
                Button { store.reset(id: entry.id); reload() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Вернуть по умолчанию" + (entry.defaultCombo.map { " (\($0.display))" } ?? ""))
                    .disabled(combo == entry.defaultCombo)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { reload() }
        .onDisappear { stopRecording() }
    }

    private func reload() {
        combo = store.hotKey(id: entry.id, default: entry.defaultCombo)
        message = QuickActionHotKeyStore.failedIDs.contains(entry.id) && combo != nil
            ? "Это сочетание занято другой программой" : nil
    }

    private func toggleRecording() {
        if recording { stopRecording(); return }
        recording = true
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // swallow while recording
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            stopRecording(); store.set(nil, id: entry.id); reload(); return
        }
        let f = event.modifierFlags
        let mods = HotKeyRules.mask(control: f.contains(.control), option: f.contains(.option),
                                    shift: f.contains(.shift), command: f.contains(.command))
        let key = UInt32(event.keyCode)
        if let problem = HotKeyRules.validate(keyCode: key, modifiers: mods, for: entry.id, others: HotKeyEntry.bindings()) {
            switch problem {
            case .needsControlOrOption: message = "Добавьте ⌃ или ⌥ — иначе клавиша сломает набор текста"
            case .reserved: message = "Эта клавиша зарезервирована — выберите другую"
            case let .taken(by): message = "Уже занято: " + HotKeyEntry.name(for: by)
            }
            return // keep recording
        }
        stopRecording()
        store.set(HotKeyCombo(keyCode: key, modifiers: mods), id: entry.id)
        // The controllers re-register synchronously on the notification; show whether the system accepted it.
        reload()
    }
}

extension HotKeyEntry {
    @MainActor static func name(for id: String) -> String {
        if id == "capture" { return "снимок экрана" }
        return all.first { $0.id == id }?.title ?? id
    }
}
