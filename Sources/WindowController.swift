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
    private let logFilterLock = NSLock()
    /// Serializes every Space switch and multi-step window move: while one window is being placed,
    /// nothing else (boot executor or ⌥ hotkeys) may switch Spaces.
    private let spaceLock = NSRecursiveLock()

    init(inspector: SpaceInspector) {
        self.inspector = inspector
    }

    func withSpaceLock<T>(_ body: () throws -> T) rethrows -> T {
        spaceLock.lock()
        defer { spaceLock.unlock() }
        return try body()
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
        spaceLock.lock()
        defer { spaceLock.unlock() }

        let allDisplays = inspector.listDisplays()
        guard let initialDisplay = allDisplays.first(where: { $0.uuid == displayUUID }),
              targetIndex >= 0, targetIndex < initialDisplay.desktopSpaceIds.count else {
            SpaceBootLogger.log("switchDisplay invalid display=\(displayUUID) targetIndex=\(targetIndex)")
            return false
        }

        let targetSpaceId = initialDisplay.desktopSpaceIds[targetIndex]
        // ⌥N switches skip refocusing when cursor and keyboard focus already sit on this display (the usual case
        // when flipping through one monitor's Spaces), so the Space shortcut goes out the moment ⌥N is pressed.
        if settleForLaunch || !displayHasInputFocus(initialDisplay) {
            focusDisplay(initialDisplay)
        }

        if initialDisplay.currentSpaceId == targetSpaceId {
            SpaceBootLogger.log("switchDisplay \(initialDisplay.name) already on space[\(targetIndex)] (id=\(targetSpaceId))")
            return true
        }

        // Boots wait briefly for held modifier keys so synthetic Space shortcuts are not polluted by them.
        // ⌥N switches don't: logs showed every shortcut posted with ⌥ still held landing fine, while the wait
        // delayed the start of each ⌥-held switch by ~0.46s.
        if settleForLaunch {
            let modifierWaitMs = waitForConflictingModifiersRelease()
            if modifierWaitMs > 0 {
                SpaceBootLogger.log("switchDisplay waited \(modifierWaitMs)ms for ⌥/⌘/⇧ to be released")
            }
        }

        let hotKeys = SymbolicHotKeys()
        let stepSettleMicros: useconds_t = settleForLaunch ? SpaceBootConfig.spaceAnimationSettleMicros : SpaceBootConfig.interactiveSettleMicros
        let pollMicros: useconds_t = settleForLaunch ? SpaceBootConfig.spaceSwitchPollMicros : SpaceBootConfig.interactivePollMicros

        // Fast path: if the user enabled "Switch to Desktop N" in System Settings, jump directly in 1 hop
        // (no stepping through intermediate spaces, no focus dependency).
        if let globalIdx = globalDesktopIndex(displayUUID: displayUUID, localIndex: targetIndex, in: allDisplays),
           let directShortcut = hotKeys.directDesktopShortcut(globalIndex: globalIdx) {
            SpaceBootLogger.log("switchDisplay \(initialDisplay.name) direct jump -> global Desktop \(globalIdx + 1) (id=\(targetSpaceId))")
            let prevId = initialDisplay.currentSpaceId
            postShortcut(directShortcut)
            if waitForSpaceArrival(displayUUID: displayUUID, targetSpaceId: targetSpaceId, previousSpaceId: prevId, settleMicros: stepSettleMicros, pollMicros: pollMicros) {
                SpaceBootLogger.log("switchDisplay direct jump arrived at \(initialDisplay.name) space[\(targetIndex)]")
                return true
            }
            SpaceBootLogger.log("switchDisplay direct jump did not land on id=\(targetSpaceId); falling back to burst navigation")
        }

        guard let leftShortcut = hotKeys.moveLeftShortcut(),
              let rightShortcut = hotKeys.moveRightShortcut() else {
            SpaceBootLogger.log("switchDisplay FAILED: Move Left/Right Space shortcuts are disabled in macOS System Settings")
            return false
        }

        SpaceBootLogger.log("switchDisplay \(initialDisplay.name) from space[\(initialDisplay.currentSpaceIndex ?? -1)] (id=\(initialDisplay.currentSpaceId)) -> space[\(targetIndex)] (id=\(targetSpaceId))")

        // Burst path: when stepping multiple Spaces (e.g. Space 1 -> Space 3), fire the directional shortcuts
        // rapidly (75ms apart) so WindowServer coalesces them into one continuous smooth slide.
        if let startIdx = initialDisplay.currentSpaceIndex {
            let delta = targetIndex - startIdx
            let steps = abs(delta)
            if steps > 1 {
                let burstShortcut = delta > 0 ? rightShortcut : leftShortcut
                let prevId = initialDisplay.currentSpaceId
                for i in 0..<steps {
                    if i > 0 { usleep(75_000) }
                    postShortcut(burstShortcut)
                }
                if waitForSpaceArrival(displayUUID: displayUUID, targetSpaceId: targetSpaceId, previousSpaceId: prevId, settleMicros: stepSettleMicros, pollMicros: pollMicros) {
                    SpaceBootLogger.log("switchDisplay burst arrived at \(initialDisplay.name) space[\(targetIndex)] in \(steps) coalesced step(s)")
                    return true
                }
            }
        }

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

            if settleForLaunch || !displayHasInputFocus(live) {
                focusDisplay(live)
            }
            guard let currentIdx = live.currentSpaceIndex else {
                postShortcut(leftShortcut)
                _ = waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: live.currentSpaceId, settleMicros: stepSettleMicros, pollMicros: pollMicros)
                continue
            }

            let shortcut = targetIndex > currentIdx ? rightShortcut : leftShortcut
            let prevId = live.currentSpaceId
            postShortcut(shortcut)

            if !waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: prevId, settleMicros: stepSettleMicros, pollMicros: pollMicros) {
                SpaceBootLogger.log("switchDisplay step \(step) did not move \(live.name); retrying with desktop focus click")
                clickSafePointOnDisplay(live)
                usleep(120_000)
                postShortcut(shortcut)
                if !waitForSpaceChange(displayUUID: displayUUID, previousSpaceId: prevId, settleMicros: stepSettleMicros, pollMicros: pollMicros) {
                    SpaceBootLogger.log("switchDisplay FAILED on \(live.name) (still id=\(prevId))")
                    return false
                }
            }
        }

        return inspector.listDisplays()
            .first(where: { $0.uuid == displayUUID })?.currentSpaceId == targetSpaceId
    }

    /// Switches `displayUUID` to the Space with ID `spaceId`, wherever macOS currently orders it.
    @discardableResult
    func switchDisplay(_ displayUUID: String, toSpaceId spaceId: Int, settleForLaunch: Bool = true) -> Bool {
        guard let display = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
              let index = display.desktopSpaceIds.firstIndex(of: spaceId) else {
            SpaceBootLogger.log("switchDisplay: Space id=\(spaceId) no longer exists on display \(displayUUID)")
            return false
        }
        return switchDisplay(displayUUID, toSpaceIndex: index, settleForLaunch: settleForLaunch)
    }

    /// Like `switchDisplay(_:toSpaceId:)`, but leaves focus and cursor alone when the Space is already visible.
    @discardableResult
    func ensureSpaceVisible(displayUUID: String, spaceId: Int) -> Bool {
        if inspector.listDisplays().first(where: { $0.uuid == displayUUID })?.currentSpaceId == spaceId {
            return true
        }
        return switchDisplay(displayUUID, toSpaceId: spaceId)
    }

    /// Shows the Space hosting `windowId` on its display (Accessibility only reaches windows on visible Spaces).
    @discardableResult
    func revealSpace(ofWindow windowId: Int) -> Bool {
        let spaceIds = inspector.spaceIds(forWindow: windowId)
        guard let display = inspector.listDisplays().first(where: { d in spaceIds.contains(where: d.desktopSpaceIds.contains) }),
              let spaceId = spaceIds.first(where: display.desktopSpaceIds.contains) else {
            return false
        }
        return ensureSpaceVisible(displayUUID: display.uuid, spaceId: spaceId)
    }

    /// Switches directly to a specific Space slot key (used by customizable ⌥1–⌥9 hotkeys).
    @discardableResult
    func switchToSlot(_ key: SpaceSlotKey) -> Bool {
        switchDisplay(key.displayUUID, toSpaceIndex: key.spaceIndex, settleForLaunch: false)
    }

    // MARK: - Cross-Space Relocation

    /// Puts a window on Space `targetSpaceId` of `targetDisplayUUID` at `frame`, wherever it currently is.
    /// Returns true once the window is on the target Space (frame drift is left to the caller's settle guard).
    ///
    /// macOS has no public API to move a window between Spaces (minimize → switch → restore puts it back on its
    /// original Space). But WindowServer reliably assigns a window that is moved onto another display to that
    /// display's *current* Space, so:
    /// - target on another display: show the target Space there, then move the window across;
    /// - target on the same display: park the window on a helper display, switch its own display, move it back.
    @discardableResult
    func relocateWindow(windowId: Int, pid: pid_t, frame: WindowRect, targetDisplayUUID: String, targetSpaceId: Int) -> Bool {
        spaceLock.lock()
        defer { spaceLock.unlock() }
        let restoreEnhancedUI = disableEnhancedUserInterface(pid: pid)
        defer { restoreEnhancedUI() }

        guard AXIsProcessTrusted(),
              let live = inspector.listAllUserWindows().first(where: { $0.windowId == windowId }) else {
            return false
        }
        let displays = inspector.listDisplays()
        guard let source = displays.first(where: { d in live.spaceIds.contains(where: d.desktopSpaceIds.contains) }),
              let sourceSpaceId = live.spaceIds.first(where: source.desktopSpaceIds.contains) else {
            SpaceBootLogger.log("Relocate: cannot find the Desktop Space of wid=\(windowId) (\(live.appName)) sp=\(live.spaceIds)")
            return false
        }

        if sourceSpaceId == targetSpaceId {
            guard ensureSpaceVisible(displayUUID: targetDisplayUUID, spaceId: targetSpaceId) else { return false }
            setWindowFrameVerified(windowId: windowId, pid: pid, frame: frame, targetSpaceId: targetSpaceId)
            return isWindow(windowId, onSpace: targetSpaceId)
        }

        let sameDisplay = source.uuid == targetDisplayUUID
        let helper = displays.first(where: {
            $0.uuid != source.uuid && $0.cgFrame.width > 0 && $0.desktopSpaceIds.contains($0.currentSpaceId)
        })
        if sameDisplay && helper == nil {
            SpaceBootLogger.log("Relocate wid=\(windowId) (\(live.appName)): no second display to bounce through; it stays on sp=\(sourceSpaceId)")
            return false
        }

        guard ensureSpaceVisible(displayUUID: source.uuid, spaceId: sourceSpaceId) else { return false }

        guard sameDisplay, let helper else {
            guard ensureSpaceVisible(displayUUID: targetDisplayUUID, spaceId: targetSpaceId) else { return false }
            setWindowFrameVerified(windowId: windowId, pid: pid, frame: frame, targetSpaceId: targetSpaceId)
            let ok = isWindow(windowId, onSpace: targetSpaceId)
            SpaceBootLogger.log("Relocate wid=\(windowId) (\(live.appName)) sp=\(sourceSpaceId) -> sp=\(targetSpaceId) across displays: \(ok ? "ok" : "FAILED")")
            return ok
        }

        guard moveWindow(windowId, pid: pid, to: parkingFrame(for: live.frame, on: helper), joining: helper.currentSpaceId, sizeFirst: true) else {
            SpaceBootLogger.log("Relocate wid=\(windowId) (\(live.appName)): did not join helper display \(helper.name) (\(describeWindow(windowId))); putting it back")
            putBack(windowId: windowId, pid: pid, frame: live.frame, spaceId: sourceSpaceId)
            return false
        }
        guard ensureSpaceVisible(displayUUID: targetDisplayUUID, spaceId: targetSpaceId) else {
            // Its own display did not switch, so moving it back returns it to where it was.
            putBack(windowId: windowId, pid: pid, frame: live.frame, spaceId: sourceSpaceId)
            return false
        }
        setWindowFrameVerified(windowId: windowId, pid: pid, frame: frame, targetSpaceId: targetSpaceId)
        if !isWindow(windowId, onSpace: targetSpaceId) {
            // The app resisted the final move; anywhere on its own display (now showing the target Space) still lands it there.
            putBack(windowId: windowId, pid: pid, frame: live.frame, spaceId: targetSpaceId)
        }
        let ok = isWindow(windowId, onSpace: targetSpaceId)
        SpaceBootLogger.log("Relocate wid=\(windowId) (\(live.appName)) sp=\(sourceSpaceId) -> sp=\(targetSpaceId) via \(helper.name): \(ok ? "ok" : "FAILED")")
        return ok
    }

    /// True if both the cursor and the focused window are on `display`, so Space shortcuts already act on it.
    private func displayHasInputFocus(_ display: LiveDisplayInfo) -> Bool {
        guard let cursor = CGEvent(source: nil)?.location, display.cgFrame.contains(cursor) else { return false }

        var appRef: CFTypeRef?
        var windowRef: CFTypeRef?
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let app = appRef,
              AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef,
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else {
            return false
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return false
        }
        return display.cgFrame.contains(CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
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
        let restoreEnhancedUI = disableEnhancedUserInterface(pid: pid)
        defer { restoreEnhancedUI() }

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

    private func applyAXFrameOnce(windowId: Int, pid: pid_t, frame: WindowRect, sizeFirst: Bool = false) -> Bool {
        guard let axWindow = findAXWindow(windowId: windowId, pid: pid) else { return false }

        var origin = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)

        guard let posVal1 = AXValueCreate(.cgPoint, &origin),
              let sizeVal1 = AXValueCreate(.cgSize, &size),
              let posVal2 = AXValueCreate(.cgPoint, &origin),
              let sizeVal2 = AXValueCreate(.cgSize, &size) else {
            return false
        }

        // Default: move to the target display FIRST, then resize, then re-apply both to prevent cross-display clamping.
        // `sizeFirst` shrinks before moving instead, for a big window heading to a smaller display.
        if sizeFirst {
            let s1 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal1)
            let p1 = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal1)
            let s2 = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal2)
            let p2 = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal2)
            return (p1 == .success || p2 == .success) && (s1 == .success || s2 == .success)
        }
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
        logFilterLock.lock()
        let isFirst = loggedFilteredWindowIds.insert(windowId).inserted
        logFilterLock.unlock()
        if isFirst {
            SpaceBootLogger.log(message)
        }
    }

    /// A frame fully inside `display` (shrunk if needed) so the parked window unambiguously belongs to it.
    private func parkingFrame(for frame: WindowRect, on display: LiveDisplayInfo) -> WindowRect {
        let inset = 60.0
        return WindowRect(
            x: Int(display.cgFrame.minX + inset),
            y: Int(display.cgFrame.minY + inset),
            width: min(frame.width, Int(max(400, display.cgFrame.width - inset * 2))),
            height: min(frame.height, Int(max(300, display.cgFrame.height - inset * 2)))
        )
    }

    private func isWindow(_ windowId: Int, onSpace spaceId: Int) -> Bool {
        inspector.spaceIds(forWindow: windowId).contains(spaceId)
    }

    /// Moves a window to `frame` and confirms it joined `spaceId`, so a failed bounce never strands it on the helper display.
    private func putBack(windowId: Int, pid: pid_t, frame: WindowRect, spaceId: Int) {
        if !moveWindow(windowId, pid: pid, to: frame, joining: spaceId, sizeFirst: false) {
            SpaceBootLogger.log("Relocate: wid=\(windowId) could not be moved back onto sp=\(spaceId) (\(describeWindow(windowId)))")
        }
    }

    /// Applies `frame` until the window shows up on `spaceId`. Chromium/Electron windows often ignore the first
    /// cross-display move (Chrome needed 2–3 tries in the logs), so the frame is re-applied until it sticks.
    private func moveWindow(_ windowId: Int, pid: pid_t, to frame: WindowRect, joining spaceId: Int, sizeFirst: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(SpaceBootConfig.relocationJoinTimeoutSeconds)
        var attempts = 0
        var lastSetOk = false
        repeat {
            attempts += 1
            lastSetOk = applyAXFrameOnce(windowId: windowId, pid: pid, frame: frame, sizeFirst: sizeFirst)
            if waitForWindow(windowId, toJoinSpace: spaceId, timeout: 0.4) {
                if attempts > 1 {
                    SpaceBootLogger.log("Relocate: wid=\(windowId) joined sp=\(spaceId) on attempt \(attempts)")
                }
                return true
            }
        } while Date() < deadline
        SpaceBootLogger.log("Relocate: wid=\(windowId) still not on sp=\(spaceId) after \(attempts) attempt(s) (last AX set \(lastSetOk ? "accepted" : "failed"))")
        return false
    }

    private func describeWindow(_ windowId: Int) -> String {
        let frame = inspector.listAllUserWindows().first(where: { $0.windowId == windowId }).map { "\($0.frame)" } ?? "not listed"
        return "now \(frame) sp=\(inspector.spaceIds(forWindow: windowId))"
    }

    /// Chromium/Electron apps animate — and may drop — frame changes while "AXEnhancedUserInterface" is on (some
    /// accessibility tools turn it on), so, like other window managers, switch it off around a move. Returns the undo.
    private func disableEnhancedUserInterface(pid: pid_t) -> () -> Void {
        let app = AXUIElementCreateApplication(pid)
        let attribute = "AXEnhancedUserInterface" as CFString
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &value) == .success, (value as? Bool) == true else {
            return {}
        }
        AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse)
        return { AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue) }
    }

    private func waitForWindow(_ windowId: Int, toJoinSpace spaceId: Int, timeout: TimeInterval = SpaceBootConfig.relocationJoinTimeoutSeconds) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if inspector.spaceIds(forWindow: windowId).contains(spaceId) {
                return true
            }
            usleep(50_000)
        }
        return false
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

    /// Returns how many milliseconds it waited (0 if no conflicting modifier was held).
    private func waitForConflictingModifiersRelease() -> Int {
        let conflicting: CGEventFlags = [.maskAlternate, .maskCommand, .maskShift]
        let start = Date()
        let deadline = start.addingTimeInterval(0.45)
        while Date() < deadline, !CGEventSource.flagsState(.hidSystemState).intersection(conflicting).isEmpty {
            usleep(15_000)
        }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    private func waitForSpaceArrival(
        displayUUID: String,
        targetSpaceId: Int,
        previousSpaceId: Int,
        settleMicros: useconds_t,
        pollMicros: useconds_t = SpaceBootConfig.spaceSwitchPollMicros
    ) -> Bool {
        let deadline = Date().addingTimeInterval(SpaceBootConfig.spaceSwitchTimeoutSeconds)
        while Date() < deadline {
            usleep(pollMicros)
            if let live = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
               live.currentSpaceId == targetSpaceId {
                usleep(settleMicros)
                return true
            }
        }
        return false
    }

    private func waitForSpaceChange(
        displayUUID: String,
        previousSpaceId: Int,
        settleMicros: useconds_t,
        pollMicros: useconds_t = SpaceBootConfig.spaceSwitchPollMicros
    ) -> Bool {
        let deadline = Date().addingTimeInterval(SpaceBootConfig.spaceSwitchTimeoutSeconds)
        while Date() < deadline {
            usleep(pollMicros)
            if let live = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
               live.currentSpaceId != previousSpaceId {
                usleep(settleMicros)
                return true
            }
        }
        return false
    }
}
