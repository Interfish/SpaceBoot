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

/// Handles profile persistence, instant multi-Space recording, and universal Space boot/restoration.
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
            for sIdx in 0..<display.desktopSpaceIds.count {
                let rawWins = buckets[dIdx][sIdx] ?? []
                let priorSpace = priorDisplay?.spaces.first(where: { $0.spaceIndex == sIdx })
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

                spaceLayouts.append(SpaceLayout(spaceIndex: sIdx, windows: records))
            }

            displayLayouts.append(DisplayLayout(
                displayUUID: display.uuid,
                displayName: display.name,
                spaceCount: display.desktopSpaceIds.count,
                activeSpaceIndex: display.currentSpaceIndex ?? 0,
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

    // MARK: - Boot & Restore

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
        for pair in displayPairs where pair.live.desktopSpaceIds.count < pair.saved.spaceCount {
            insufficient.append((pair.saved.displayName, pair.live.desktopSpaceIds.count, pair.saved.spaceCount))
        }
        if !insufficient.isEmpty {
            throw ProfileActionError.insufficientSpaces(insufficient)
        }

        // Verify at least one Space-switching method is available if multi-Space navigation is needed.
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

        for pair in displayPairs {
            let liveUUID = pair.live.uuid

            // Process activeSpaceIndex LAST so the display naturally finishes on the user's primary working Space.
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

                // Launch missing windows sequentially while this display & Space are active.
                if launchMissing {
                    for (idx, savedWin) in savedSpace.windows.enumerated() where assignments[idx] == nil {
                        guard let launch = savedWin.launch else { continue }
                        let currentAll = inspector.listAllUserWindows()
                        let existingIds = Set(currentAll.map { $0.windowId })
                        let appAlreadyHasWindow = currentAll.contains { $0.appId == savedWin.appId }

                        SpaceBootLogger.log("Launching \(savedWin.appName) (kind=\(launch.kind), hasWindow=\(appAlreadyHasWindow)) for \(pair.saved.displayName) space[\(savedSpace.spaceIndex)]")
                        let outcome = launcher.launchWindow(
                            appId: savedWin.appId,
                            spec: launch,
                            appAlreadyHasWindow: appAlreadyHasWindow
                        )

                        switch outcome {
                        case .singleWindowAlreadyOpen:
                            continue
                        case .failed(let reason):
                            SpaceBootLogger.log("Launch failed for \(savedWin.appName): \(reason)")
                            continue
                        case .triggered:
                            break
                        }

                        if let result = waitForMainWindow(
                            appId: savedWin.appId,
                            expectedFrame: savedWin.frame,
                            excluding: existingIds
                        ) {
                            let newWin = result.window
                            assignments[idx] = newWin
                            claimedWindowIds.insert(newWin.windowId)
                            _ = controller.setWindowFrameVerified(
                                windowId: newWin.windowId,
                                pid: newWin.pid,
                                frame: savedWin.frame,
                                targetSpaceId: targetSpaceId
                            )
                            if result.sawSplash,
                               let replaced = watchForWindowReplacement(
                                   original: newWin,
                                   expectedFrame: savedWin.frame,
                                   excluding: existingIds
                               ) {
                                SpaceBootLogger.log("Detected replacement window wid=\(replaced.windowId) for \(savedWin.appName)")
                                assignments[idx] = replaced
                                claimedWindowIds.insert(replaced.windowId)
                            }
                        } else {
                            SpaceBootLogger.log("Timed out waiting for main window of \(savedWin.appName); queuing late-arrival watcher")
                            pendingLateWindows.append(PendingLateWindow(
                                appId: savedWin.appId,
                                appName: savedWin.appName,
                                savedWindow: savedWin,
                                targetSpaceId: targetSpaceId,
                                existingIdsAtLaunch: existingIds
                            ))
                        }
                    }
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

            let finalIndex = min(pair.saved.activeSpaceIndex, max(0, pair.live.desktopSpaceIds.count - 1))
            _ = controller.switchDisplay(liveUUID, toSpaceIndex: finalIndex)
        }

        if !pendingLateWindows.isEmpty {
            watchPendingLateWindows(pendingLateWindows)
        }

        SpaceBootLogger.log("=== APPLY DONE profile=\(profile.name) matched=\(matchedCount)/\(totalCount) pendingLate=\(pendingLateWindows.count) ===")
        return (matchedCount, totalCount)
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

    private func waitForMainWindow(
        appId: String,
        expectedFrame: WindowRect,
        excluding existingIds: Set<Int>
    ) -> (window: LiveWindowInfo, sawSplash: Bool)? {
        var deadline = Date().addingTimeInterval(SpaceBootConfig.launchWindowTimeoutSeconds)
        var extendedForProcess = false
        var sawSplash = false

        while Date() < deadline {
            usleep(SpaceBootConfig.launchPollMicros)
            let candidates = inspector.listAllUserWindows().filter {
                $0.appId == appId && !existingIds.contains($0.windowId)
            }

            if let mainWin = candidates.first(where: {
                controller.isLikelyMainWindow($0, expectedFrame: expectedFrame, requireAXMetadata: true)
            }) {
                usleep(350_000)
                let refreshed = inspector.listAllUserWindows().first(where: { $0.windowId == mainWin.windowId }) ?? mainWin
                return (refreshed, sawSplash)
            }

            if !sawSplash && !candidates.isEmpty {
                sawSplash = true
                deadline = max(deadline, Date().addingTimeInterval(SpaceBootConfig.splashExtendedTimeoutSeconds))
                SpaceBootLogger.log("Detected splash/loading window for \(appId); extending wait to \(Int(SpaceBootConfig.splashExtendedTimeoutSeconds))s")
            } else if !extendedForProcess && !NSRunningApplication.runningApplications(withBundleIdentifier: appId).isEmpty {
                extendedForProcess = true
                deadline = max(deadline, Date().addingTimeInterval(SpaceBootConfig.processInitTimeoutSeconds))
                SpaceBootLogger.log("App \(appId) process started; waiting up to \(Int(SpaceBootConfig.processInitTimeoutSeconds))s for main window")
            }
        }
        return nil
    }

    private func watchForWindowReplacement(
        original: LiveWindowInfo,
        expectedFrame: WindowRect,
        excluding existingIds: Set<Int>
    ) -> LiveWindowInfo? {
        usleep(SpaceBootConfig.replacementWatchDelayMicros)
        let current = inspector.listAllUserWindows()
        let stillAlive = current.contains { $0.windowId == original.windowId }
        if stillAlive { return nil }

        var excluded = existingIds
        excluded.insert(original.windowId)
        return waitForMainWindow(appId: original.appId, expectedFrame: expectedFrame, excluding: excluded)?.window
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
