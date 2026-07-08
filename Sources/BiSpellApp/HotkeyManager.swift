
import AppKit
import Carbon

/// Global hotkeys:
/// - ⌥⌘.  suggestion / check
/// - ⌥⌘/  fix-all top suggestions
@MainActor
final class HotkeyManager {
    private var checkHotKeyRef: EventHotKeyRef?
    private var fixAllHotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onHotkey: (() -> Void)?
    var onFixAllHotkey: (() -> Void)?

    func register() {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            DispatchQueue.main.async {
                if hotKeyID.id == 1 {
                    manager.onHotkey?()
                } else if hotKeyID.id == 2 {
                    manager.onFixAllHotkey?()
                }
            }
            return noErr
        }, 1, &eventType, userData, &handler)

        let modifiers = UInt32(optionKey | cmdKey)
        let checkID = EventHotKeyID(signature: OSType(0x4253504C), id: 1) // BSPL
        RegisterEventHotKey(UInt32(kVK_ANSI_Period), modifiers, checkID, GetApplicationEventTarget(), 0, &checkHotKeyRef)
        // kVK_ANSI_Slash = 0x2C
        let fixID = EventHotKeyID(signature: OSType(0x4253504C), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_Slash), modifiers, fixID, GetApplicationEventTarget(), 0, &fixAllHotKeyRef)
    }

    func unregister() {
        if let checkHotKeyRef {
            UnregisterEventHotKey(checkHotKeyRef)
            self.checkHotKeyRef = nil
        }
        if let fixAllHotKeyRef {
            UnregisterEventHotKey(fixAllHotKeyRef)
            self.fixAllHotKeyRef = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }
}
