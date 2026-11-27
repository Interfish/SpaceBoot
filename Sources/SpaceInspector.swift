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

    /// Returns all currently connected displays with their exact native Spaces (Desktop, Fullscreen, Split View)
    /// in Mission Control left-to-right order.
    func listDisplays() -> [LiveDisplayInfo] {
        guard let copyManaged = copyManagedDisplaySpaces else { return [] }
        let rawDisplays = copyManaged(connectionId) as? [[String: Any]] ?? []
        let screenMap = buildScreenMap()

        var results: [LiveDisplayInfo] = []
        for entry in rawDisplays {
            guard let uuid = entry["Display Identifier"] as? String else { continue }
            let rawSpaces = entry["Spaces"] as? [[String: Any]] ?? []
            let currentSpaceId = (entry["Current Space"] as? [String: Any])?["id64"] as? Int ?? 0
            let screenInfo = screenMap[uuid]
            let displayFrame = screenInfo?.cgFrame ?? .zero

            let spaces = rawSpaces.compactMap { space -> LiveSpaceInfo? in
                guard let id64 = space["id64"] as? Int else { return nil }
                let type = space["type"] as? Int ?? -1
                if type == SpaceBootConfig.desktopSpaceType {
                    return LiveSpaceInfo(id: id64, kind: .desktop, tiles: [], layoutRect: nil, interTileSpacing: 0)
                }
                guard type == SpaceBootConfig.fullscreenSpaceType else { return nil }
                return parseFullScreenSpace(space, spaceId: id64, displayFrame: displayFrame)
            }

            results.append(LiveDisplayInfo(
                uuid: uuid,
                name: screenInfo?.name ?? uuid,
                cgFrame: displayFrame,
                spaces: spaces,
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
        let tileSpaceMap = buildTileWindowSpaceMap(displays: displays)
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

            // Prefer SLSCopyWindowsWithOptionsAndTags(options: 0x0) for Desktop Spaces and direct TileSpaces mapping
            // for Fullscreen/Split Spaces (excluding closed, minimized, hidden, and fullscreen backdrop windows).
            let spaceIds: [Int]
            if let lookup = openSpaceLookup {
                guard let matchedSpaces = lookup[wid], !matchedSpaces.isEmpty else { continue }
                spaceIds = matchedSpaces
            } else if let tileSpaces = tileSpaceMap[wid], !tileSpaces.isEmpty {
                spaceIds = tileSpaces
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

    /// Space IDs hosting `windowId`; empty once the window is closed (minimized windows keep their Space).
    func spaceIds(forWindow windowId: Int) -> [Int] {
        guard let copyWinSpaces = copySpacesForWindows else { return [] }
        return copyWinSpaces(connectionId, 0x7, [windowId] as CFArray) as? [Int] ?? []
    }

    /// Finds the active display matching a saved display layout (UUID first, then name fallback).
    func matchLiveDisplay(for saved: DisplayLayout, in liveDisplays: [LiveDisplayInfo]) -> LiveDisplayInfo? {
        if let exact = liveDisplays.first(where: { $0.uuid == saved.displayUUID }) {
            return exact
        }
        return liveDisplays.first(where: { $0.name == saved.displayName })
    }

    /// Returns the live Fullscreen or Split View Space currently hosting `windowId`, if any.
    func fullScreenSpace(hostingWindow windowId: Int, in displays: [LiveDisplayInfo]? = nil) -> (display: LiveDisplayInfo, space: LiveSpaceInfo)? {
        let list = displays ?? listDisplays()
        for display in list {
            for space in display.spaces where space.kind != .desktop {
                if space.tiles.contains(where: { $0.windowId == windowId }) {
                    return (display, space)
                }
            }
        }
        return nil
    }

    /// Returns the live on-screen bounds for `windowId` (e.g., its picker thumbnail during Split View selection).
    func onscreenWindowBounds(windowId: Int) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in rawList {
            guard (entry[kCGWindowNumber as String] as? Int) == windowId,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = bounds["X"] as? Double ?? 0
            let y = bounds["Y"] as? Double ?? 0
            let w = bounds["Width"] as? Double ?? 0
            let h = bounds["Height"] as? Double ?? 0
            if w > 0 && h > 0 {
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }
        return nil
    }

    /// Diagnostic helper returning currently onscreen layer-0 user windows and their live CG frames.
    func listOnscreenUserWindows() -> [(windowId: Int, pid: pid_t, appName: String, rect: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let pidInfo = buildPidAppInfoMap()
        var results: [(Int, pid_t, String, CGRect)] = []
        for entry in rawList {
            guard isUserWindowEntry(entry, pidInfo: pidInfo),
                  let wid = entry[kCGWindowNumber as String] as? Int,
                  let pidInt = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let rect = CGRect(
                x: bounds["X"] as? Double ?? 0,
                y: bounds["Y"] as? Double ?? 0,
                width: bounds["Width"] as? Double ?? 0,
                height: bounds["Height"] as? Double ?? 0
            )
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            results.append((wid, pid_t(pidInt), owner, rect))
        }
        return results
    }

    // MARK: - Private Helpers

    private func parseFullScreenSpace(_ space: [String: Any], spaceId: Int, displayFrame: CGRect) -> LiveSpaceInfo? {
        let manager = space["TileLayoutManager"] as? [String: Any]
        let layoutRect = (manager?["Layout Rect"] as? [String: Any]).flatMap(parseWindowRect)
        let spacingWidth = ((manager?["Inter-Tile Spacing"] as? [String: Any])?["Width"] as? NSNumber)?.doubleValue ?? 12.0
        let interTileSpacing = Int(spacingWidth.rounded())

        var tiles: [LiveTileInfo] = []
        if let rawTiles = manager?["TileSpaces"] as? [[String: Any]] {
            for tile in rawTiles {
                let wid = (tile["TileWindowID"] as? Int) ?? (tile["fs_wid"] as? Int) ?? 0
                let pidInt = tile["pid"] as? Int ?? 0
                guard wid > 0 else { continue }
                let tileSpaceId = tile["id64"] as? Int ?? spaceId
                let tileType = tile["TileType"] as? String ?? "Primary"
                let rect = (tile["TileRect"] as? [String: Any]).flatMap(parseWindowRect)
                    ?? layoutRect
                    ?? WindowRect(x: 0, y: 0, width: Int(displayFrame.width), height: Int(displayFrame.height))
                tiles.append(LiveTileInfo(
                    windowId: wid,
                    pid: pid_t(pidInt),
                    tileSpaceId: tileSpaceId,
                    tileType: tileType,
                    tileRect: rect
                ))
            }
        }

        if tiles.isEmpty, let wid = space["fs_wid"] as? Int, wid > 0 {
            let pidInt = space["pid"] as? Int ?? 0
            let fallbackRect = WindowRect(x: 0, y: 0, width: Int(displayFrame.width), height: Int(displayFrame.height))
            tiles.append(LiveTileInfo(
                windowId: wid,
                pid: pid_t(pidInt),
                tileSpaceId: spaceId,
                tileType: "Primary",
                tileRect: fallbackRect
            ))
        }

        guard !tiles.isEmpty else { return nil }
        tiles.sort {
            if $0.tileRect.x != $1.tileRect.x { return $0.tileRect.x < $1.tileRect.x }
            return $0.tileType == "Primary" && $1.tileType != "Primary"
        }

        let kind: SpaceKind = tiles.count >= 2 ? .split : .fullscreen
        return LiveSpaceInfo(
            id: spaceId,
            kind: kind,
            tiles: tiles,
            layoutRect: layoutRect,
            interTileSpacing: interTileSpacing
        )
    }

    private func parseWindowRect(_ dict: [String: Any]) -> WindowRect? {
        guard let x = (dict["X"] as? NSNumber)?.doubleValue,
              let y = (dict["Y"] as? NSNumber)?.doubleValue,
              let w = (dict["Width"] as? NSNumber)?.doubleValue,
              let h = (dict["Height"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return WindowRect(
            x: Int(x.rounded()),
            y: Int(y.rounded()),
            width: Int(w.rounded()),
            height: Int(h.rounded())
        )
    }

    private func buildTileWindowSpaceMap(displays: [LiveDisplayInfo]) -> [Int: [Int]] {
        var map: [Int: [Int]] = [:]
        for display in displays {
            for space in display.spaces where space.kind != .desktop {
                for tile in space.tiles {
                    map[tile.windowId, default: []].append(space.id)
                }
            }
        }
        return map
    }

    /// Maps each genuinely open (unminimized, non-hidden, non-closed) windowId -> [spaceId] across Desktop and Fullscreen/Split Spaces.
    private func buildOpenWindowSpaceMap(displays: [LiveDisplayInfo]) -> [Int: [Int]]? {
        guard let copyWithOpts = copyWindowsWithOptionsAndTags else { return nil }
        var map = buildTileWindowSpaceMap(displays: displays)

        for display in displays {
            for space in display.spaces where space.kind == .desktop {
                var setTags: UInt64 = 0
                var clearTags: UInt64 = 0
                // options = 0x0 excludes minimized, hidden, and closed background windows on that Desktop Space.
                let rawIds = copyWithOpts(connectionId, 0, [space.id] as CFArray, 0x0, &setTags, &clearTags) as? [Int] ?? []
                for wid in rawIds {
                    map[wid, default: []].append(space.id)
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
