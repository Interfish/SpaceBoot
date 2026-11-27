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

        var fsRef: CFTypeRef?
        let isFullScreen = (AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fsRef) == .success)
            && ((fsRef as? Bool) == true)

        return AXWindowMeta(
            role: role,
            subrole: subrole,
            title: title,
            isSizeSettable: sizeSettable.boolValue,
            isPositionSettable: posSettable.boolValue,
            isMinimized: isMinimized,
            isFullScreen: isFullScreen
        )
    }

    /// Recording filter: accepts any normal standard window (including fixed-size utilities like Calculator),
    /// rejecting only non-standard dialogs/tooltips/minimized windows. Fullscreen Spaces allow `isPositionSettable == false`.
    func isRecordableWindow(_ win: LiveWindowInfo, isFullScreenSpace: Bool = false) -> Bool {
        if let meta = inspectAXWindow(windowId: win.windowId, pid: win.pid) {
            if isFullScreenSpace {
                if meta.isMinimized {
                    logFilterOnce(win.windowId, "Record skip minimized fullscreen wid=\(win.windowId) app=\(win.appName)")
                    return false
                }
                return true
            }
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
            if !meta.isPositionSettable && !meta.isFullScreen {
                logFilterOnce(win.windowId, "Filter immovable window wid=\(win.windowId) app=\(win.appName)")
                return false
            }
            if expectsLargeWindow {
                if !meta.isSizeSettable && !meta.isFullScreen {
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

    /// Navigates the specified display to `targetIndex` (0-based across all Spaces: Desktop, Fullscreen, Split View),
    /// using direct "Switch to Desktop N" shortcut if enabled for Desktop Spaces, otherwise stepping with Move Left/Right.
    /// Set `settleForLaunch: false` for fast interactive hotkey switching.
    @discardableResult
    func switchDisplay(_ displayUUID: String, toSpaceIndex targetIndex: Int, settleForLaunch: Bool = true) -> Bool {
        spaceLock.lock()
        defer { spaceLock.unlock() }

        let allDisplays = inspector.listDisplays()
        guard let initialDisplay = allDisplays.first(where: { $0.uuid == displayUUID }),
              targetIndex >= 0, targetIndex < initialDisplay.spaces.count else {
            SpaceBootLogger.log("switchDisplay invalid display=\(displayUUID) targetIndex=\(targetIndex)")
            return false
        }

        let targetSpace = initialDisplay.spaces[targetIndex]
        let targetSpaceId = targetSpace.id
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

        // Fast path: if the target is a Desktop Space and the user enabled "Switch to Desktop N", jump directly in 1 hop.
        if targetSpace.kind == .desktop,
           let globalIdx = globalDesktopIndex(displayUUID: displayUUID, spaceId: targetSpaceId, in: allDisplays),
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

        let maxSteps = initialDisplay.spaces.count + 2
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
              let index = display.spaces.firstIndex(where: { $0.id == spaceId }) else {
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
        guard let display = inspector.listDisplays().first(where: { d in spaceIds.contains(where: d.allSpaceIds.contains) }),
              let spaceId = spaceIds.first(where: display.allSpaceIds.contains) else {
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

    // MARK: - Fullscreen & Split View Control

    /// Transitions `windowId` into a solo native macOS Fullscreen Space on `displayUUID` and returns the new Space ID.
    func enterFullScreen(windowId: Int, pid: pid_t, onDisplay displayUUID: String) -> Int? {
        spaceLock.lock()
        defer { spaceLock.unlock() }
        guard AXIsProcessTrusted() else { return nil }

        if let existing = inspector.fullScreenSpace(hostingWindow: windowId) {
            if existing.display.uuid == displayUUID && existing.space.kind == .fullscreen {
                return existing.space.id
            }
            guard exitFullScreen(windowId: windowId, pid: pid) else { return nil }
        }

        if let display = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
           let win = inspector.listAllUserWindows().first(where: { $0.windowId == windowId }) {
            let onTargetDisplay = win.spaceIds.contains(where: display.desktopSpaceIds.contains)
            if !onTargetDisplay, let stagingId = display.desktopSpaceIds.last {
                let stageFrame = WindowRect(
                    x: Int(display.cgFrame.minX + 60),
                    y: Int(display.cgFrame.minY + 60),
                    width: min(win.frame.width, Int(max(500, display.cgFrame.width - 120))),
                    height: min(win.frame.height, Int(max(400, display.cgFrame.height - 120)))
                )
                guard relocateWindow(windowId: windowId, pid: pid, frame: stageFrame, targetDisplayUUID: displayUUID, targetSpaceId: stagingId) else {
                    return nil
                }
            }
        }

        _ = revealSpace(ofWindow: windowId)
        raiseWindow(windowId: windowId, pid: pid)
        usleep(140_000)

        guard let axWindow = findAXWindow(windowId: windowId, pid: pid) else {
            SpaceBootLogger.log("FullScreen: AXWindow not found for wid=\(windowId)")
            return nil
        }

        // Tier 1: set AXFullScreen = true directly.
        if AXUIElementSetAttributeValue(axWindow, "AXFullScreen" as CFString, kCFBooleanTrue) == .success {
            if let sid = waitForFullScreenSpace(windowId: windowId, onDisplay: displayUUID, timeout: 2.5) {
                usleep(450_000)
                SpaceBootLogger.log("FullScreen: wid=\(windowId) entered sp=\(sid) via AXFullScreen")
                return sid
            }
        }

        // Tier 2: press the green fullscreen button.
        if let fsButton = copyAXElementAttr(axWindow, kAXFullScreenButtonAttribute),
           AXUIElementPerformAction(fsButton, kAXPressAction as CFString) == .success {
            if let sid = waitForFullScreenSpace(windowId: windowId, onDisplay: displayUUID, timeout: 2.5) {
                usleep(450_000)
                SpaceBootLogger.log("FullScreen: wid=\(windowId) entered sp=\(sid) via AXFullScreenButton")
                return sid
            }
        }

        // Tier 3: press localized "Enter Full Screen" menu item in AXMenuBar.
        if triggerEnterFullScreenMenuItem(pid: pid) {
            if let sid = waitForFullScreenSpace(windowId: windowId, onDisplay: displayUUID, timeout: 3.0) {
                usleep(450_000)
                SpaceBootLogger.log("FullScreen: wid=\(windowId) entered sp=\(sid) via AXMenuBar")
                return sid
            }
        }

        SpaceBootLogger.log("FullScreen: failed to enter fullscreen for wid=\(windowId)")
        return nil
    }

    /// Exits native Fullscreen / Split View for `windowId` back onto a Desktop Space.
    @discardableResult
    func exitFullScreen(windowId: Int, pid: pid_t) -> Bool {
        spaceLock.lock()
        defer { spaceLock.unlock() }
        guard AXIsProcessTrusted() else { return false }

        guard inspector.fullScreenSpace(hostingWindow: windowId) != nil else { return true }
        _ = revealSpace(ofWindow: windowId)
        raiseWindow(windowId: windowId, pid: pid)
        usleep(150_000)

        guard let axWindow = findAXWindow(windowId: windowId, pid: pid) else { return false }

        if AXUIElementSetAttributeValue(axWindow, "AXFullScreen" as CFString, kCFBooleanFalse) == .success,
           waitForFullScreenExit(windowId: windowId, timeout: 3.5) {
            usleep(450_000)
            return true
        }
        if let fsButton = copyAXElementAttr(axWindow, kAXFullScreenButtonAttribute),
           AXUIElementPerformAction(fsButton, kAXPressAction as CFString) == .success,
           waitForFullScreenExit(windowId: windowId, timeout: 3.5) {
            usleep(450_000)
            return true
        }
        if triggerExitFullScreenMenuItem(pid: pid),
           waitForFullScreenExit(windowId: windowId, timeout: 3.5) {
            usleep(450_000)
            return true
        }
        return inspector.fullScreenSpace(hostingWindow: windowId) == nil
    }

    /// Pairs two windows into native macOS Fullscreen Split View on `displayUUID` and adjusts the vertical divider to `splitRatio`.
    func enterSplitView(
        leftWindowId: Int,
        leftPid: pid_t,
        rightWindowId: Int,
        rightPid: pid_t,
        onDisplay displayUUID: String,
        splitRatio: Double?
    ) -> Int? {
        spaceLock.lock()
        defer { spaceLock.unlock() }
        guard AXIsProcessTrusted() else { return nil }

        // Already paired in a Split View Space on the target display?
        if let existing = inspector.fullScreenSpace(hostingWindow: leftWindowId),
           existing.display.uuid == displayUUID,
           existing.space.kind == .split,
           existing.space.tiles.contains(where: { $0.windowId == rightWindowId }) {
            if let ratio = splitRatio {
                _ = adjustSplitDivider(spaceId: existing.space.id, onDisplay: displayUUID, targetRatio: ratio)
            }
            return existing.space.id
        }

        // Ensure neither window is locked inside a separate Fullscreen Space.
        if inspector.fullScreenSpace(hostingWindow: leftWindowId) != nil {
            guard exitFullScreen(windowId: leftWindowId, pid: leftPid) else { return nil }
        }
        if inspector.fullScreenSpace(hostingWindow: rightWindowId) != nil {
            guard exitFullScreen(windowId: rightWindowId, pid: rightPid) else { return nil }
        }

        guard let display = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
              let stagingDesktopId = (display.currentSpace?.kind == .desktop ? display.currentSpaceId : display.desktopSpaceIds.last) else {
            SpaceBootLogger.log("SplitView: no Desktop Space available on \(displayUUID) to stage split")
            return nil
        }

        let halfW = max(500, Int(display.cgFrame.width / 2) - 40)
        let stageH = max(400, Int(display.cgFrame.height) - 100)
        let leftStageFrame = WindowRect(x: Int(display.cgFrame.minX + 20), y: Int(display.cgFrame.minY + 40), width: halfW, height: stageH)
        let rightStageFrame = WindowRect(x: Int(display.cgFrame.minX) + halfW + 40, y: Int(display.cgFrame.minY + 40), width: halfW, height: stageH)

        if !inspector.spaceIds(forWindow: rightWindowId).contains(stagingDesktopId) {
            guard relocateWindow(windowId: rightWindowId, pid: rightPid, frame: rightStageFrame, targetDisplayUUID: displayUUID, targetSpaceId: stagingDesktopId) else {
                return nil
            }
        }
        if !inspector.spaceIds(forWindow: leftWindowId).contains(stagingDesktopId) {
            guard relocateWindow(windowId: leftWindowId, pid: leftPid, frame: leftStageFrame, targetDisplayUUID: displayUUID, targetSpaceId: stagingDesktopId) else {
                return nil
            }
        }

        guard ensureSpaceVisible(displayUUID: displayUUID, spaceId: stagingDesktopId) else { return nil }
        usleep(150_000)

        // Raise right window first, then left window so both sit together on the visible Desktop with left focused.
        raiseWindow(windowId: rightWindowId, pid: rightPid)
        usleep(120_000)
        raiseWindow(windowId: leftWindowId, pid: leftPid)
        usleep(180_000)

        guard triggerTileLeftFullScreen(windowId: leftWindowId, pid: leftPid) else {
            SpaceBootLogger.log("SplitView: failed to trigger Full Screen Tile Left on wid=\(leftWindowId)")
            return nil
        }

        // Wait for macOS to create the fullscreen tile space and show the Split View right-side picker.
        let pickerDeadline = Date().addingTimeInterval(SpaceBootConfig.splitPickerAppearTimeoutSeconds)
        var pickerSpace: (display: LiveDisplayInfo, space: LiveSpaceInfo)?
        while Date() < pickerDeadline {
            if let fs = inspector.fullScreenSpace(hostingWindow: leftWindowId), fs.display.uuid == displayUUID {
                if fs.space.kind == .split && fs.space.tiles.contains(where: { $0.windowId == rightWindowId }) {
                    if let ratio = splitRatio {
                        _ = adjustSplitDivider(spaceId: fs.space.id, onDisplay: displayUUID, targetRatio: ratio)
                    }
                    return fs.space.id
                }
                if let leftTile = fs.space.tiles.first(where: { $0.windowId == leftWindowId }),
                   Double(leftTile.tileRect.width) < fs.display.cgFrame.width * 0.85 {
                    pickerSpace = fs
                    break
                }
            }
            usleep(100_000)
        }

        guard let picker = pickerSpace,
              let leftTile = picker.space.tiles.first(where: { $0.windowId == leftWindowId }) else {
            SpaceBootLogger.log("SplitView: timed out waiting for Split View picker on wid=\(leftWindowId)")
            return nil
        }

        // Let the picker thumbnail animation finish before locating & clicking the right-hand candidate.
        usleep(450_000)
        let leftRightEdgeX = picker.display.cgFrame.minX + Double(leftTile.tileRect.x + leftTile.tileRect.width)

        for clickAttempt in 1...2 {
            var candidateBounds = inspector.onscreenWindowBounds(windowId: rightWindowId)
            if candidateBounds == nil || !picker.display.cgFrame.contains(CGPoint(x: candidateBounds!.midX, y: candidateBounds!.midY)) || candidateBounds!.midX <= leftRightEdgeX {
                usleep(250_000)
                candidateBounds = inspector.onscreenWindowBounds(windowId: rightWindowId)
            }

            guard let bounds = candidateBounds,
                  picker.display.cgFrame.contains(CGPoint(x: bounds.midX, y: bounds.midY)),
                  bounds.midX > leftRightEdgeX else {
                let dump = inspector.listOnscreenUserWindows()
                    .filter { picker.display.cgFrame.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                    .map { "wid=\($0.windowId)(\($0.appName)):\($0.rect)" }
                    .joined(separator: ", ")
                SpaceBootLogger.log("SplitPicker: wid=\(rightWindowId) not found in right half (leftEdge=\(Int(leftRightEdgeX)), bounds=\(String(describing: candidateBounds))). Onscreen: [\(dump)]")
                continue
            }

            let clickPt = CGPoint(x: bounds.midX, y: bounds.midY)
            SpaceBootLogger.log("SplitPicker: attempt \(clickAttempt) clicking wid=\(rightWindowId) at \(clickPt) (bounds=\(bounds))")
            clickPoint(clickPt)

            let pairDeadline = Date().addingTimeInterval(3.5)
            while Date() < pairDeadline {
                if let fs = inspector.fullScreenSpace(hostingWindow: leftWindowId),
                   fs.display.uuid == displayUUID,
                   fs.space.kind == .split,
                   fs.space.tiles.contains(where: { $0.windowId == rightWindowId }) {
                    usleep(500_000)
                    SpaceBootLogger.log("SplitView: paired wid=\(leftWindowId) + wid=\(rightWindowId) on sp=\(fs.space.id) (ratio=\(fs.space.splitRatio ?? -1))")
                    if let ratio = splitRatio {
                        _ = adjustSplitDivider(spaceId: fs.space.id, onDisplay: displayUUID, targetRatio: ratio)
                    }
                    return fs.space.id
                }
                usleep(120_000)
            }
        }

        // If still stuck in the Split View picker, press Escape so macOS exits picker cleanly.
        if let fs = inspector.fullScreenSpace(hostingWindow: leftWindowId),
           fs.space.kind == .fullscreen,
           let leftTile = fs.space.tiles.first(where: { $0.windowId == leftWindowId }),
           Double(leftTile.tileRect.width) < fs.display.cgFrame.width * 0.85 {
            postShortcut(KeyShortcut(keyCode: 53, flags: []))
            usleep(300_000)
        }
        SpaceBootLogger.log("SplitView: failed to pair wid=\(leftWindowId) + wid=\(rightWindowId)")
        return nil
    }

    /// Drags the Split View vertical divider bar to `targetRatio` (left tile width fraction).
    @discardableResult
    func adjustSplitDivider(spaceId: Int, onDisplay displayUUID: String, targetRatio rawTargetRatio: Double) -> Bool {
        spaceLock.lock()
        defer { spaceLock.unlock() }
        guard AXIsProcessTrusted() else { return false }

        let targetRatio = min(max(rawTargetRatio, 0.15), 0.85)
        guard let initialDisplay = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
              let initialSpace = initialDisplay.spaces.first(where: { $0.id == spaceId }),
              initialSpace.kind == .split,
              initialSpace.tiles.count >= 2,
              let initialRatio = initialSpace.splitRatio else {
            return false
        }

        if abs(initialRatio - targetRatio) <= SpaceBootConfig.splitRatioTolerance {
            return true
        }

        guard ensureSpaceVisible(displayUUID: displayUUID, spaceId: spaceId) else { return false }
        usleep(150_000)

        var previousAfterRatio: Double?
        for attempt in 1...2 {
            guard let liveDisplay = inspector.listDisplays().first(where: { $0.uuid == displayUUID }),
                  let liveSpace = liveDisplay.spaces.first(where: { $0.id == spaceId }),
                  liveSpace.kind == .split,
                  liveSpace.tiles.count >= 2,
                  let currentRatio = liveSpace.splitRatio else {
                return false
            }
            if abs(currentRatio - targetRatio) <= SpaceBootConfig.splitRatioTolerance {
                return true
            }

            let layoutRect = liveSpace.layoutRect ?? WindowRect(
                x: 0,
                y: 0,
                width: Int(liveDisplay.cgFrame.width),
                height: Int(liveDisplay.cgFrame.height)
            )
            let spacing = Double(liveSpace.interTileSpacing > 0 ? liveSpace.interTileSpacing : 12)
            let usableWidth = Double(layoutRect.width) - spacing
            let leftTile = liveSpace.tiles[0]

            let startX = liveDisplay.cgFrame.minX + Double(leftTile.tileRect.x + leftTile.tileRect.width) + spacing / 2.0
            let rawTargetX = liveDisplay.cgFrame.minX + Double(layoutRect.x) + usableWidth * targetRatio + spacing / 2.0
            let targetX = min(max(rawTargetX, liveDisplay.cgFrame.minX + 120), liveDisplay.cgFrame.maxX - 120)
            let midY = liveDisplay.cgFrame.minY + liveDisplay.cgFrame.height * 0.5

            dragMouse(from: CGPoint(x: startX, y: midY), to: CGPoint(x: targetX, y: midY))
            usleep(450_000)

            let afterRatio = inspector.listDisplays()
                .first(where: { $0.uuid == displayUUID })?
                .spaces.first(where: { $0.id == spaceId })?
                .splitRatio
            SpaceBootLogger.log("SplitDivider attempt \(attempt) sp=\(spaceId): \(currentRatio) -> \(afterRatio ?? -1) (want \(targetRatio))")

            if let after = afterRatio {
                if abs(after - targetRatio) <= SpaceBootConfig.splitRatioTolerance {
                    return true
                }
                if let prev = previousAfterRatio, abs(prev - after) < 0.002 {
                    SpaceBootLogger.log("SplitDivider clamped by OS/app at \(after) (want \(targetRatio))")
                    return true
                }
                previousAfterRatio = after
            }
        }
        return false
    }

    // MARK: - Private Helpers

    private func globalDesktopIndex(displayUUID: String, spaceId: Int, in displays: [LiveDisplayInfo]) -> Int? {
        var offset = 0
        for d in displays {
            if d.uuid == displayUUID {
                guard let localIdx = d.desktopSpaceIds.firstIndex(of: spaceId) else { return nil }
                return offset + localIdx
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

    private func copyAXElementAttr(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func waitForFullScreenSpace(windowId: Int, onDisplay displayUUID: String, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let fs = inspector.fullScreenSpace(hostingWindow: windowId),
               fs.display.uuid == displayUUID {
                return fs.space.id
            }
            usleep(100_000)
        }
        return nil
    }

    private func waitForFullScreenExit(windowId: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if inspector.fullScreenSpace(hostingWindow: windowId) == nil &&
               !inspector.spaceIds(forWindow: windowId).isEmpty {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    private func triggerEnterFullScreenMenuItem(pid: pid_t) -> Bool {
        let titles: Set<String> = [
            "enter full screen",
            "进入全屏幕",
            "進入全螢幕",
            "フルスクリーンにする",
            "vollbild ein",
            "activer le mode plein écran",
            "usar pantalla completa"
        ]
        return pressMatchingMenuItem(pid: pid) { title, _ in
            titles.contains(title)
        }
    }

    private func triggerExitFullScreenMenuItem(pid: pid_t) -> Bool {
        let titles: Set<String> = [
            "exit full screen",
            "退出全屏幕",
            "離開全螢幕",
            "フルスクリーンを解除",
            "vollbild aus",
            "quitter le mode plein écran",
            "salir de pantalla completa"
        ]
        return pressMatchingMenuItem(pid: pid) { title, _ in
            titles.contains(title)
        }
    }

    private func triggerTileLeftFullScreen(windowId: Int, pid: pid_t) -> Bool {
        // Tier 1: Search the app's AXMenuBar Window menu for macOS 14 ("Tile Window to Left of Screen")
        // or macOS 15+ ("Window -> Full Screen Tile -> Left of Screen").
        let pressedMenuBar = pressMatchingMenuItem(pid: pid) { title, parentTitle in
            isFullScreenLeftTileMenuItem(title: title, parentTitle: parentTitle)
        }
        if pressedMenuBar {
            return true
        }

        // Tier 2: AXShowMenu on the window's green AXFullScreenButton.
        guard let axWindow = findAXWindow(windowId: windowId, pid: pid),
              let fsButton = copyAXElementAttr(axWindow, kAXFullScreenButtonAttribute) else {
            return false
        }
        guard AXUIElementPerformAction(fsButton, kAXShowMenuAction as CFString) == .success else {
            return false
        }
        usleep(250_000)

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(fsButton, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let menus = childrenRef as? [AXUIElement] {
            for menu in menus {
                if searchAndPressMenu(menu, parentTitle: "", predicate: isFullScreenLeftTileMenuItem) {
                    return true
                }
            }
        }

        // Dismiss the green-button popup menu if nothing matched.
        postShortcut(KeyShortcut(keyCode: 53, flags: []))
        return false
    }

    private func isFullScreenLeftTileMenuItem(title: String, parentTitle: String) -> Bool {
        let legacyTitles: Set<String> = [
            "tile window to left of screen",
            "将窗口拼贴到屏幕左侧",
            "將視窗並排顯示於螢幕左側",
            "ウインドウを画面の左側にタイル表示",
            "fenster links auf dem bildschirm anordnen",
            "juxtaposer la fenêtre à gauche de l’écran",
            "colocar ventana a la izquierda de la pantalla"
        ]
        if legacyTitles.contains(title) {
            return true
        }
        if (title.contains("tile") || title.contains("拼贴") || title.contains("並排")) &&
           (title.contains("left") || title.contains("左")) {
            return true
        }

        // macOS 15+: Window -> Full Screen Tile -> Left of Screen (exclude Move & Resize -> Left).
        let isLeftOfScreen = [
            "left of screen",
            "屏幕左侧",
            "螢幕左側",
            "画面の左側",
            "linke bildschirmhälfte",
            "à gauche de l’écran",
            "izquierda de la pantalla"
        ].contains { title.contains($0) }

        let underFullScreenParent = [
            "full screen",
            "fullscreen",
            "全屏",
            "全螢幕",
            "フルスクリーン",
            "vollbild",
            "plein écran",
            "pantalla completa"
        ].contains { parentTitle.contains($0) }

        return isLeftOfScreen && underFullScreenParent
    }

    private func pressMatchingMenuItem(pid: pid_t, predicate: (String, String) -> Bool) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var mbRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &mbRef) == .success,
              let menuBar = mbRef else {
            return false
        }
        var topRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &topRef) == .success,
              let topItems = topRef as? [AXUIElement] else {
            return false
        }

        for topItem in topItems.dropFirst(2) {
            let topTitle = normalizeMenuTitle(copyStringAttr(topItem, kAXTitleAttribute) ?? "")
            var subRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(topItem, kAXChildrenAttribute as CFString, &subRef) == .success,
                  let subMenus = subRef as? [AXUIElement],
                  let menu = subMenus.first else {
                continue
            }
            if searchAndPressMenu(menu, parentTitle: topTitle, predicate: predicate) {
                return true
            }
        }
        return false
    }

    private func searchAndPressMenu(_ menu: AXUIElement, parentTitle: String, predicate: (String, String) -> Bool) -> Bool {
        var itemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
              let items = itemsRef as? [AXUIElement] else {
            return false
        }
        for item in items {
            let rawTitle = copyStringAttr(item, kAXTitleAttribute) ?? ""
            let normalized = normalizeMenuTitle(rawTitle)
            if !normalized.isEmpty && isAXElementEnabled(item) && predicate(normalized, parentTitle) {
                let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
                SpaceBootLogger.log("Menu AXPress '\(rawTitle)' (parent='\(parentTitle)') -> err=\(err.rawValue)")
                if err == .success {
                    return true
                }
            }
            var subRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &subRef) == .success,
               let subMenus = subRef as? [AXUIElement] {
                for subMenu in subMenus {
                    if searchAndPressMenu(subMenu, parentTitle: normalized.isEmpty ? parentTitle : normalized, predicate: predicate) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func normalizeMenuTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isAXElementEnabled(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &ref) == .success else {
            return true
        }
        return (ref as? Bool) ?? true
    }

    private func clickPoint(_ point: CGPoint) {
        moveMouse(to: point)
        usleep(80_000)
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
           let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
            usleep(40_000)
            up.post(tap: .cghidEventTap)
        }
    }

    private func dragMouse(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        moveMouse(to: start)
        usleep(80_000)

        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            return
        }
        down.post(tap: .cghidEventTap)
        usleep(120_000)

        let steps = 16
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let pt = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: pt, mouseButton: .left) {
                drag.post(tap: .cghidEventTap)
            }
            usleep(18_000)
        }

        usleep(100_000)
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
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
