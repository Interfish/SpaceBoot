import Cocoa
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Controls native Spaces navigation (via verified Control+Left/Right steps)
/// and exact window placement/z-order (via Accessibility AXUIElement).
final class WindowController {
    private static let keyCodeLeftArrow: CGKeyCode = 123
    private static let keyCodeRightArrow: CGKeyCode = 124

    private let inspector: SpaceInspector

    init(inspector: SpaceInspector) {
        self.inspector = inspector
    }

    // MARK: - Space Switching

    /// Navigates the specified display to `targetIndex` (0-based desktop Space)
    /// and verifies arrival via SkyLight after each step.
    @discardableResult
    func switchDisplay(_ displayUUID: String, toSpaceIndex targetIndex: Int) -> Bool {
        guard let initialDisplay = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
              targetIndex >= 0, targetIndex < initialDisplay.desktopSpaceIds.count else {
            return false
        }

        let targetSpaceId = initialDisplay.desktopSpaceIds[targetIndex]
        if initialDisplay.currentSpaceId == targetSpaceId {
            // Position cursor on target display so newly launched apps open on this display.
            CGWarpMouseCursorPosition(initialDisplay.cgCenter)
            return true
        }

        CGWarpMouseCursorPosition(initialDisplay.cgCenter)
        usleep(100_000)

        let maxSteps = initialDisplay.desktopSpaceIds.count + 2
        for _ in 0..<maxSteps {
            guard let live = inspector.listDisplays().first(where: { $0.uuid == displayUUID }) else {
                return false
            }
            if live.currentSpaceId == targetSpaceId {
                usleep(SpaceBootConfig.spaceAnimationSettleMicros)
                return true
            }
            guard let currentIdx = live.currentSpaceIndex else {
                postControlArrow(keyCode: Self.keyCodeLeftArrow)
                _ = waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: live.currentSpaceId)
                continue
            }

            let keyCode = targetIndex > currentIdx ? Self.keyCodeRightArrow : Self.keyCodeLeftArrow
            let prevId = live.currentSpaceId
            CGWarpMouseCursorPosition(live.cgCenter)
            postControlArrow(keyCode: keyCode)

            if !waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: prevId) {
                return false
            }
        }

        return inspector.listDisplays()
            .first(where: { $0.uuid == displayUUID })?.currentSpaceId == targetSpaceId
    }

    // MARK: - AX Window Frame & Z-Order

    @discardableResult
    func setWindowFrame(windowId: Int, pid: pid_t, frame: WindowRect) -> Bool {
        guard AXIsProcessTrusted(), let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            return false
        }

        var size = CGSize(width: frame.width, height: frame.height)
        var origin = CGPoint(x: frame.x, y: frame.y)

        guard let sizeVal1 = AXValueCreate(.cgSize, &size),
              let posVal = AXValueCreate(.cgPoint, &origin),
              let sizeVal2 = AXValueCreate(.cgSize, &size) else {
            return false
        }

        // size -> position -> size avoids macOS clamping window dimensions across differently sized displays.
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal1)
        let posErr = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        let sizeErr = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal2)
        return posErr == .success && sizeErr == .success
    }

    func raiseWindow(windowId: Int, pid: pid_t) {
        guard AXIsProcessTrusted(), let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            return
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    // MARK: - Private Helpers

    private func findAXWindow(windowId: Int, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for axWin in axWindows {
            var cgWid: CGWindowID = 0
            if _AXUIElementGetWindow(axWin, &cgWid) == .success, Int(cgWid) == windowId {
                return axWin
            }
        }
        return nil
    }

    private func postControlArrow(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskControl, .maskNumericPad, .maskSecondaryFn]

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.post(tap: .cghidEventTap)
        usleep(40_000)
        keyUp.post(tap: .cghidEventTap)
    }

    private func waitForSpaceChange(displayUUID: String, previousSpaceId: Int) -> Bool {
        let deadline = Date().addingTimeInterval(SpaceBootConfig.spaceSwitchTimeoutSeconds)
        while Date() < deadline {
            usleep(SpaceBootConfig.spaceSwitchPollMicros)
            if let live = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
               live.currentSpaceId != previousSpaceId {
                usleep(SpaceBootConfig.spaceAnimationSettleMicros)
                return true
            }
        }
        return false
    }
}
