import Foundation

extension SelfTest {
    static func hotKeyRules(_ check: Check) {
        typealias R = HotKeyRules
        let others = [HotKeyBinding(id: "translateReplace", keyCode: 17, modifiers: R.control | R.option),
                      HotKeyBinding(id: "capture", keyCode: 1, modifiers: R.option | R.shift)]
        check(R.validate(keyCode: 37, modifiers: R.control | R.option, for: "fixLayout", others: others) == nil, "hotkey: ⌃⌥L is free")
        check(R.validate(keyCode: 17, modifiers: R.control | R.option, for: "fixLayout", others: others) == .taken(by: "translateReplace"), "hotkey: ⌃⌥T is taken")
        check(R.validate(keyCode: 17, modifiers: R.control | R.option, for: "translateReplace", others: others) == nil, "hotkey: own combo is not a conflict")
        check(R.validate(keyCode: 1, modifiers: R.option | R.shift, for: "fixLayout", others: others) == .taken(by: "capture"), "hotkey: ⌥⇧S (screenshot) is taken")
        check(R.validate(keyCode: 37, modifiers: R.cmd, for: "x", others: []) == .needsControlOrOption, "hotkey: ⌘L alone is refused")
        check(R.validate(keyCode: 37, modifiers: 0, for: "x", others: []) == .needsControlOrOption, "hotkey: bare key refused")
        check(R.validate(keyCode: 37, modifiers: R.shift, for: "x", others: []) == .needsControlOrOption, "hotkey: ⇧L refused")
        check(R.validate(keyCode: 49, modifiers: R.control | R.option, for: "x", others: []) == .reserved, "hotkey: ⌃⌥Space refused")
        check(R.validate(keyCode: 37, modifiers: R.control | R.option | 0x10000, for: "x", others: []) == nil, "hotkey: stray device flags ignored")
        check(R.mask(control: true, option: true, shift: false, command: false) == R.control | R.option, "hotkey: mask")
        check(R.label(modifiers: R.control | R.option | R.shift, key: "L") == "⌃⌥⇧L", "hotkey: label order ⌃⌥⇧⌘")
    }
}
