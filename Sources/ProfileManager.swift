import Cocoa
import Foundation

enum ProfileActionError: LocalizedError {
    case skyLightUnavailable
    case missingAccessibility
    case missingDisplays([String])
    case insufficientSpaces([(displayName: String, current: Int, required: Int)])

    var errorDescription: String? {
        switch self {
        case .skyLightUnavailable:
            return "Unable to query macOS Spaces metadata (SkyLight API unavailable)."
        case .missingAccessibility:
            return "Grant Accessibility permission to SpaceBoot in System Settings → Privacy & Security → Accessibility."
        case .missingDisplays(let names):
            return "Required display(s) not connected: \(names.joined(separator: ", "))."
        case .insufficientSpaces(let items):
            let details = items.map { "\($0.displayName): has \($0.current) desktop(s), profile requires \($0.required)" }
            return "Not enough Desktop Spaces:\n" + details.joined(separator: "\n") + "\n\nAdd the missing Desktop Spaces in Mission Control and try again."
        }
    }
}

/// Handles profile persistence, instant multi-Space recording, and sequential Space boot/restoration.
final class ProfileManager {
    private let inspector: SpaceInspector
    private let controller: WindowController

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
                    let priorWin = findPriorWindow(
                        for: win,
                        in: priorSpace?.windows ?? [],
                        usedIndices: &usedPriorIndices
                    )
                    return WindowRecord(
                        appId: win.appId,
                        appName: win.appName,
                        titleHint: priorWin?.titleHint ?? inferTitleHint(for: win),
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
        return profile
    }

    // MARK: - Boot & Restore

    func applyProfile(_ profile: SpaceBootProfile, launchMissing: Bool) throws -> (matched: Int, total: Int) {
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
        for pair in displayPairs where pair.live.desktopSpaceIds.count < pair.saved.spaceCount {
            insufficient.append((pair.saved.displayName, pair.live.desktopSpaceIds.count, pair.saved.spaceCount))
        }
        if !insufficient.isEmpty {
            throw ProfileActionError.insufficientSpaces(insufficient)
        }

        var matchedCount = 0
        let totalCount = profile.totalWindowCount

        for pair in displayPairs {
            let liveUUID = pair.live.uuid

            for savedSpace in pair.saved.spaces where !savedSpace.windows.isEmpty {
                guard controller.switchDisplay(liveUUID, toSpaceIndex: savedSpace.spaceIndex) else {
                    continue
                }

                guard let currentDisplay = inspector.listDisplays().first(where: { $0.uuid == liveUUID }),
                      savedSpace.spaceIndex < currentDisplay.desktopSpaceIds.count else { continue }
                let targetSpaceId = currentDisplay.desktopSpaceIds[savedSpace.spaceIndex]

                var windowsOnSpace = inspector.listAllUserWindows().filter { $0.spaceIds.contains(targetSpaceId) }
                var assignments = matchWindowsOnSpace(saved: savedSpace.windows, live: windowsOnSpace)

                if launchMissing {
                    for (idx, savedWin) in savedSpace.windows.enumerated() where assignments[idx] == nil {
                        guard let launch = savedWin.launch else { continue }
                        let existingIds = Set(inspector.listAllUserWindows().map { $0.windowId })
                        triggerLaunch(launch)

                        if let newWin = waitForNewWindow(appId: savedWin.appId, excluding: existingIds) {
                            assignments[idx] = newWin
                        }
                    }
                    windowsOnSpace = inspector.listAllUserWindows().filter { $0.spaceIds.contains(targetSpaceId) }
                    let retry = matchWindowsOnSpace(saved: savedSpace.windows, live: windowsOnSpace)
                    for (idx, win) in retry where assignments[idx] == nil {
                        assignments[idx] = win
                    }
                }

                var placed: [(saved: WindowRecord, live: LiveWindowInfo)] = []
                for (idx, savedWin) in savedSpace.windows.enumerated() {
                    guard let liveWin = assignments[idx] else { continue }
                    _ = controller.setWindowFrame(windowId: liveWin.windowId, pid: liveWin.pid, frame: savedWin.frame)
                    placed.append((savedWin, liveWin))
                    matchedCount += 1
                }

                for item in placed.sorted(by: { $0.saved.zIndex > $1.saved.zIndex }) {
                    controller.raiseWindow(windowId: item.live.windowId, pid: item.live.pid)
                    usleep(SpaceBootConfig.raiseWindowDelayMicros)
                }
            }

            let finalIndex = min(pair.saved.activeSpaceIndex, max(0, pair.live.desktopSpaceIds.count - 1))
            _ = controller.switchDisplay(liveUUID, toSpaceIndex: finalIndex)
        }

        return (matchedCount, totalCount)
    }

    // MARK: - Private Helpers

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

    private func inferTitleHint(for win: LiveWindowInfo) -> String? {
        let trimmed = win.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(40))
    }

    private func defaultLaunchConfig(for win: LiveWindowInfo) -> LaunchConfig? {
        if SpaceBootConfig.hostManagedBundleIds.contains(win.appId) {
            return nil
        }
        if win.appId == "com.google.Chrome" {
            return LaunchConfig(kind: "chrome_new_window", target: "")
        }
        if win.appId == "com.todesktop.230313mzl4w4u92" {
            return LaunchConfig(kind: "cursor_new_window", target: "")
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: win.appId) {
            return LaunchConfig(kind: "app", target: appURL.path)
        }
        return LaunchConfig(kind: "app", target: win.appName)
    }

    private func matchWindowsOnSpace(saved: [WindowRecord], live: [LiveWindowInfo]) -> [Int: LiveWindowInfo] {
        var matched: [Int: LiveWindowInfo] = [:]
        var usedIds: Set<Int> = []

        for (idx, s) in saved.enumerated() {
            guard let hint = s.titleHint, !hint.isEmpty else { continue }
            if let found = live.first(where: {
                !usedIds.contains($0.windowId) &&
                $0.appId == s.appId &&
                $0.title.localizedCaseInsensitiveContains(hint)
            }) {
                matched[idx] = found
                usedIds.insert(found.windowId)
            }
        }

        for (idx, s) in saved.enumerated() where matched[idx] == nil {
            if let found = live.first(where: { !usedIds.contains($0.windowId) && $0.appId == s.appId }) {
                matched[idx] = found
                usedIds.insert(found.windowId)
            }
        }
        return matched
    }

    private func triggerLaunch(_ spec: LaunchConfig) {
        let process = Process()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        switch spec.kind {
        case "chrome_new_window":
            process.executableURL = URL(fileURLWithPath: SpaceBootConfig.chromeExecutablePath)
            var args = ["--new-window"]
            if !spec.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append(spec.target)
            }
            process.arguments = args

        case "cursor_new_window":
            if let cursorCli = SpaceBootConfig.resolveCursorCliPath() {
                process.executableURL = URL(fileURLWithPath: cursorCli)
                process.arguments = ["--new-window"]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "Cursor"]
            }

        case "cursor_uri":
            guard let cursorCli = SpaceBootConfig.resolveCursorCliPath() else { return }
            process.executableURL = URL(fileURLWithPath: cursorCli)
            process.arguments = ["--file-uri", spec.target]

        case "app":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", spec.target]

        default:
            return
        }

        try? process.run()
    }

    private func waitForNewWindow(appId: String, excluding existingIds: Set<Int>) -> LiveWindowInfo? {
        let deadline = Date().addingTimeInterval(SpaceBootConfig.launchWindowTimeoutSeconds)
        while Date() < deadline {
            usleep(SpaceBootConfig.launchPollMicros)
            let live = inspector.listAllUserWindows()
            if let found = live.first(where: { $0.appId == appId && !existingIds.contains($0.windowId) }) {
                usleep(250_000)
                return found
            }
        }
        return nil
    }
}
