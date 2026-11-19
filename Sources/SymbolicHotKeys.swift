import CoreGraphics
import Foundation

struct KeyShortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// Dynamically reads macOS Mission Control / Spaces shortcuts from com.apple.symbolichotkeys.plist
/// so SpaceBoot adapts to whatever shortcuts the user configured (direct Desktop 1..16 or Move Left/Right).
final class SymbolicHotKeys {
    private static let plistPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.symbolichotkeys.plist"

    private static let moveLeftKeyId = "79"
    private static let moveRightKeyId = "81"
    private static let desktop1KeyId = 118
    private static let maxDirectDesktops = 16

    private static let defaultLeftArrowKeyCode: CGKeyCode = 123
    private static let defaultRightArrowKeyCode: CGKeyCode = 124

    private let entries: [String: [String: Any]]

    init() {
        let url = URL(fileURLWithPath: Self.plistPath)
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let hotKeys = plist["AppleSymbolicHotKeys"] as? [String: [String: Any]] {
            self.entries = hotKeys
        } else {
            self.entries = [:]
        }
    }

    /// Returns the direct "Switch to Desktop N" shortcut (0-based global desktop index) if enabled by the user.
    func directDesktopShortcut(globalIndex: Int) -> KeyShortcut? {
        guard globalIndex >= 0, globalIndex < Self.maxDirectDesktops else { return nil }
        let keyId = String(Self.desktop1KeyId + globalIndex)
        return parseShortcut(forKeyId: keyId, defaultKeyCode: nil, defaultFlags: nil)
    }

    /// Returns the user's configured "Move left a space" shortcut, defaulting to Control+Left if unset.
    func moveLeftShortcut() -> KeyShortcut? {
        parseShortcut(
            forKeyId: Self.moveLeftKeyId,
            defaultKeyCode: Self.defaultLeftArrowKeyCode,
            defaultFlags: [.maskControl, .maskNumericPad, .maskSecondaryFn]
        )
    }

    /// Returns the user's configured "Move right a space" shortcut, defaulting to Control+Right if unset.
    func moveRightShortcut() -> KeyShortcut? {
        parseShortcut(
            forKeyId: Self.moveRightKeyId,
            defaultKeyCode: Self.defaultRightArrowKeyCode,
            defaultFlags: [.maskControl, .maskNumericPad, .maskSecondaryFn]
        )
    }

    // MARK: - Private Parsing

    private func parseShortcut(
        forKeyId keyId: String,
        defaultKeyCode: CGKeyCode?,
        defaultFlags: CGEventFlags?
    ) -> KeyShortcut? {
        guard let entry = entries[keyId] else {
            // If entry is absent in plist, Move Left/Right default to enabled in macOS; direct Desktop 1..16 default to disabled.
            if let keyCode = defaultKeyCode, let flags = defaultFlags {
                return KeyShortcut(keyCode: keyCode, flags: flags)
            }
            return nil
        }

        let enabled = (entry["enabled"] as? Bool) ?? false
        guard enabled else { return nil }

        if let value = entry["value"] as? [String: Any],
           let params = value["parameters"] as? [Int],
           params.count >= 3 {
            let keyCode = CGKeyCode(params[1])
            let modifierBits = UInt64(params[2])
            let flags = cgEventFlags(fromSymbolicModifiers: modifierBits, keyCode: keyCode)
            return KeyShortcut(keyCode: keyCode, flags: flags)
        }

        if let keyCode = defaultKeyCode, let flags = defaultFlags {
            return KeyShortcut(keyCode: keyCode, flags: flags)
        }
        return nil
    }

    private func cgEventFlags(fromSymbolicModifiers bits: UInt64, keyCode: CGKeyCode) -> CGEventFlags {
        var flags: CGEventFlags = []
        if (bits & 0x020000) != 0 { flags.insert(.maskShift) }
        if (bits & 0x040000) != 0 { flags.insert(.maskControl) }
        if (bits & 0x080000) != 0 { flags.insert(.maskAlternate) }
        if (bits & 0x100000) != 0 { flags.insert(.maskCommand) }
        if (bits & 0x200000) != 0 { flags.insert(.maskNumericPad) }
        if (bits & 0x800000) != 0 { flags.insert(.maskSecondaryFn) }

        // Arrow keys on macOS keyboards carry numeric-pad + secondary-fn flags for WindowServer recognition.
        if keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126 {
            flags.insert(.maskNumericPad)
            flags.insert(.maskSecondaryFn)
        }
        return flags
    }
}
