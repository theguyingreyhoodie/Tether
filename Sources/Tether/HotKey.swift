import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Uses the Carbon hot-key API, which needs no permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(key: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        Self.handlers[id] = handler
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5445_5448), id: id)  // "TETH"
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("Tether: could not register hot key %d (status %d); another app may own it", id, status)
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            if status == noErr {
                DispatchQueue.main.async { HotKey.handlers[pressed.id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
