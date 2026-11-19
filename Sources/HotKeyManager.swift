import Carbon
import Cocoa
import Foundation

enum HotKeyAction {
    case switchDesktop(globalIndex: Int) // 0-based global desktop index (0 -> ⌥1, 1 -> ⌥2, ...)
    case bootMatchingProfile             // ⌥⇧B
}

private enum HotKeyDispatchBridge {
    static var handler: ((UInt32) -> Void)?
}

/// Manages runtime-only global hotkeys via Carbon `RegisterEventHotKey`.
/// Leaves zero footprint in macOS System Settings and releases all registrations on quit.
final class HotKeyManager {
    private static let signature: OSType = 0x53504254 // 'SPBT'
    private static let bootHotKeyId: UInt32 = 100

    /// Hardware key codes for digits 1..9 on US/standard ANSI/ISO macOS keyboards.
    private static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let bKeyCode: UInt32 = 11

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionHandler: ((HotKeyAction) -> Void)?
    private(set) var isRegistered = false

    func register(onAction: @escaping (HotKeyAction) -> Void) {
        unregister()
        actionHandler = onAction

        HotKeyDispatchBridge.handler = { [weak self] hotKeyId in
            guard let self = self else { return }
            if hotKeyId == Self.bootHotKeyId {
                self.actionHandler?(.bootMatchingProfile)
            } else if hotKeyId >= 1 && hotKeyId <= UInt32(Self.digitKeyCodes.count) {
                self.actionHandler?(.switchDesktop(globalIndex: Int(hotKeyId - 1)))
            }
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event = event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    HotKeyDispatchBridge.handler?(hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            SpaceBootLogger.log("HotKeyManager: InstallEventHandler failed (\(installStatus))")
            return
        }

        // Register Option + 1..9 for global desktop switching.
        for (idx, keyCode) in Self.digitKeyCodes.enumerated() {
            registerSingle(id: UInt32(idx + 1), keyCode: keyCode, modifiers: UInt32(optionKey))
        }

        // Register Option + Shift + B for quick-booting the matching profile.
        registerSingle(
            id: Self.bootHotKeyId,
            keyCode: Self.bKeyCode,
            modifiers: UInt32(optionKey | shiftKey)
        )

        isRegistered = true
        SpaceBootLogger.log("HotKeyManager: registered ⌥1–⌥9 and ⌥⇧B (runtime-only)")
    }

    func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }

        if isRegistered {
            isRegistered = false
            SpaceBootLogger.log("HotKeyManager: unregistered all runtime hotkeys")
        }
    }

    deinit {
        unregister()
    }

    // MARK: - Private Helpers

    private func registerSingle(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let validRef = ref {
            hotKeyRefs.append(validRef)
        } else {
            SpaceBootLogger.log("HotKeyManager: failed to register hotkey id=\(id) keyCode=\(keyCode) status=\(status)")
        }
    }
}
