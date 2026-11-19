import Cocoa
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Controls native Spaces navigation (with explicit target-display activation + verified Space arrival),
/// AX window metadata inspection, and verified cross-display window placement/z-order.
final class WindowController {
    private static let keyCodeLeftArrow: CGKeyCode = 123
    private static let keyCodeRightArrow: CGKeyCode = 124

    private let inspector: SpaceInspector

    init(inspector: SpaceInspector) {
        self.inspector = inspector
    }

    // MARK: - AX Window Introspection

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

    private var loggedFilteredWindowIds: Set<Int> = []

    /// Determines whether a window qualifies as a genuine main content window (filtering out splash/login popups).
    /// When `requireAXMetadata` is true (used for newly spawned active-Space windows), transient/closing windows
    /// whose AXUIElement is unavailable are rejected rather than accepted via size heuristics.
    func isLikelyMainWindow(
        _ win: LiveWindowInfo,
        expectedFrame: WindowRect? = nil,
        requireAXMetadata: Bool = false
    ) -> Bool {
        if let meta = inspectAXWindow(windowId: win.windowId, pid: win.pid) {
            if !meta.isStandardMainWindow {
                logFilterOnce(win.windowId, "Filter non-standard window wid=\(win.windowId) app=\(win.appName) role=\(meta.role) subrole=\(meta.subrole) min=\(meta.isMinimized)")
                return false
            }
            if !meta.isPositionSettable {
                logFilterOnce(win.windowId, "Filter immovable window wid=\(win.windowId) app=\(win.appName)")
                return false
            }
            // Splash/login windows are typically non-resizable and small compared to the saved browser window.
            if let expected = expectedFrame,
               expected.width >= SpaceBootConfig.largeTargetMinWidth,
               expected.height >= SpaceBootConfig.largeTargetMinHeight {
                if !meta.isSizeSettable {
                    logFilterOnce(win.windowId, "Filter non-resizable splash wid=\(win.windowId) app=\(win.appName) size=\(win.frame.width)x\(win.frame.height)")
                    return false
                }
                if win.frame.width < SpaceBootConfig.splashFilterMinWidth ||
                   win.frame.height < SpaceBootConfig.splashFilterMinHeight {
                    logFilterOnce(win.windowId, "Filter small splash wid=\(win.windowId) app=\(win.appName) size=\(win.frame.width)x\(win.frame.height) expected=\(expected.width)x\(expected.height)")
                    return false
                }
            } else if !meta.isSizeSettable && (win.frame.width < 450 || win.frame.height < 450) {
                logFilterOnce(win.windowId, "Filter small fixed helper wid=\(win.windowId) app=\(win.appName) size=\(win.frame.width)x\(win.frame.height)")
                return false
            }
            return true
        }

        if requireAXMetadata && AXIsProcessTrusted() {
            return false
        }

        // If AX metadata wasn't readable (e.g., off-Space window during Record), apply conservative size heuristic.
        if let expected = expectedFrame,
           expected.width >= SpaceBootConfig.largeTargetMinWidth,
           expected.height >= SpaceBootConfig.largeTargetMinHeight {
            return win.frame.width >= SpaceBootConfig.splashFilterMinWidth &&
                   win.frame.height >= SpaceBootConfig.splashFilterMinHeight
        }
        return true
    }

    private func logFilterOnce(_ windowId: Int, _ message: String) {
        if loggedFilteredWindowIds.insert(windowId).inserted {
            SpaceBootLogger.log(message)
        }
    }

    // MARK: - Space Switching

    /// Activates the target display and navigates it to `targetIndex` (0-based desktop Space),
    /// verifying arrival via SkyLight after each step.
    @discardableResult
    func switchDisplay(_ displayUUID: String, toSpaceIndex targetIndex: Int) -> Bool {
        guard let initialDisplay = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
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

        SpaceBootLogger.log("switchDisplay \(initialDisplay.name) from space[\(initialDisplay.currentSpaceIndex ?? -1)] (id=\(initialDisplay.currentSpaceId)) -> space[\(targetIndex)] (id=\(targetSpaceId))")

        let maxSteps = initialDisplay.desktopSpaceIds.count + 2
        for step in 0..<maxSteps {
            guard let live = inspector.listDisplays().first(where: { $0.uuid == displayUUID }) else {
                return false
            }
            if live.currentSpaceId == targetSpaceId {
                usleep(SpaceBootConfig.spaceAnimationSettleMicros)
                SpaceBootLogger.log("switchDisplay arrived at \(live.name) space[\(targetIndex)] after \(step) step(s)")
                return true
            }

            focusDisplay(live)
            guard let currentIdx = live.currentSpaceIndex else {
                postControlArrow(keyCode: Self.keyCodeLeftArrow)
                _ = waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: live.currentSpaceId)
                continue
            }

            let keyCode = targetIndex > currentIdx ? Self.keyCodeRightArrow : Self.keyCodeLeftArrow
            let prevId = live.currentSpaceId
            postControlArrow(keyCode: keyCode)

            if !waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: prevId) {
                // Retry once by explicitly clicking an empty desktop area on this display to force active-display focus.
                SpaceBootLogger.log("switchDisplay step \(step) did not move \(live.name); retrying with desktop focus click")
                clickSafePointOnDisplay(live)
                usleep(120_000)
                postControlArrow(keyCode: keyCode)
                if !waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: prevId) {
                    SpaceBootLogger.log("switchDisplay FAILED on \(live.name) (still id=\(prevId))")
                    return false
                }
            }
        }

        return inspector.listDisplays()
            .first(where: { $0.uuid == displayUUID })?.currentSpaceId == targetSpaceId
    }

    /// Moves pointer and transfers active-display focus to `display` so Ctrl+Arrow and new windows target it.
    func focusDisplay(_ display: LiveDisplayInfo) {
        moveMouse(to: display.cgCenter)

        // Prefer focusing an existing visible window already on this display's current Space (no click side effects).
        let windowsOnCurrentSpace = inspector.listAllUserWindows().filter {
            $0.spaceIds.contains(display.currentSpaceId)
        }
        if let topWin = windowsOnCurrentSpace.first {
            raiseWindow(windowId: topWin.windowId, pid: topWin.pid)
            usleep(80_000)
            return
        }

        // Empty Space: click the empty desktop so macOS switches keyboard/Space focus to this display.
        clickSafePointOnDisplay(display)
        usleep(80_000)
    }

    // MARK: - Verified Cross-Display Window Frame & Z-Order

    /// Sets window frame using position -> size -> position -> size and verifies arrival
    /// (retrying if Chrome/Electron snaps back asynchronously during startup).
    @discardableResult
    func setWindowFrameVerified(windowId: Int, pid: pid_t, frame: WindowRect, targetSpaceId: Int? = nil) -> Bool {
        guard AXIsProcessTrusted() else { return false }

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

    private func moveMouse(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    /// Clicks an uncovered point on `display` (or neutral menu bar midpoint if fully covered) to focus that display.
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
            CGPoint(x: display.cgFrame.midX, y: display.cgFrame.minY + 12) // Empty middle of display menu bar
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
        usleep(50_000)
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
