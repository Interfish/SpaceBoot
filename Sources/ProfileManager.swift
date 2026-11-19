import Cocoa
import Foundation

enum ProfileActionError: LocalizedError {
    case skyLightUnavailable
    case missingAccessibility
    case missingDisplays([String])
    case insufficientSpaces([(displayName: String, current: Int, required: Int)])
    case spaceShortcutsDisabled

    var errorDescription: String? {
        switch self {
        case .skyLightUnavailable:
            return "Unable to query macOS Spaces metadata (SkyLight API unavailable)."
        case .missingAccessibility:
            return "Grant Accessibility permission to SpaceBoot in System Settings → Privacy & Security → Accessibility (or Device Control & Data Access)."
        case .missingDisplays(let names):
            return "Required display(s) not connected: \(names.joined(separator: ", "))."
        case .insufficientSpaces(let items):
            let details = items.map { "\($0.displayName): has \($0.current) desktop(s), profile requires \($0.required)" }
            return "Not enough Desktop Spaces:\n" + details.joined(separator: "\n") + "\n\nAdd the missing Desktop Spaces in Mission Control and try again."
        case .spaceShortcutsDisabled:
            return "Mission Control Space-switching shortcuts are disabled. Enable \"Move left a space\" / \"Move right a space\" (or \"Switch to Desktop N\") in System Settings → Keyboard Shortcuts → Mission Control."
        }
    }
}

private struct PendingLateWindow {
    let appId: String
    let appName: String
    let savedWindow: WindowRecord
    let targetSpaceId: Int
    let existingIdsAtLaunch: Set<Int>
}

private final class SettleGuardEntry {
    var windowId: Int
    var pid: pid_t
    let appId: String
    let appName: String
    var expectedFrame: WindowRect
    let targetDisplayUUID: String
    let targetSpaceId: Int

    init(
        windowId: Int,
        pid: pid_t,
        appId: String,
        appName: String,
        expectedFrame: WindowRect,
        targetDisplayUUID: String,
        targetSpaceId: Int
    ) {
        self.windowId = windowId
        self.pid = pid
        self.appId = appId
        self.appName = appName
        self.expectedFrame = expectedFrame
        self.targetDisplayUUID = targetDisplayUUID
        self.targetSpaceId = targetSpaceId
    }
}

private final class ParallelLaunchSlot {
    let savedIndex: Int
    let savedWindow: WindowRecord
    var deadline: Date
    var extendedForProcess = false
    var sawSplash = false
    var resolvedWindow: LiveWindowInfo?

    init(savedIndex: Int, savedWindow: WindowRecord, initialDeadline: Date) {
        self.savedIndex = savedIndex
        self.savedWindow = savedWindow
        self.deadline = initialDeadline
    }
}

/// Handles profile persistence, instant multi-Space recording, pipelined parallel launching,
/// and post-boot settle guards for apps that reposition themselves asynchronously after startup.
final class ProfileManager {
    private let inspector: SpaceInspector
    private let controller: WindowController
    private let launcher = AppLauncher()

    init(inspector: SpaceInspector, controller: WindowController) {
        self.inspector = inspector
        self.controller = controller
    }

    // MARK: - Persistence

    func listProfiles() -> [SpaceBootProfile] {
        ensureProfilesDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: SpaceBootConfig.profilesDirectory)) ?? []
        return files
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { loadProfile(named: $0.replacingOccurrences(of: ".json", with: "")) }
    }

    func profileURL(named name: String) -> URL {
        URL(fileURLWithPath: SpaceBootConfig.profilesDirectory)
            .appendingPathComponent("\(sanitizedFileName(name)).json")
    }

    func loadProfile(named name: String) -> SpaceBootProfile? {
        guard let data = try? Data(contentsOf: profileURL(named: name)) else { return nil }
        return try? JSONDecoder().decode(SpaceBootProfile.self, from: data)
    }

    func saveProfile(_ profile: SpaceBootProfile) throws {
        ensureProfilesDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: profileURL(named: profile.name))
    }

    func deleteProfile(named name: String) throws {
        let url = profileURL(named: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Record (Zero-Switch Snapshot of All Displays & Spaces)

    func recordProfile(named name: String) throws -> SpaceBootProfile {
        guard inspector.isAvailable else { throw ProfileActionError.skyLightUnavailable }

        SpaceBootLogger.log("=== RECORD START profile=\(name) axTrusted=\(AXIsProcessTrusted()) ===")
        let existingProfile = loadProfile(named: name)
        let liveDisplays = inspector.listDisplays()
        let allWindows = inspector.listAllUserWindows()

        var spaceLookup: [Int: (displayIdx: Int, spaceIdx: Int)] = [:]
        for (dIdx, display) in liveDisplays.enumerated() {
            for (sIdx, spaceId) in display.desktopSpaceIds.enumerated() {
                spaceLookup[spaceId] = (dIdx, sIdx)
            }
        }

        var buckets: [[Int: [LiveWindowInfo]]] = Array(repeating: [:], count: liveDisplays.count)
        for win in allWindows {
            guard let matchedSpace = win.spaceIds.compactMap({ spaceLookup[$0] }).first else {
                continue
            }
            guard controller.isRecordableWindow(win) else {
                continue
            }
            buckets[matchedSpace.displayIdx][matchedSpace.spaceIdx, default: []].append(win)
        }

        var displayLayouts: [DisplayLayout] = []
        for (dIdx, display) in liveDisplays.enumerated() {
            let priorDisplay = existingProfile?.displays.first(where: {
                $0.displayUUID == display.uuid || $0.displayName == display.name
            })

            var spaceLayouts: [SpaceLayout] = []
            var remappedActiveSpaceIndex = 0
            let liveActiveIndex = display.currentSpaceIndex ?? 0

            for sIdx in 0..<display.desktopSpaceIds.count {
                let rawWins = buckets[dIdx][sIdx] ?? []
                // Skip empty Spaces so recorded profiles never require blank placeholder desktops.
                guard !rawWins.isEmpty else { continue }

                let compactedIdx = spaceLayouts.count
                if sIdx == liveActiveIndex {
                    remappedActiveSpaceIndex = compactedIdx
                }

                let priorSpace = priorDisplay?.spaces.first(where: { $0.spaceIndex == compactedIdx })
                    ?? priorDisplay?.spaces.first(where: { $0.spaceIndex == sIdx })
                var usedPriorIndices: Set<Int> = []

                let records: [WindowRecord] = rawWins.enumerated().map { zIdx, win in
                    let axTitle = controller.inspectAXWindow(windowId: win.windowId, pid: win.pid)?.title ?? ""
                    let effectiveTitle = axTitle.isEmpty ? win.title : axTitle
                    let enrichedWin = LiveWindowInfo(
                        windowId: win.windowId, pid: win.pid, appId: win.appId, appName: win.appName,
                        title: effectiveTitle, frame: win.frame, spaceIds: win.spaceIds, zIndex: win.zIndex,
                        isOnscreen: win.isOnscreen
                    )
                    let priorWin = findPriorWindow(
                        for: enrichedWin,
                        in: priorSpace?.windows ?? [],
                        usedIndices: &usedPriorIndices
                    )
                    return WindowRecord(
                        appId: win.appId,
                        appName: win.appName,
                        titleHint: priorWin?.titleHint ?? inferTitleHint(title: effectiveTitle),
                        frame: win.frame,
                        zIndex: zIdx,
                        launch: priorWin?.launch ?? defaultLaunchConfig(for: win)
                    )
                }

                spaceLayouts.append(SpaceLayout(spaceIndex: compactedIdx, windows: records))
            }

            displayLayouts.append(DisplayLayout(
                displayUUID: display.uuid,
                displayName: display.name,
                spaceCount: spaceLayouts.count,
                activeSpaceIndex: remappedActiveSpaceIndex,
                spaces: spaceLayouts
            ))
        }

        let formatter = ISO8601DateFormatter()
        let profile = SpaceBootProfile(
            name: name,
            updatedAt: formatter.string(from: Date()),
            displays: displayLayouts
        )
        try saveProfile(profile)
        SpaceBootLogger.log("=== RECORD DONE profile=\(name) totalWindows=\(profile.totalWindowCount) ===")
        return profile
    }

    // MARK: - Diagnostics

    func dumpDiagnostics() {
        SpaceBootLogger.log("=== INSPECT axTrusted=\(AXIsProcessTrusted()) ===")
        let displays = inspector.listDisplays()
        for d in displays {
            SpaceBootLogger.log("Display \(d.name) uuid=\(d.uuid) cgFrame=\(d.cgFrame) spaces=\(d.desktopSpaceIds) current=\(d.currentSpaceId)")
        }
        for w in inspector.listAllUserWindows() {
            let meta = controller.inspectAXWindow(windowId: w.windowId, pid: w.pid)
            let metaDesc = meta.map { "role=\($0.role) subrole=\($0.subrole) resizable=\($0.isSizeSettable) title='\($0.title.prefix(30))'" } ?? "ax=unavailable"
            SpaceBootLogger.log("  wid=\(w.windowId) \(w.appId) (\(w.appName)) sp=\(w.spaceIds) frame=\(w.frame) \(metaDesc)")
        }
    }

    // MARK: - Boot & Restore (Pipelined Parallel Launch + Post-Boot Settle Guard)

    func applyProfile(_ profile: SpaceBootProfile, launchMissing: Bool) throws -> (matched: Int, total: Int) {
        guard inspector.isAvailable else { throw ProfileActionError.skyLightUnavailable }
        guard AXIsProcessTrusted() else { throw ProfileActionError.missingAccessibility }

        SpaceBootLogger.log("=== APPLY START profile=\(profile.name) launchMissing=\(launchMissing) ===")
        let liveDisplays = inspector.listDisplays()

        var displayPairs: [(saved: DisplayLayout, live: LiveDisplayInfo)] = []
        var missingDisplayNames: [String] = []
        for savedDisplay in profile.displays {
            if let live = inspector.matchLiveDisplay(for: savedDisplay, in: liveDisplays) {
                displayPairs.append((savedDisplay, live))
            } else {
                missingDisplayNames.append(savedDisplay.displayName)
            }
        }
        if !missingDisplayNames.isEmpty {
            throw ProfileActionError.missingDisplays(missingDisplayNames)
        }

        var insufficient: [(String, Int, Int)] = []
        for pair in displayPairs {
            let required = pair.saved.requiredSpaceCount
            if pair.live.desktopSpaceIds.count < required {
                insufficient.append((pair.saved.displayName, pair.live.desktopSpaceIds.count, required))
            }
        }
        if !insufficient.isEmpty {
            throw ProfileActionError.insufficientSpaces(insufficient)
        }

        let needsSpaceSwitch = displayPairs.contains { pair in
            pair.saved.spaces.filter { !$0.windows.isEmpty }.count > 1 ||
            pair.saved.spaces.contains { !$0.windows.isEmpty && $0.spaceIndex != (pair.live.currentSpaceIndex ?? -1) }
        }
        if needsSpaceSwitch {
            let hotKeys = SymbolicHotKeys()
            let hasStepShortcuts = hotKeys.moveLeftShortcut() != nil && hotKeys.moveRightShortcut() != nil
            let hasAnyDirect = (0..<16).contains { hotKeys.directDesktopShortcut(globalIndex: $0) != nil }
            if !hasStepShortcuts && !hasAnyDirect {
                throw ProfileActionError.spaceShortcutsDisabled
            }
        }

        var claimedWindowIds = preClaimCorrectlyPlacedWindows(displayPairs: displayPairs)
        let neededBySpaceAndApp = buildNeededWindowCounts(displayPairs: displayPairs)
        var matchedCount = 0
        let totalCount = profile.totalWindowCount
        var pendingLateWindows: [PendingLateWindow] = []
        var settleGuardEntries: [SettleGuardEntry] = []

        for pair in displayPairs {
            let liveUUID = pair.live.uuid

            // Process activeSpaceIndex LAST so the display naturally finishes on the user's active Space.
            let nonEmptySpaces = pair.saved.spaces.filter { !$0.windows.isEmpty }
            let orderedSpaces = nonEmptySpaces.sorted { lhs, rhs in
                if lhs.spaceIndex == pair.saved.activeSpaceIndex { return false }
                if rhs.spaceIndex == pair.saved.activeSpaceIndex { return true }
                return lhs.spaceIndex < rhs.spaceIndex
            }

            for savedSpace in orderedSpaces {
                guard controller.switchDisplay(liveUUID, toSpaceIndex: savedSpace.spaceIndex) else {
                    SpaceBootLogger.log("Skipping \(pair.saved.displayName) space[\(savedSpace.spaceIndex)]: switchDisplay failed")
                    continue
                }

                guard let currentDisplay = inspector.listDisplays().first(where: { $0.uuid == liveUUID }),
                      savedSpace.spaceIndex < currentDisplay.desktopSpaceIds.count else { continue }
                let targetSpaceId = currentDisplay.desktopSpaceIds[savedSpace.spaceIndex]
                let visibleSpaceIds = Set(inspector.listDisplays().map { $0.currentSpaceId })

                let allLive = inspector.listAllUserWindows()
                let windowsOnSpace = allLive.filter { $0.spaceIds.contains(targetSpaceId) }
                var assignments = matchWindowsOnSpace(saved: savedSpace.windows, live: windowsOnSpace)
                for win in assignments.values { claimedWindowIds.insert(win.windowId) }

                // Borrow only SURPLUS unclaimed windows of the same app sitting on another currently-visible Space.
                for (idx, savedWin) in savedSpace.windows.enumerated() where assignments[idx] == nil {
                    if let stray = allLive.first(where: { win in
                        guard !claimedWindowIds.contains(win.windowId),
                              win.appId == savedWin.appId,
                              let winSpace = win.spaceIds.first(where: { visibleSpaceIds.contains($0) }),
                              winSpace != targetSpaceId else { return false }

                        let currentCountOnWinSpace = allLive.filter {
                            $0.appId == win.appId && $0.spaceIds.contains(winSpace)
                        }.count
                        let neededOnWinSpace = neededBySpaceAndApp["\(winSpace):\(win.appId)"] ?? 0
                        guard currentCountOnWinSpace > neededOnWinSpace else { return false }

                        return controller.isLikelyMainWindow(win, expectedFrame: savedWin.frame, requireAXMetadata: true)
                    }) {
                        SpaceBootLogger.log("Borrowing surplus visible window wid=\(stray.windowId) (\(stray.appName)) from sp=\(stray.spaceIds) -> \(pair.saved.displayName) sp=\(targetSpaceId)")
                        assignments[idx] = stray
                        claimedWindowIds.insert(stray.windowId)
                    }
                }

                // Launch all missing windows in this Space using staggered parallel waves (place each as soon as ready).
                if launchMissing {
                    let missingIndices = savedSpace.windows.indices.filter {
                        assignments[$0] == nil && savedSpace.windows[$0].launch != nil
                    }
                    let launchedResult = launchMissingInParallelWaves(
                        missingIndices: missingIndices,
                        savedWindows: savedSpace.windows,
                        displayName: pair.saved.displayName,
                        displayUUID: liveUUID,
                        spaceIndex: savedSpace.spaceIndex,
                        targetSpaceId: targetSpaceId,
                        claimedWindowIds: &claimedWindowIds
                    )
                    for (idx, win) in launchedResult.resolved {
                        assignments[idx] = win
                        settleGuardEntries.append(SettleGuardEntry(
                            windowId: win.windowId,
                            pid: win.pid,
                            appId: savedSpace.windows[idx].appId,
                            appName: savedSpace.windows[idx].appName,
                            expectedFrame: savedSpace.windows[idx].frame,
                            targetDisplayUUID: liveUUID,
                            targetSpaceId: targetSpaceId
                        ))
                    }
                    pendingLateWindows.append(contentsOf: launchedResult.timedOut)
                }

                // Final verified frame placement for every matched window on this Space.
                var placed: [(saved: WindowRecord, live: LiveWindowInfo)] = []
                for (idx, savedWin) in savedSpace.windows.enumerated() {
                    guard let liveWin = assignments[idx] else { continue }
                    _ = controller.setWindowFrameVerified(
                        windowId: liveWin.windowId,
                        pid: liveWin.pid,
                        frame: savedWin.frame,
                        targetSpaceId: targetSpaceId
                    )
                    placed.append((savedWin, liveWin))
                    matchedCount += 1
                }

                // Restore exact stacking order: bottom-most (largest zIndex) first, top-most (0) last.
                for item in placed.sorted(by: { $0.saved.zIndex > $1.saved.zIndex }) {
                    controller.raiseWindow(windowId: item.live.windowId, pid: item.live.pid)
                    usleep(SpaceBootConfig.raiseWindowDelayMicros)
                }
            }

            if pair.saved.requiredSpaceCount > 0 {
                let finalIndex = min(pair.saved.activeSpaceIndex, max(0, pair.live.desktopSpaceIds.count - 1))
                _ = controller.switchDisplay(liveUUID, toSpaceIndex: finalIndex)
            }
        }

        // Background watchers: catch late-auth apps AND re-snap apps (e.g., Electron) that call window.center() after boot.
        if !pendingLateWindows.isEmpty {
            watchPendingLateWindows(pendingLateWindows)
        }
        if !settleGuardEntries.isEmpty {
            startPostBootSettleGuard(entries: settleGuardEntries, knownWindowIds: claimedWindowIds)
        }

        SpaceBootLogger.log("=== APPLY DONE profile=\(profile.name) matched=\(matchedCount)/\(totalCount) pendingLate=\(pendingLateWindows.count) settleGuarded=\(settleGuardEntries.count) ===")
        return (matchedCount, totalCount)
    }

    // MARK: - Parallel Pipelined Launching (Per Space)

    /// Splits missing windows on a Space into parallel waves (at most 1 launch per distinct appId per wave),
    /// fires launches staggered by ~0.4s, and snaps each window into place the moment it becomes ready.
    private func launchMissingInParallelWaves(
        missingIndices: [Int],
        savedWindows: [WindowRecord],
        displayName: String,
        displayUUID: String,
        spaceIndex: Int,
        targetSpaceId: Int,
        claimedWindowIds: inout Set<Int>
    ) -> (resolved: [Int: LiveWindowInfo], timedOut: [PendingLateWindow]) {
        var remainingIndices = missingIndices
        var resolvedAll: [Int: LiveWindowInfo] = [:]
        var timedOutAll: [PendingLateWindow] = []

        while !remainingIndices.isEmpty {
            // Pick at most one pending entry per distinct appId for this parallel wave so new windows map unambiguously.
            var waveIndices: [Int] = []
            var seenAppIds: Set<String> = []
            var nextWaveIndices: [Int] = []

            for idx in remainingIndices {
                let appId = savedWindows[idx].appId
                if seenAppIds.insert(appId).inserted {
                    waveIndices.append(idx)
                } else {
                    nextWaveIndices.append(idx)
                }
            }
            remainingIndices = nextWaveIndices

            let baselineSnapshot = inspector.listAllUserWindows()
            let baselineIds = Set(baselineSnapshot.map { $0.windowId })
            var activeSlots: [ParallelLaunchSlot] = []

            // Stagger-fire all launches in this parallel wave (~0.4s apart).
            for (wavePos, idx) in waveIndices.enumerated() {
                let savedWin = savedWindows[idx]
                guard let launch = savedWin.launch else { continue }
                let appHasWindow = baselineSnapshot.contains { $0.appId == savedWin.appId }

                if wavePos > 0 {
                    usleep(SpaceBootConfig.parallelLaunchStaggerMicros)
                }

                SpaceBootLogger.log("Parallel launch [\(wavePos + 1)/\(waveIndices.count)] \(savedWin.appName) (kind=\(launch.kind), hasWindow=\(appHasWindow)) for \(displayName) space[\(spaceIndex)]")
                let outcome = launcher.launchWindow(
                    appId: savedWin.appId,
                    spec: launch,
                    appAlreadyHasWindow: appHasWindow
                )

                switch outcome {
                case .triggered:
                    let slot = ParallelLaunchSlot(
                        savedIndex: idx,
                        savedWindow: savedWin,
                        initialDeadline: Date().addingTimeInterval(SpaceBootConfig.launchWindowTimeoutSeconds)
                    )
                    activeSlots.append(slot)
                case .singleWindowAlreadyOpen:
                    break
                case .failed(let reason):
                    SpaceBootLogger.log("Launch failed for \(savedWin.appName): \(reason)")
                }
            }

            // Unified ready-poll loop: position each window immediately as soon as its main AXStandardWindow appears.
            var waveClaimedIds = baselineIds.union(claimedWindowIds)
            while activeSlots.contains(where: { $0.resolvedWindow == nil && Date() < $0.deadline }) {
                usleep(SpaceBootConfig.launchPollMicros)
                let liveNow = inspector.listAllUserWindows()

                for slot in activeSlots where slot.resolvedWindow == nil && Date() < slot.deadline {
                    let appId = slot.savedWindow.appId
                    let candidates = liveNow.filter {
                        $0.appId == appId && !waveClaimedIds.contains($0.windowId)
                    }

                    if let mainWin = candidates.first(where: {
                        controller.isLikelyMainWindow($0, expectedFrame: slot.savedWindow.frame, requireAXMetadata: true)
                    }) {
                        usleep(300_000)
                        let refreshed = inspector.listAllUserWindows().first(where: { $0.windowId == mainWin.windowId }) ?? mainWin
                        slot.resolvedWindow = refreshed
                        waveClaimedIds.insert(refreshed.windowId)
                        claimedWindowIds.insert(refreshed.windowId)

                        SpaceBootLogger.log("Ready -> placing wid=\(refreshed.windowId) (\(slot.savedWindow.appName)) onto \(displayName) space[\(spaceIndex)]")
                        _ = controller.setWindowFrameVerified(
                            windowId: refreshed.windowId,
                            pid: refreshed.pid,
                            frame: slot.savedWindow.frame,
                            targetSpaceId: targetSpaceId
                        )

                        // Guard against apps whose splash-transition window closes right after spawning.
                        if slot.sawSplash,
                           let replaced = watchForWindowReplacement(
                               original: refreshed,
                               expectedFrame: slot.savedWindow.frame,
                               excluding: waveClaimedIds
                           ) {
                            SpaceBootLogger.log("Detected replacement window wid=\(replaced.windowId) for \(slot.savedWindow.appName)")
                            slot.resolvedWindow = replaced
                            waveClaimedIds.insert(replaced.windowId)
                            claimedWindowIds.insert(replaced.windowId)
                        }
                        continue
                    }

                    if !slot.sawSplash && !candidates.isEmpty {
                        slot.sawSplash = true
                        slot.deadline = max(slot.deadline, Date().addingTimeInterval(SpaceBootConfig.splashExtendedTimeoutSeconds))
                        SpaceBootLogger.log("Detected splash/loading window for \(appId); extending wait to \(Int(SpaceBootConfig.splashExtendedTimeoutSeconds))s")
                    } else if !slot.extendedForProcess && !NSRunningApplication.runningApplications(withBundleIdentifier: appId).isEmpty {
                        slot.extendedForProcess = true
                        slot.deadline = max(slot.deadline, Date().addingTimeInterval(SpaceBootConfig.processInitTimeoutSeconds))
                        SpaceBootLogger.log("App \(appId) process started; waiting up to \(Int(SpaceBootConfig.processInitTimeoutSeconds))s for main window")
                    }
                }
            }

            // Collect resolved & timed-out slots from this wave.
            for slot in activeSlots {
                if let win = slot.resolvedWindow {
                    resolvedAll[slot.savedIndex] = win
                } else {
                    SpaceBootLogger.log("Timed out waiting for main window of \(slot.savedWindow.appName); queuing late-arrival watcher")
                    timedOutAll.append(PendingLateWindow(
                        appId: slot.savedWindow.appId,
                        appName: slot.savedWindow.appName,
                        savedWindow: slot.savedWindow,
                        targetSpaceId: targetSpaceId,
                        existingIdsAtLaunch: baselineIds
                    ))
                }
            }
        }

        return (resolvedAll, timedOutAll)
    }

    // MARK: - Post-Boot Settle Guard (Catches Electron win.center() After Startup)

    /// Watches newly launched windows for ~15s after boot finishes.
    /// Handles BOTH:
    /// 1. Apps that asynchronously reposition themselves (e.g. Electron calling BrowserWindow.center()).
    /// 2. Apps that close their initial startup window and spawn a brand-new main window ID a few seconds later.
    private func startPostBootSettleGuard(entries: [SettleGuardEntry], knownWindowIds: Set<Int>) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var trackedIds = knownWindowIds
            let deadline = Date().addingTimeInterval(SpaceBootConfig.postBootSettleGuardSeconds)

            while Date() < deadline {
                usleep(SpaceBootConfig.postBootSettlePollMicros)
                let displays = self.inspector.listDisplays()
                let activeSpaceByDisplay = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.currentSpaceId) })
                let visibleSpaces = Set(displays.map { $0.currentSpaceId })
                let liveWindows = self.inspector.listAllUserWindows()

                for entry in entries {
                    // Only re-snap when the entry's target Space is currently active on its target display.
                    guard activeSpaceByDisplay[entry.targetDisplayUUID] == entry.targetSpaceId else {
                        continue
                    }

                    // Case A: Original window ID is still alive — check for async drift.
                    // Prefer AX logical bounds over CG bounds so Mission Control thumbnail scaling never causes false drift.
                    if let live = liveWindows.first(where: { $0.windowId == entry.windowId }) {
                        let logicalFrame = self.controller.readAXWindowFrame(windowId: entry.windowId, pid: entry.pid) ?? live.frame
                        let frameOk = logicalFrame.isApproximatelyEqual(
                            to: entry.expectedFrame,
                            tolerance: SpaceBootConfig.frameVerifyTolerancePx
                        )
                        let spaceOk = live.spaceIds.contains(entry.targetSpaceId)

                        if !frameOk || !spaceOk {
                            SpaceBootLogger.log("SettleGuard drift on wid=\(entry.windowId) (\(entry.appName)): got \(logicalFrame) sp=\(live.spaceIds), restoring -> \(entry.expectedFrame) sp=\(entry.targetSpaceId)")
                            _ = self.controller.setWindowFrameVerified(
                                windowId: entry.windowId,
                                pid: entry.pid,
                                frame: entry.expectedFrame,
                                targetSpaceId: entry.targetSpaceId
                            )
                            // If OS/app clamped height/width while staying at the right Space & origin, update expectedFrame
                            // to avoid re-fighting Dock/min-size constraints on subsequent ticks.
                            if let after = self.inspector.listAllUserWindows().first(where: { $0.windowId == entry.windowId }),
                               after.spaceIds.contains(entry.targetSpaceId),
                               abs(after.frame.x - entry.expectedFrame.x) <= SpaceBootConfig.frameVerifyTolerancePx,
                               abs(after.frame.y - entry.expectedFrame.y) <= SpaceBootConfig.frameVerifyTolerancePx {
                                entry.expectedFrame = after.frame
                            }
                        }
                        continue
                    }

                    // Case B: Original startup window disappeared and app spawned a brand-new replacement window ID
                    // (common in Electron/desktop apps whose preloader window closes and opens the real main window).
                    if let replacement = liveWindows.first(where: { win in
                        !trackedIds.contains(win.windowId) &&
                        win.appId == entry.appId &&
                        win.spaceIds.contains(where: { visibleSpaces.contains($0) }) &&
                        self.controller.isLikelyMainWindow(win, expectedFrame: entry.expectedFrame, requireAXMetadata: true)
                    }) {
                        SpaceBootLogger.log("SettleGuard adopted replacement wid=\(replacement.windowId) (replacing wid=\(entry.windowId)) for \(entry.appName); moving from \(replacement.frame) sp=\(replacement.spaceIds) -> \(entry.expectedFrame) sp=\(entry.targetSpaceId)")
                        entry.windowId = replacement.windowId
                        entry.pid = replacement.pid
                        trackedIds.insert(replacement.windowId)
                        _ = self.controller.setWindowFrameVerified(
                            windowId: replacement.windowId,
                            pid: replacement.pid,
                            frame: entry.expectedFrame,
                            targetSpaceId: entry.targetSpaceId
                        )
                        self.controller.raiseWindow(windowId: replacement.windowId, pid: replacement.pid)
                    }
                }
            }
            SpaceBootLogger.log("SettleGuard completed \(Int(SpaceBootConfig.postBootSettleGuardSeconds))s watch for \(entries.count) window(s)")
        }
    }

    // MARK: - Private Helpers

    /// Determines a generic launch config purely from standard macOS bundle location (zero vendor hardcoding).
    private func defaultLaunchConfig(for win: LiveWindowInfo) -> LaunchConfig? {
        if let app = NSRunningApplication(processIdentifier: win.pid),
           let bundleURL = app.bundleURL {
            guard SpaceBootConfig.isStandaloneApplicationPath(bundleURL.path) else {
                SpaceBootLogger.log("Record: skipping standalone launch for host-managed bundle \(bundleURL.path)")
                return nil
            }
            return LaunchConfig(kind: "app", target: bundleURL.path, url: nil)
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: win.appId) {
            guard SpaceBootConfig.isStandaloneApplicationPath(appURL.path) else {
                return nil
            }
            return LaunchConfig(kind: "app", target: appURL.path, url: nil)
        }
        return nil
    }

    private func buildNeededWindowCounts(displayPairs: [(saved: DisplayLayout, live: LiveDisplayInfo)]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for pair in displayPairs {
            for savedSpace in pair.saved.spaces {
                guard savedSpace.spaceIndex < pair.live.desktopSpaceIds.count else { continue }
                let spaceId = pair.live.desktopSpaceIds[savedSpace.spaceIndex]
                for win in savedSpace.windows {
                    let key = "\(spaceId):\(win.appId)"
                    counts[key, default: 0] += 1
                }
            }
        }
        return counts
    }

    private func preClaimCorrectlyPlacedWindows(displayPairs: [(saved: DisplayLayout, live: LiveDisplayInfo)]) -> Set<Int> {
        var claimed: Set<Int> = []
        let allLive = inspector.listAllUserWindows()

        for pair in displayPairs {
            for savedSpace in pair.saved.spaces {
                guard savedSpace.spaceIndex < pair.live.desktopSpaceIds.count else { continue }
                let spaceId = pair.live.desktopSpaceIds[savedSpace.spaceIndex]
                let winsOnSpace = allLive.filter { $0.spaceIds.contains(spaceId) }
                let matched = matchWindowsOnSpace(saved: savedSpace.windows, live: winsOnSpace)
                for win in matched.values {
                    claimed.insert(win.windowId)
                }
            }
        }
        return claimed
    }

    private func watchForWindowReplacement(
        original: LiveWindowInfo,
        expectedFrame: WindowRect,
        excluding existingIds: Set<Int>
    ) -> LiveWindowInfo? {
        usleep(SpaceBootConfig.replacementWatchDelayMicros)
        let current = inspector.listAllUserWindows()
        if current.contains(where: { $0.windowId == original.windowId }) {
            return nil
        }

        var excluded = existingIds
        excluded.insert(original.windowId)
        let deadline = Date().addingTimeInterval(SpaceBootConfig.launchWindowTimeoutSeconds)
        while Date() < deadline {
            usleep(SpaceBootConfig.launchPollMicros)
            if let found = inspector.listAllUserWindows().first(where: {
                $0.appId == original.appId &&
                !excluded.contains($0.windowId) &&
                controller.isLikelyMainWindow($0, expectedFrame: expectedFrame, requireAXMetadata: true)
            }) {
                return found
            }
        }
        return nil
    }

    private func watchPendingLateWindows(_ pendingList: [PendingLateWindow]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var remaining = pendingList
            let deadline = Date().addingTimeInterval(SpaceBootConfig.lateArrivalWatchSeconds)

            while !remaining.isEmpty && Date() < deadline {
                usleep(500_000)
                let live = self.inspector.listAllUserWindows()
                remaining.removeAll { item in
                    guard let found = live.first(where: {
                        $0.appId == item.appId &&
                        !item.existingIdsAtLaunch.contains($0.windowId) &&
                        self.controller.isLikelyMainWindow(
                            $0,
                            expectedFrame: item.savedWindow.frame,
                            requireAXMetadata: true
                        )
                    }) else {
                        return false
                    }
                    SpaceBootLogger.log("Late-arrival watcher caught wid=\(found.windowId) (\(item.appName)); snapping to \(item.savedWindow.frame)")
                    usleep(400_000)
                    let ok = self.controller.setWindowFrameVerified(
                        windowId: found.windowId,
                        pid: found.pid,
                        frame: item.savedWindow.frame,
                        targetSpaceId: item.targetSpaceId
                    )
                    if !ok {
                        SpaceBootLogger.log("Late-arrival snap did not converge for wid=\(found.windowId) (\(item.appName)); continuing watch")
                    }
                    return ok
                }
            }
        }
    }

    private func ensureProfilesDirectory() {
        try? FileManager.default.createDirectory(
            atPath: SpaceBootConfig.profilesDirectory,
            withIntermediateDirectories: true
        )
    }

    private func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "default" : cleaned
    }

    private func findPriorWindow(
        for win: LiveWindowInfo,
        in priorList: [WindowRecord],
        usedIndices: inout Set<Int>
    ) -> WindowRecord? {
        if let idx = priorList.indices.first(where: { i in
            guard !usedIndices.contains(i), priorList[i].appId == win.appId else { return false }
            if let hint = priorList[i].titleHint, !hint.isEmpty {
                return win.title.localizedCaseInsensitiveContains(hint)
            }
            return false
        }) {
            usedIndices.insert(idx)
            return priorList[idx]
        }

        if let idx = priorList.indices.first(where: { !usedIndices.contains($0) && priorList[$0].appId == win.appId }) {
            usedIndices.insert(idx)
            return priorList[idx]
        }
        return nil
    }

    private func inferTitleHint(title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(40))
    }

    private func matchWindowsOnSpace(saved: [WindowRecord], live: [LiveWindowInfo]) -> [Int: LiveWindowInfo] {
        var matched: [Int: LiveWindowInfo] = [:]
        var usedIds: Set<Int> = []

        for (idx, s) in saved.enumerated() {
            guard let hint = s.titleHint, !hint.isEmpty else { continue }
            if let found = live.first(where: { win in
                guard !usedIds.contains(win.windowId), win.appId == s.appId else { return false }
                let title = controller.inspectAXWindow(windowId: win.windowId, pid: win.pid)?.title ?? win.title
                return title.localizedCaseInsensitiveContains(hint)
            }) {
                matched[idx] = found
                usedIds.insert(found.windowId)
            }
        }

        for (idx, s) in saved.enumerated() where matched[idx] == nil {
            if let found = live.first(where: {
                !usedIds.contains($0.windowId) &&
                $0.appId == s.appId &&
                controller.isLikelyMainWindow($0, expectedFrame: s.frame)
            }) {
                matched[idx] = found
                usedIds.insert(found.windowId)
            }
        }
        return matched
    }
}
