import Carbon.HIToolbox
import AppKit

/// Carbon 全局快捷键（RegisterEventHotKey）。
/// 沙盒应用可用，无需「辅助功能」权限；支持注册多个快捷键。
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private init() {}

    private var hotKeys: [UInt32: (ref: EventHotKeyRef, handler: () -> Void)] = [:]
    private var installed = false
    private var nextID: UInt32 = 1

    @discardableResult
    func register(keyCode: UInt32, carbonModifiers: UInt32, handler: @escaping () -> Void) -> UInt32? {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D53_484B) /* 'MSHK' */, id: id)
        let status = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let hotKeyRef = ref else { return nil }
        hotKeys[id] = (hotKeyRef, handler)
        return id
    }

    func unregister(id: UInt32) {
        if let entry = hotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(entry.ref)
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            if let entry = center.hotKeys[hotKeyID.id] {
                let handler = entry.handler
                DispatchQueue.main.async { handler() }
            }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, userData, nil)
        installed = (status == noErr)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var mods = ""
        if carbonModifiers & UInt32(controlKey) != 0 { mods += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { mods += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { mods += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { mods += "⌘" }
        let keyName = KeyEventUtil.string(forKeyCode: Int(keyCode))?.uppercased() ?? "?"
        return mods + keyName
    }
}

/// 常用键位名称映射（展示用）
enum KeyEventUtil {
    static let names: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "↩", 49: "␣", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func string(forKeyCode code: Int) -> String? {
        names[code]
    }
}
