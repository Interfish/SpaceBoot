import Cocoa
import CoreGraphics
import Foundation

/// Read-only queries against macOS SkyLight + CoreGraphics to inspect all displays,
/// native Spaces, and genuinely open windows across every Space without switching.
final class SpaceInspector {
    private typealias MainConnFn = @convention(c) () -> UInt32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> CFArray
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, UInt32, CFArray) -> CFArray
    private typealias CopyWindowsWithOptionsAndTagsFn = @convention(c) (
        UInt32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> CFArray

    private let connectionId: UInt32
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?
    private let copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTagsFn?

    init() {
        let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(skyLightPath, RTLD_NOW),
              let mainSym = dlsym(handle, "SLSMainConnectionID"),
              let managedSym = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let winSpacesSym = dlsym(handle, "SLSCopySpacesForWindows") else {
            self.connectionId = 0
            self.copyManagedDisplaySpaces = nil
            self.copySpacesForWindows = nil
            self.copyWindowsWithOptionsAndTags = nil
            return
        }

        let mainConn = unsafeBitCast(mainSym, to: MainConnFn.self)
        self.connectionId = mainConn()
        self.copyManagedDisplaySpaces = unsafeBitCast(managedSym, to: CopyManagedDisplaySpacesFn.self)
        self.copySpacesForWindows = unsafeBitCast(winSpacesSym, to: CopySpacesForWindowsFn.self)
        if let optsSym = dlsym(handle, "SLSCopyWindowsWithOptionsAndTags") {
            self.copyWindowsWithOptionsAndTags = unsafeBitCast(optsSym, to: CopyWindowsWithOptionsAndTagsFn.self)
        } else {
            self.copyWindowsWithOptionsAndTags = nil
        }
    }

    var isAvailable: Bool {
        copyManagedDisplaySpaces != nil && copySpacesForWindows != nil
    }

    /// Returns all currently connected displays with their exact native Desktop Space list.
    func listDisplays() -> [LiveDisplayInfo] {
        guard let copyManaged = copyManagedDisplaySpaces else { return [] }
        let rawDisplays = copyManaged(connectionId) as? [[String: Any]] ?? []
        let screenMap = buildScreenMap()

        var results: [LiveDisplayInfo] = []
        for entry in rawDisplays {
            guard let uuid = entry["Display Identifier"] as? String else { continue }
            let rawSpaces = entry["Spaces"] as? [[String: Any]] ?? []
            let desktopSpaceIds = rawSpaces.compactMap { space -> Int? in
                let type = space["type"] as? Int ?? -1
                guard type == SpaceBootConfig.desktopSpaceType else { return nil }
                return space["id64"] as? Int
            }
            let currentSpaceId = (entry["Current Space"] as? [String: Any])?["id64"] as? Int ?? 0

            let screenInfo = screenMap[uuid]
            results.append(LiveDisplayInfo(
                uuid: uuid,
                name: screenInfo?.name ?? uuid,
                cgFrame: screenInfo?.cgFrame ?? .zero,
                desktopSpaceIds: desktopSpaceIds,
                currentSpaceId: currentSpaceId
            ))
        }
        return results
    }

    /// Returns all genuinely open (non-closed, non-minimized, non-hidden) user app windows
    /// across all Desktop Spaces, ordered front-to-back.
    func listAllUserWindows() -> [LiveWindowInfo] {
        guard let copyWinSpaces = copySpacesForWindows else { return [] }
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let displays = listDisplays()
        let activeSpaceIds = Set(displays.map { $0.currentSpaceId })
        let openSpaceLookup = buildOpenWindowSpaceMap(displays: displays)
        let pidInfo = buildPidAppInfoMap()

        var windows: [LiveWindowInfo] = []
        var zOrder = 0

        for entry in rawList {
            guard isUserWindowEntry(entry, pidInfo: pidInfo) else { continue }
            guard let wid = entry[kCGWindowNumber as String] as? Int,
                  let pidInt = entry[kCGWindowOwnerPID as String] as? Int else { continue }

            let pid = pid_t(pidInt)
            let appInfo = pidInfo[pid]
            let appId = appInfo?.bundleId ?? ""
            let appName = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = entry[kCGWindowName as String] as? String ?? ""
            let isOnscreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]

            let frame = WindowRect(
                x: Int((bounds["X"] as? Double ?? 0).rounded()),
                y: Int((bounds["Y"] as? Double ?? 0).rounded()),
                width: Int((bounds["Width"] as? Double ?? 0).rounded()),
                height: Int((bounds["Height"] as? Double ?? 0).rounded())
            )

            // Prefer SLSCopyWindowsWithOptionsAndTags(options: 0x0) which excludes closed (Cmd+W),
            // minimized (Cmd+M), and hidden windows even on inactive Spaces.
            let spaceIds: [Int]
            if let lookup = openSpaceLookup {
                guard let matchedSpaces = lookup[wid], !matchedSpaces.isEmpty else { continue }
                spaceIds = matchedSpaces
            } else {
                let fallbackSpaces = copyWinSpaces(connectionId, 0x7, [wid] as CFArray) as? [Int] ?? []
                guard !fallbackSpaces.isEmpty else { continue }
                spaceIds = fallbackSpaces
            }

            // Extra guard: on a currently visible Space, require CoreGraphics to report the window onscreen.
            let onActiveSpace = spaceIds.contains(where: { activeSpaceIds.contains($0) })
            if onActiveSpace && !isOnscreen {
                continue
            }

            windows.append(LiveWindowInfo(
                windowId: wid,
                pid: pid,
                appId: appId,
                appName: appName,
                title: title,
                frame: frame,
                spaceIds: spaceIds,
                zIndex: zOrder,
                isOnscreen: isOnscreen
            ))
            zOrder += 1
        }
        return windows
    }

    /// Finds the active display matching a saved display layout (UUID first, then name fallback).
    func matchLiveDisplay(for saved: DisplayLayout, in liveDisplays: [LiveDisplayInfo]) -> LiveDisplayInfo? {
        if let exact = liveDisplays.first(where: { $0.uuid == saved.displayUUID }) {
            return exact
        }
        return liveDisplays.first(where: { $0.name == saved.displayName })
    }

    // MARK: - Private Helpers

    /// Maps each genuinely open (unminimized, non-hidden, non-closed) windowId -> [desktopSpaceId].
    private func buildOpenWindowSpaceMap(displays: [LiveDisplayInfo]) -> [Int: [Int]]? {
        guard let copyWithOpts = copyWindowsWithOptionsAndTags else { return nil }
        var map: [Int: [Int]] = [:]

        for display in displays {
            for spaceId in display.desktopSpaceIds {
                var setTags: UInt64 = 0
                var clearTags: UInt64 = 0
                // options = 0x0 excludes minimized, hidden, and closed background windows on that Space.
                let rawIds = copyWithOpts(connectionId, 0, [spaceId] as CFArray, 0x0, &setTags, &clearTags) as? [Int] ?? []
                for wid in rawIds {
                    map[wid, default: []].append(spaceId)
                }
            }
        }
        return map
    }

    private func buildScreenMap() -> [String: (name: String, cgFrame: CGRect)] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var map: [String: (String, CGRect)] = [:]

        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let cfUUID = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue() else { continue }
            let uuidString = CFUUIDCreateString(nil, cfUUID) as String
            let appKitFrame = screen.frame
            let cgY = primaryHeight - (appKitFrame.origin.y + appKitFrame.size.height)
            let cgFrame = CGRect(
                x: appKitFrame.origin.x,
                y: cgY,
                width: appKitFrame.size.width,
                height: appKitFrame.size.height
            )
            map[uuidString] = (screen.localizedName, cgFrame)
        }
        return map
    }

    private func buildPidAppInfoMap() -> [pid_t: (bundleId: String, isHidden: Bool)] {
        var map: [pid_t: (String, Bool)] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                map[app.processIdentifier] = (bid, app.isHidden)
            }
        }
        return map
    }

    private func isUserWindowEntry(_ entry: [String: Any], pidInfo: [pid_t: (bundleId: String, isHidden: Bool)]) -> Bool {
        guard (entry[kCGWindowLayer as String] as? Int) == SpaceBootConfig.normalWindowLayer else {
            return false
        }
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 0
        guard alpha > 0 else { return false }

        let pid = pid_t(entry[kCGWindowOwnerPID as String] as? Int ?? 0)
        guard let info = pidInfo[pid], !info.isHidden else { return false }
        guard !SpaceBootConfig.ignoredBundleIds.contains(info.bundleId) else { return false }

        let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        return width >= SpaceBootConfig.minimumWindowWidth && height >= SpaceBootConfig.minimumWindowHeight
    }
}
