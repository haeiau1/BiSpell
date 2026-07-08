import AppKit
import Carbon

/// Global hotkey: ⌥⌘. (Option-Command-Period) opens correction popup / selection check.
@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onHotkey: (() -> Void)?

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
            if hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    manager.onHotkey?()
                }
            }
            return noErr
        }, 1, &eventType, userData, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4253504C), id: 1) // 'BSPL'
        // kVK_ANSI_Period = 0x2F, option+command
        let modifiers = UInt32(optionKey | cmdKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_Period), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    deinit {
        // Cannot call MainActor in deinit safely; best-effort
    }
}
