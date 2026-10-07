import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys through Carbon's RegisterEventHotKey, which (unlike
/// watching all key presses) needs no Accessibility permission.
final class Hotkeys {
    static let shared = Hotkeys()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    /// Registers a hotkey written like "cmd+shift+v". Returns false when the
    /// text can't be read or another app already owns that combination.
    @discardableResult
    func register(_ spec: String, handler: @escaping () -> Void) -> Bool {
        guard let (key, modifiers) = Hotkeys.parse(spec) else { return false }
        installHandlerOnce()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x434C5053 /* CLPS */, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { Hotkeys.shared.handlers[id.id]?() }
            return noErr
        }, 1, &type, nil, nil)
    }

    /// "cmd+shift+v" → (key code, Carbon modifier flags).
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            default: key = keyCodes[part]
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return (key, modifiers)
    }

    /// How a hotkey is shown in menus and messages, e.g. "⌃⌘V".
    static func symbols(_ spec: String) -> String {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        var s = ""
        if parts.contains(where: { ["ctrl", "control"].contains($0) }) { s += "⌃" }
        if parts.contains(where: { ["opt", "option", "alt"].contains($0) }) { s += "⌥" }
        if parts.contains("shift") { s += "⇧" }
        if parts.contains(where: { ["cmd", "command"].contains($0) }) { s += "⌘" }
        return s + (parts.last ?? "").uppercased()
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "escape": UInt32(kVK_Escape),
    ]
}
