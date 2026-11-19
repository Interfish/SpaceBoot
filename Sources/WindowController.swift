import Cocoa
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Controls native Spaces navigation (dynamically reading the user's macOS Mission Control shortcuts),
/// AX window metadata inspection, and verified cross-display window placement/z-order.
final class WindowController {
    private let inspector: SpaceInspector
    private var loggedFilteredWindowIds: Set<Int> = []

    init(inspector: SpaceInspector) {
        self.inspector = inspector
    }

    // MARK: - AX Window Introspection

    /// Reads the window's logical position and size directly via Accessibility (unaffected by Mission Control thumbnail scaling).
    func readAXWindowFrame(windowId: Int, pid: pid_t) -> WindowRect? {
        guard AXIsProcessTrusted(), let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            return nil
        }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posAX = posRef, let sizeAX = sizeRef else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAX as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeAX as! AXValue, .cgSize, &size) else {
            return nil
        }

        return WindowRect(
            x: Int(origin.x.rounded()),
            y: Int(origin.y.rounded()),
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded())
        )
    }

    /// Reads Accessibility metadata for a window. Returns nil if inaccessible (e.g., off-Space window
    /// that an app only exposes while on screen, or missing Accessibility permission).
    func inspectAXWindow(windowId: Int, pid: pid_t) -> AXWindowMeta? {
        guard AXIsProcessTrusted(), let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            return nil
        }

        let role = copyStringAttr(axWindow, kAXRoleAttribute) ?? ""
        let subrole = copyStringAttr(axWindow, kAXSubroleAttribute) ?? ""
        let title = copyStringAttr(axWindow, kAXTitleAttribute) ?? ""

        var sizeSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &sizeSettable)

        var posSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axWindow, kAXPositionAttribute as CFString, &posSettable)

        var minRef: CFTypeRef?
        let isMinimized = (AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef) == .success)
            && ((minRef as? Bool) == true)

        return AXWindowMeta(
            role: role,
            subrole: subrole,
            title: title,
            isSizeSettable: sizeSettable.boolValue,
            isPositionSettable: posSettable.boolValue,
            isMinimized: isMinimized
        )
    }

    /// Recording filter: accepts any normal standard window (including fixed-size utilities like Calculator),
    /// rejecting only non-standard dialogs/tooltips/minimized windows.
    func isRecordableWindow(_ win: LiveWindowInfo) -> Bool {
        if let meta = inspectAXWindow(windowId: win.windowId, pid: win.pid) {
            if !meta.isStandardMainWindow || !meta.isPositionSettable {
                logFilterOnce(win.windowId, "Record skip non-standard wid=\(win.windowId) app=\(win.appName) role=\(meta.role) subrole=\(meta.subrole)")
                return false
            }
        }
        return true
    }

    /// Boot filter: verifies a candidate window matches the expected target window and is not a splash/login popup.
    func isLikelyMainWindow(
        _ win: LiveWindowInfo,
        expectedFrame: WindowRect,
        requireAXMetadata: Bool = false
    ) -> Bool {
        let expectsLargeWindow = expectedFrame.width >= SpaceBootConfig.largeTargetMinWidth
            && expectedFrame.height >= SpaceBootConfig.largeTargetMinHeight

        if let meta = inspectAXWindow(windowId: win.windowId, pid: win.pid) {
            if !meta.isStandardMainWindow {
                logFilterOnce(win.windowId, "Filter non-standard window wid=\(win.windowId) app=\(win.appName) role=\(meta.role) subrole=\(meta.subrole) min=\(meta.isMinimized)")
                return false
            }
            if !meta.isPositionSettable {
                logFilterOnce(win.windowId, "Filter immovable window wid=\(win.windowId) app=\(win.appName)")
                return false
            }
            if expectsLargeWindow {
                if !meta.isSizeSettable {
                    logFilterOnce(win.windowId, "Filter non-resizable splash wid=\(win.windowId) app=\(win.appName) size=\(win.frame.width)x\(win.frame.height)")
                    return false
                }
                if win.frame.width < SpaceBootConfig.splashFilterMinWidth ||
                   win.frame.height < SpaceBootConfig.splashFilterMinHeight {
                    logFilterOnce(win.windowId, "Filter small splash wid=\(win.windowId) app=\(win.appName) size=\(win.frame.width)x\(win.frame.height) expected=\(expectedFrame.width)x\(expectedFrame.height)")
                    return false
                }
            }
            return true
        }

        if requireAXMetadata && AXIsProcessTrusted() {
            return false
        }

        if expectsLargeWindow {
            return win.frame.width >= SpaceBootConfig.splashFilterMinWidth &&
                   win.frame.height >= SpaceBootConfig.splashFilterMinHeight
        }
        return true
    }

    // MARK: - Space Switching (Adaptive to User's macOS Shortcuts)

    /// Navigates the specified display to `targetIndex` (0-based desktop Space),
    /// using direct "Switch to Desktop N" shortcut if enabled, otherwise stepping with the user's Move Left/Right shortcut.
    /// Set `settleForLaunch: false` for fast interactive hotkey switching.
    @discardableResult
    func switchDisplay(_ displayUUID: String, toSpaceIndex targetIndex: Int, settleForLaunch: Bool = true) -> Bool {
        let allDisplays = inspector.listDisplays()
        guard let initialDisplay = allDisplays.first(where: { $0.uuid == displayUUID }),
              targetIndex >= 0, targetIndex < initialDisplay.desktopSpaceIds.count else {
            SpaceBootLogger.log("switchDisplay invalid display=\(displayUUID) targetIndex=\(targetIndex)")
            return false
        }

        let targetSpaceId = initialDisplay.desktopSpaceIds[targetIndex]
        focusDisplay(initialDisplay)

        if initialDisplay.currentSpaceId == targetSpaceId {
            SpaceBootLogger.log("switchDisplay \(initialDisplay.name) already on space[\(targetIndex)] (id=\(targetSpaceId))")
            return true
        }

        // Wait briefly if the user is still holding physical modifier keys (e.g. Option from ⌥1–⌥9)
        // so synthetic Space shortcuts are not polluted by held modifiers.
        waitForConflictingModifiersRelease()

        let hotKeys = SymbolicHotKeys()
        let stepSettleMicros: useconds_t = settleForLaunch ? SpaceBootConfig.spaceAnimationSettleMicros : 160_000

        // Fast path: if the user enabled "Switch to Desktop N" in System Settings, jump directly in 1 hop.
        if let globalIdx = globalDesktopIndex(displayUUID: displayUUID, localIndex: targetIndex, in: allDisplays),
           let directShortcut = hotKeys.directDesktopShortcut(globalIndex: globalIdx) {
            SpaceBootLogger.log("switchDisplay \(initialDisplay.name) direct jump -> global Desktop \(globalIdx + 1) (id=\(targetSpaceId))")
            let prevId = initialDisplay.currentSpaceId
            postShortcut(directShortcut)
            if waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: prevId, settleMicros: stepSettleMicros),
               inspector.listDisplays().first(where: { $0.uuid == displayUUID })?.currentSpaceId == targetSpaceId {
                SpaceBootLogger.log("switchDisplay direct jump arrived at \(initialDisplay.name) space[\(targetIndex)]")
                return true
            }
            SpaceBootLogger.log("switchDisplay direct jump did not land on id=\(targetSpaceId); falling back to step navigation")
        }

        guard let leftShortcut = hotKeys.moveLeftShortcut(),
              let rightShortcut = hotKeys.moveRightShortcut() else {
            SpaceBootLogger.log("switchDisplay FAILED: Move Left/Right Space shortcuts are disabled in macOS System Settings")
            return false
        }

        SpaceBootLogger.log("switchDisplay \(initialDisplay.name) from space[\(initialDisplay.currentSpaceIndex ?? -1)] (id=\(initialDisplay.currentSpaceId)) -> space[\(targetIndex)] (id=\(targetSpaceId))")

        let maxSteps = initialDisplay.desktopSpaceIds.count + 2
        for step in 0..<maxSteps {
            guard let live = inspector.listDisplays().first(where: { $0.uuid == displayUUID }) else {
                return false
            }
            if live.currentSpaceId == targetSpaceId {
                if settleForLaunch {
                    usleep(SpaceBootConfig.spaceAnimationSettleMicros)
                }
                SpaceBootLogger.log("switchDisplay arrived at \(live.name) space[\(targetIndex)] after \(step) step(s)")
                return true
            }

            focusDisplay(live)
            guard let currentIdx = live.currentSpaceIndex else {
                postShortcut(leftShortcut)
                _ = waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: live.currentSpaceId, settleMicros: stepSettleMicros)
                continue
            }

            let shortcut = targetIndex > currentIdx ? rightShortcut : leftShortcut
            let prevId = live.currentSpaceId
            postShortcut(shortcut)

            if !waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: prevId, settleMicros: stepSettleMicros) {
                SpaceBootLogger.log("switchDisplay step \(step) did not move \(live.name); retrying with desktop focus click")
                clickSafePointOnDisplay(live)
                usleep(120_000)
                postShortcut(shortcut)
                if !waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: prevId, settleMicros: stepSettleMicros) {
                    SpaceBootLogger.log("switchDisplay FAILED on \(live.name) (still id=\(prevId))")
                    return false
                }
            }
        }

        return inspector.listDisplays()
            .first(where: { $0.uuid == displayUUID })?.currentSpaceId == targetSpaceId
    }

    /// Switches Space `localIndex` (0-based) on whichever display currently contains the mouse cursor.
    @discardableResult
    func switchActiveDisplay(toSpaceIndex localIndex: Int) -> Bool {
        let displays = inspector.listDisplays()
        guard !displays.isEmpty else { return false }

        let targetDisplay: LiveDisplayInfo
        if let cursorLocation = CGEvent(source: nil)?.location,
           let underCursor = displays.first(where: { $0.cgFrame.contains(cursorLocation) }) {
            targetDisplay = underCursor
        } else {
            targetDisplay = displays[0]
        }

        guard localIndex >= 0, localIndex < targetDisplay.desktopSpaceIds.count else {
            SpaceBootLogger.log("switchActiveDisplay \(targetDisplay.name) has only \(targetDisplay.desktopSpaceIds.count) space(s); ignoring index \(localIndex)")
            return false
        }

        return switchDisplay(targetDisplay.uuid, toSpaceIndex: localIndex, settleForLaunch: false)
    }

    /// Switches directly to a 0-based global desktop index across connected displays.
    @discardableResult
    func switchToGlobalDesktop(index globalIndex: Int) -> Bool {
        let displays = inspector.listDisplays()
        var offset = 0
        for display in displays {
            let count = display.desktopSpaceIds.count
            if globalIndex >= offset && globalIndex < offset + count {
                let localIdx = globalIndex - offset
                return switchDisplay(display.uuid, toSpaceIndex: localIdx, settleForLaunch: false)
            }
            offset += count
        }
        return false
    }

    /// Transfers active-display focus to `display` so Space navigation and new windows target it.
    /// Avoids warping the user's cursor if it is already inside `display`.
    func focusDisplay(_ display: LiveDisplayInfo) {
        let cursorAlreadyOnDisplay = CGEvent(source: nil).map { display.cgFrame.contains($0.location) } ?? false
        if !cursorAlreadyOnDisplay {
            moveMouse(to: display.cgCenter)
        }

        let windowsOnCurrentSpace = inspector.listAllUserWindows().filter {
            $0.spaceIds.contains(display.currentSpaceId)
        }
        if let topWin = windowsOnCurrentSpace.first {
            raiseWindow(windowId: topWin.windowId, pid: topWin.pid)
            usleep(80_000)
            return
        }

        clickSafePointOnDisplay(display)
        usleep(80_000)
    }

    // MARK: - Verified Cross-Display Window Frame & Z-Order

    /// Sets window frame using position -> size -> position -> size and verifies arrival
    /// (retrying if Chromium/Electron snaps back asynchronously during startup, and stopping early
    /// if macOS clamps the window to the exact same bounds on the target Space).
    @discardableResult
    func setWindowFrameVerified(windowId: Int, pid: pid_t, frame: WindowRect, targetSpaceId: Int? = nil) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        var previousRect: WindowRect?

        for attempt in 1...SpaceBootConfig.frameApplyMaxAttempts {
            let applied = applyAXFrameOnce(windowId: windowId, pid: pid, frame: frame)
            usleep(SpaceBootConfig.frameVerifyDelayMicros)

            if let live = inspector.listAllUserWindows().first(where: { $0.windowId == windowId }) {
                let frameOk = live.frame.isApproximatelyEqual(to: frame, tolerance: SpaceBootConfig.frameVerifyTolerancePx)
                let spaceOk = targetSpaceId.map { live.spaceIds.contains($0) } ?? true
                if frameOk && spaceOk {
                    if attempt > 1 {
                        SpaceBootLogger.log("Frame converged on attempt \(attempt) for wid=\(windowId) (\(live.appName)) -> \(live.frame)")
                    }
                    return true
                }
                // If the window is already on the target Space at the right origin and clamped identically across 2 tries
                // (e.g., macOS Dock or app min/max size constraint), accept without burning remaining retries.
                if spaceOk,
                   let prev = previousRect,
                   prev == live.frame,
                   abs(live.frame.x - frame.x) <= SpaceBootConfig.frameVerifyTolerancePx,
                   abs(live.frame.y - frame.y) <= SpaceBootConfig.frameVerifyTolerancePx {
                    SpaceBootLogger.log("Frame clamped by OS/app on target Space for wid=\(windowId) (\(live.appName)): \(live.frame) (requested \(frame))")
                    return true
                }
                previousRect = live.frame
                SpaceBootLogger.log("Frame attempt \(attempt) for wid=\(windowId) (\(live.appName)): got \(live.frame) sp=\(live.spaceIds), want \(frame) sp=\(targetSpaceId ?? -1) (applied=\(applied))")
            } else {
                SpaceBootLogger.log("Frame attempt \(attempt): wid=\(windowId) no longer in window list")
                return false
            }
        }
        return false
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

    private func globalDesktopIndex(displayUUID: String, localIndex: Int, in displays: [LiveDisplayInfo]) -> Int? {
        var offset = 0
        for d in displays {
            if d.uuid == displayUUID {
                return offset + localIndex
            }
            offset += d.desktopSpaceIds.count
        }
        return nil
    }

    private func applyAXFrameOnce(windowId: Int, pid: pid_t, frame: WindowRect) -> Bool {
        guard let axWindow = findAXWindow(windowId: windowId, pid: pid) else { return false }

        var origin = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)

        guard let posVal1 = AXValueCreate(.cgPoint, &origin),
              let sizeVal1 = AXValueCreate(.cgSize, &size),
              let posVal2 = AXValueCreate(.cgPoint, &origin),
              let sizeVal2 = AXValueCreate(.cgSize, &size) else {
            return false
        }

        // Move to target display FIRST, then resize, then re-apply position & size to prevent cross-display clamping.
        let p1 = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal1)
        let s1 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal1)
        let p2 = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal2)
        let s2 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal2)
        return (p1 == .success || p2 == .success) && (s1 == .success || s2 == .success)
    }

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

    private func copyStringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private func logFilterOnce(_ windowId: Int, _ message: String) {
        if loggedFilteredWindowIds.insert(windowId).inserted {
            SpaceBootLogger.log(message)
        }
    }

    private func moveMouse(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    private func clickSafePointOnDisplay(_ display: LiveDisplayInfo) {
        let windowsOnSpace = inspector.listAllUserWindows().filter {
            $0.spaceIds.contains(display.currentSpaceId)
        }
        let rects = windowsOnSpace.map {
            CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)
        }

        let candidates: [CGPoint] = [
            display.cgCenter,
            CGPoint(x: display.cgFrame.minX + 40, y: display.cgFrame.maxY - 60),
            CGPoint(x: display.cgFrame.maxX - 40, y: display.cgFrame.maxY - 60),
            CGPoint(x: display.cgFrame.midX, y: display.cgFrame.minY + 12)
        ]

        let targetPoint = candidates.first { pt in
            !rects.contains(where: { $0.contains(pt) })
        } ?? CGPoint(x: display.cgFrame.midX, y: display.cgFrame.minY + 12)

        moveMouse(to: targetPoint)
        usleep(40_000)

        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left),
           let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
            usleep(30_000)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postShortcut(_ shortcut: KeyShortcut) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000)
        keyUp.post(tap: .cghidEventTap)
    }

    private func waitForConflictingModifiersRelease() {
        let conflicting: CGEventFlags = [.maskAlternate, .maskCommand, .maskShift]
        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            let current = CGEventSource.flagsState(.hidSystemState)
            if current.intersection(conflicting).isEmpty {
                return
            }
            usleep(15_000)
        }
    }

    private func waitForSpaceChange(displayUUID: String, previousSpaceId: Int, settleMicros: useconds_t) -> Bool {
        let deadline = Date().addingTimeInterval(SpaceBootConfig.spaceSwitchTimeoutSeconds)
        while Date() < deadline {
            usleep(SpaceBootConfig.spaceSwitchPollMicros)
            if let live = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
               live.currentSpaceId != previousSpaceId {
                usleep(settleMicros)
                return true
            }
        }
        return false
    }
}
