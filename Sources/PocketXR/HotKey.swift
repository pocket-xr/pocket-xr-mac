import Carbon.HIToolbox
import Foundation

/// A key combination that works from any app (Carbon's RegisterEventHotKey, which needs no permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions = [UInt32: () -> Void]()
    private static var nextID: UInt32 = 1
    /// One handler serves every hot key: it looks the pressed key's id up in [actions].
    private static var handler: EventHandlerRef?

    convenience init?(keyCode: UInt32, control: Bool = false, option: Bool = false, command: Bool = false, shift: Bool = false, action: @escaping () -> Void) {
        var mods: UInt32 = 0
        if control { mods |= UInt32(controlKey) }
        if option { mods |= UInt32(optionKey) }
        if command { mods |= UInt32(cmdKey) }
        if shift { mods |= UInt32(shiftKey) }
        self.init(keyCode: keyCode, modifiers: mods, action: action)
    }

    /// [modifiers] is Carbon's mask (controlKey, optionKey, cmdKey, shiftKey).
    init?(keyCode: UInt32, modifiers mods: UInt32, action: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        guard HotKey.installHandler() else { return nil }
        let hkID = EventHotKeyID(signature: OSType(0x5058_4B59), id: id) // "PXKY"
        guard RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        HotKey.actions[id] = action
    }

    private static func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.actions[hk.id]?()
            return noErr
        }, 1, &spec, nil, &handler)
        return installed == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }
}
