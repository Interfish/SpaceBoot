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

/// Handles profile persistence, instant multi-Space recording, and boot validation.
/// The boot itself runs in a `BootSession`.
final class ProfileManager {
    private let inspector: SpaceInspector
    private let controller: WindowController
    private let launcher = AppLauncher()
    private let bootLock = NSLock()
    private var activeBoot: BootSession?

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

    /// Records every display's non-empty Spaces (Desktop, Fullscreen, and Split View) in Mission Control order.
    /// Empty Desktop Spaces are skipped, so `liveSlots` maps each recorded Space to its live Space index.
    /// The profile's `hotkeyOrder` keeps its previous order on re-record, else starts from `liveHotkeyOrder`.
    func recordProfile(
        named name: String,
        liveHotkeyOrder: [SpaceSlotKey]
    ) throws -> (profile: SpaceBootProfile, liveSlots: [SpaceSlotKey: SpaceSlotKey]) {
        guard inspector.isAvailable else { throw ProfileActionError.skyLightUnavailable }

        SpaceBootLogger.log("=== RECORD START profile=\(name) axTrusted=\(AXIsProcessTrusted()) ===")
        let existingProfile = loadProfile(named: name)
        let liveDisplays = inspector.listDisplays()
        let allWindows = inspector.listAllUserWindows()
        let windowsById = Dictionary(allWindows.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })

        var displayLayouts: [DisplayLayout] = []
        var liveSlots: [SpaceSlotKey: SpaceSlotKey] = [:]
        for display in liveDisplays {
            let priorDisplay = existingProfile?.displays.first(where: {
                $0.displayUUID == display.uuid || $0.displayName == display.name
            })

            var spaceLayouts: [SpaceLayout] = []
            var remappedActiveSpaceIndex = 0
            let liveActiveIndex = display.currentSpaceIndex ?? 0

            for (sIdx, liveSpace) in display.spaces.enumerated() {
                let rawWins: [LiveWindowInfo]
                let effectiveKind: SpaceKind
                let recordedSplitRatio: Double?

                switch liveSpace.kind {
                case .desktop:
                    rawWins = allWindows.filter {
                        $0.spaceIds.contains(liveSpace.id) && controller.isRecordableWindow($0, isFullScreenSpace: false)
                    }
                    guard !rawWins.isEmpty else { continue }
                    effectiveKind = .desktop
                    recordedSplitRatio = nil

                case .fullscreen, .split:
                    let tileWins = liveSpace.tiles.compactMap { tile -> LiveWindowInfo? in
                        guard let win = windowsById[tile.windowId],
                              controller.isRecordableWindow(win, isFullScreenSpace: true) else {
                            return nil
                        }
                        return win
                    }
                    guard !tileWins.isEmpty else { continue }
                    rawWins = tileWins
                    effectiveKind = tileWins.count >= 2 ? .split : .fullscreen
                    recordedSplitRatio = effectiveKind == .split ? liveSpace.splitRatio : nil
                }

                let compactedIdx = spaceLayouts.count
                if sIdx == liveActiveIndex {
                    remappedActiveSpaceIndex = compactedIdx
                }
                liveSlots[SpaceSlotKey(displayUUID: display.uuid, spaceIndex: compactedIdx)] =
                    SpaceSlotKey(displayUUID: display.uuid, spaceIndex: sIdx)

                let recordedAppIds = Set(rawWins.map(\.appId))
                let priorSpace = priorDisplay?.spaces.first(where: { $0.spaceIndex == compactedIdx && $0.effectiveKind == effectiveKind })
                    ?? priorDisplay?.spaces.first(where: { $0.spaceIndex == sIdx && $0.effectiveKind == effectiveKind })
                    ?? priorDisplay?.spaces.first(where: {
                        $0.effectiveKind == effectiveKind && !Set($0.windows.map(\.appId)).isDisjoint(with: recordedAppIds)
                    })
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

                spaceLayouts.append(SpaceLayout(
                    spaceIndex: compactedIdx,
                    kind: effectiveKind,
                    splitRatio: recordedSplitRatio,
                    windows: records
                ))
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
        var profile = SpaceBootProfile(
            name: name,
            updatedAt: formatter.string(from: Date()),
            displays: displayLayouts
        )
        let recordedSlotByLive = Dictionary(liveSlots.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        profile.hotkeyOrder = existingProfile?.hotkeyOrder ?? liveHotkeyOrder.compactMap { recordedSlotByLive[$0] }
        profile.hotkeyOrder = profile.resolvedHotkeyOrder
        try saveProfile(profile)
        SpaceBootLogger.log("=== RECORD DONE profile=\(name) totalWindows=\(profile.totalWindowCount) ===")
        return (profile, liveSlots)
    }

    /// Maps each recorded Space of a booted profile to its live Space index on the matching display.
    /// Empty if the profile has no saved ⌥ order, so booting it leaves the current order alone.
    func bootedLiveSlots(for profile: SpaceBootProfile) -> [SpaceSlotKey: SpaceSlotKey] {
        guard profile.hotkeyOrder != nil else { return [:] }
        let liveDisplays = inspector.listDisplays()
        var liveSlots: [SpaceSlotKey: SpaceSlotKey] = [:]

        for saved in profile.displays {
            guard let live = inspector.matchLiveDisplay(for: saved, in: liveDisplays) else { continue }
            let liveDesktopIndices = live.spaces.indices.filter { live.spaces[$0].kind == .desktop }
            var usedLiveIndices: Set<Int> = []
            var desktopRank = 0

            for space in saved.spaces where !space.windows.isEmpty {
                let recordedKey = SpaceSlotKey(displayUUID: saved.displayUUID, spaceIndex: space.spaceIndex)
                switch space.effectiveKind {
                case .desktop:
                    if desktopRank < liveDesktopIndices.count {
                        let liveIdx = liveDesktopIndices[desktopRank]
                        liveSlots[recordedKey] = SpaceSlotKey(displayUUID: live.uuid, spaceIndex: liveIdx)
                        usedLiveIndices.insert(liveIdx)
                    }
                    desktopRank += 1

                case .fullscreen, .split:
                    let expectedApps = Set(space.windows.map(\.appId))
                    let matchedIdx = live.spaces.indices.first(where: { idx in
                        guard !usedLiveIndices.contains(idx), live.spaces[idx].kind == space.effectiveKind else { return false }
                        let tileApps = Set(live.spaces[idx].tiles.compactMap {
                            NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier
                        })
                        return tileApps == expectedApps || !tileApps.isDisjoint(with: expectedApps)
                    }) ?? live.spaces.indices.first(where: {
                        !usedLiveIndices.contains($0) && live.spaces[$0].kind == space.effectiveKind
                    })
                    if let idx = matchedIdx {
                        liveSlots[recordedKey] = SpaceSlotKey(displayUUID: live.uuid, spaceIndex: idx)
                        usedLiveIndices.insert(idx)
                    } else if space.spaceIndex < live.spaces.count {
                        liveSlots[recordedKey] = SpaceSlotKey(displayUUID: live.uuid, spaceIndex: space.spaceIndex)
                    }
                }
            }
        }
        return liveSlots
    }

    // MARK: - Diagnostics

    func dumpDiagnostics() {
        SpaceBootLogger.log("=== INSPECT axTrusted=\(AXIsProcessTrusted()) ===")
        let displays = inspector.listDisplays()
        for d in displays {
            let spaceDesc = d.spaces.map { sp -> String in
                let ratioText = sp.splitRatio.map { String(format: " ratio=%.3f", $0) } ?? ""
                let tileText = sp.tiles.isEmpty ? "" : " tiles=[" + sp.tiles.map { "wid=\($0.windowId) pid=\($0.pid) rect=\($0.tileRect)" }.joined(separator: ", ") + "]"
                return "{id=\(sp.id) \(sp.kind.rawValue)\(ratioText)\(tileText)}"
            }.joined(separator: ", ")
            SpaceBootLogger.log("Display \(d.name) uuid=\(d.uuid) cgFrame=\(d.cgFrame) current=\(d.currentSpaceId) spaces=[\(spaceDesc)]")
        }
        for w in inspector.listAllUserWindows() {
            let meta = controller.inspectAXWindow(windowId: w.windowId, pid: w.pid)
            let metaDesc = meta.map { "role=\($0.role) subrole=\($0.subrole) fs=\($0.isFullScreen) resizable=\($0.isSizeSettable) title='\($0.title.prefix(30))'" } ?? "ax=unavailable"
            SpaceBootLogger.log("  wid=\(w.windowId) \(w.appId) (\(w.appName)) sp=\(w.spaceIds) frame=\(w.frame) \(metaDesc)")
        }
    }

    // MARK: - Boot & Restore

    /// Validates the profile against the connected displays, then runs the boot's busy (foreground) phase.
    /// Late windows (slow or login-gated apps) keep being placed in the background afterwards;
    /// `onBackgroundFinished` reports how that ended if anything was still pending.
    func applyProfile(
        _ profile: SpaceBootProfile,
        launchMissing: Bool,
        onBackgroundFinished: ((BootSession.Summary) -> Void)? = nil
    ) throws -> BootSession.Summary {
        guard inspector.isAvailable else { throw ProfileActionError.skyLightUnavailable }
        guard AXIsProcessTrusted() else { throw ProfileActionError.missingAccessibility }

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
            let requiredDesktops = pair.saved.requiredDesktopSpaceCount
            let hasAnyNonEmpty = pair.saved.spaces.contains { !$0.windows.isEmpty }
            let neededDesktops = hasAnyNonEmpty ? max(1, requiredDesktops) : requiredDesktops
            if pair.live.desktopSpaceIds.count < neededDesktops {
                insufficient.append((pair.saved.displayName, pair.live.desktopSpaceIds.count, neededDesktops))
            }
        }
        if !insufficient.isEmpty {
            throw ProfileActionError.insufficientSpaces(insufficient)
        }

        let hasFullScreen = displayPairs.contains { pair in
            pair.saved.spaces.contains { $0.effectiveKind != .desktop && !$0.windows.isEmpty }
        }
        let needsSpaceSwitch = hasFullScreen || displayPairs.contains { pair in
            pair.saved.spaces.filter { !$0.windows.isEmpty }.count > 1 ||
            pair.saved.spaces.contains { !$0.windows.isEmpty && $0.spaceIndex != (pair.live.currentDesktopIndex ?? -1) }
        }
        if needsSpaceSwitch {
            let hotKeys = SymbolicHotKeys()
            let hasStepShortcuts = hotKeys.moveLeftShortcut() != nil && hotKeys.moveRightShortcut() != nil
            let hasAnyDirect = (0..<16).contains { hotKeys.directDesktopShortcut(globalIndex: $0) != nil }
            if !hasStepShortcuts && !hasAnyDirect {
                throw ProfileActionError.spaceShortcutsDisabled
            }
        }

        let session = BootSession(
            profile: profile,
            displayPairs: displayPairs,
            launchMissing: launchMissing,
            inspector: inspector,
            controller: controller,
            launcher: launcher
        )
        // A newer boot supersedes any background watch still running from the previous one.
        bootLock.lock()
        activeBoot?.cancel()
        activeBoot = session
        bootLock.unlock()

        let summary = session.runForeground()
        if session.hasPendingWork {
            let report = summary.waitingApps.isEmpty ? nil : onBackgroundFinished
            DispatchQueue.global(qos: .utility).async {
                session.runBackground(completion: report)
            }
        }
        return summary
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
}
