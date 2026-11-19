import Cocoa
import CoreGraphics
import Foundation

/// Read-only queries against macOS SkyLight + CoreGraphics to inspect all displays,
/// native Spaces, and windows across every Space (including inactive Spaces) without switching.
final class SpaceInspector {
    private typealias MainConnFn = @convention(c) () -> UInt32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> CFArray
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, UInt32, CFArray) -> CFArray

    private let connectionId: UInt32
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?

    init() {
        let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(skyLightPath, RTLD_NOW),
              let mainSym = dlsym(handle, "SLSMainConnectionID"),
              let managedSym = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let winSpacesSym = dlsym(handle, "SLSCopySpacesForWindows") else {
            self.connectionId = 0
            self.copyManagedDisplaySpaces = nil
            self.copySpacesForWindows = nil
            return
        }

        let mainConn = unsafeBitCast(mainSym, to: MainConnFn.self)
        self.connectionId = mainConn()
        self.copyManagedDisplaySpaces = unsafeBitCast(managedSym, to: CopyManagedDisplaySpacesFn.self)
        self.copySpacesForWindows = unsafeBitCast(winSpacesSym, to: CopySpacesForWindowsFn.self)
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

    /// Returns all normal user app windows across all Spaces (ordered front-to-back).
    func listAllUserWindows() -> [LiveWindowInfo] {
        guard let copyWinSpaces = copySpacesForWindows else { return [] }
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let pidToBundleId = buildPidBundleIdMap()
        var windows: [LiveWindowInfo] = []
        var zOrder = 0

        for entry in rawList {
            guard isUserWindowEntry(entry, pidToBundleId: pidToBundleId) else { continue }
            guard let wid = entry[kCGWindowNumber as String] as? Int,
                  let pidInt = entry[kCGWindowOwnerPID as String] as? Int else { continue }

            let pid = pid_t(pidInt)
            let appId = pidToBundleId[pid] ?? ""
            let appName = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = entry[kCGWindowName as String] as? String ?? ""
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]

            let frame = WindowRect(
                x: Int((bounds["X"] as? Double ?? 0).rounded()),
                y: Int((bounds["Y"] as? Double ?? 0).rounded()),
                width: Int((bounds["Width"] as? Double ?? 0).rounded()),
                height: Int((bounds["Height"] as? Double ?? 0).rounded())
            )

            // Mask 0x7 queries all space types for this window ID.
            let spaceIds = copyWinSpaces(connectionId, 0x7, [wid] as CFArray) as? [Int] ?? []
            guard !spaceIds.isEmpty else { continue }

            windows.append(LiveWindowInfo(
                windowId: wid,
                pid: pid,
                appId: appId,
                appName: appName,
                title: title,
                frame: frame,
                spaceIds: spaceIds,
                zIndex: zOrder
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

    private func buildScreenMap() -> [String: (name: String, cgFrame: CGRect)] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var map: [String: (String, CGRect)] = [:]

        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let cfUUID = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue() else { continue }
            let uuidString = CFUUIDCreateString(nil, cfUUID) as String
            let appKitFrame = screen.frame
            // Convert AppKit bottom-left origin coordinates to CoreGraphics top-left origin coordinates.
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

    private func buildPidBundleIdMap() -> [pid_t: String] {
        var map: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                map[app.processIdentifier] = bid
            }
        }
        return map
    }

    private func isUserWindowEntry(_ entry: [String: Any], pidToBundleId: [pid_t: String]) -> Bool {
        guard (entry[kCGWindowLayer as String] as? Int) == SpaceBootConfig.normalWindowLayer else {
            return false
        }
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 0
        guard alpha > 0 else { return false }

        let pid = pid_t(entry[kCGWindowOwnerPID as String] as? Int ?? 0)
        let bundleId = pidToBundleId[pid] ?? ""
        guard !SpaceBootConfig.ignoredBundleIds.contains(bundleId) else { return false }

        let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        return width >= SpaceBootConfig.minimumWindowWidth && height >= SpaceBootConfig.minimumWindowHeight
    }
}
