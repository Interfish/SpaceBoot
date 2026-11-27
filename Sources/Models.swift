import Foundation

// MARK: - App Constants

enum SpaceBootConfig {
    static let appName = "SpaceBoot"
    static let bundleIdentifier = "com.spaceboot.SpaceBoot"
    static let profilesDirectory = "\(NSHomeDirectory())/.config/spaceboot/profiles"

    static let minimumWindowWidth: Double = 150
    static let minimumWindowHeight: Double = 150
    static let largeTargetMinWidth = 500
    static let largeTargetMinHeight = 400
    static let splashFilterMinWidth = 450
    static let splashFilterMinHeight = 350
    static let normalWindowLayer = 0
    static let desktopSpaceType = 0
    static let fullscreenSpaceType = 4

    static let fullscreenTransitionTimeoutSeconds: TimeInterval = 4.0
    static let splitPickerAppearTimeoutSeconds: TimeInterval = 3.5
    static let splitRatioTolerance: Double = 0.025

    static let spaceSwitchTimeoutSeconds: TimeInterval = 2.0
    static let spaceSwitchPollMicros: useconds_t = 80_000
    static let spaceAnimationSettleMicros: useconds_t = 400_000
    /// ⌥1–⌥9 switches hold their lock only this long after arrival (boots keep the longer settle).
    static let interactiveSettleMicros: useconds_t = 80_000
    static let interactivePollMicros: useconds_t = 40_000
    static let frameVerifyTolerancePx = 24
    static let frameApplyMaxAttempts = 5
    static let frameVerifyDelayMicros: useconds_t = 220_000
    static let raiseWindowDelayMicros: useconds_t = 70_000
    static let postBootSettleGuardSeconds: TimeInterval = 15.0

    // Event-driven boot pipeline (see BootSession).
    static let coldLaunchStaggerSeconds: TimeInterval = 1.0
    static let executorPollMicros: useconds_t = 250_000
    static let freshWindowSettleSeconds: TimeInterval = 0.3
    static let windowRequestResponseSeconds: TimeInterval = 3.0
    static let windowRequestRetrySeconds: TimeInterval = 8.0
    static let maxWindowRequestsPerSlot = 2
    static let postReadyGraceSeconds: TimeInterval = 1.5
    static let foregroundWaitPerAppSeconds: TimeInterval = 15.0
    static let foregroundPhaseMaxSeconds: TimeInterval = 90.0
    static let pendingWindowWatchSeconds: TimeInterval = 300.0
    static let settleAfterForegroundSeconds: TimeInterval = 20.0
    static let replacementWaitSeconds: TimeInterval = 60.0
    static let handoverWatchSeconds: TimeInterval = 120.0
    static let maxRequestSwitchFailures = 3
    static let missingWindowGraceSeconds: TimeInterval = 5.0
    static let maxPlacementAttempts = 3
    static let maxRelocationAttempts = 2
    static let relocationJoinTimeoutSeconds: TimeInterval = 3.0
    static let userIdleBeforeSwitchSeconds: TimeInterval = 1.0
    static let promptNudgeDelaySeconds: TimeInterval = 2.0

    /// macOS system/daemon processes excluded from recorded workspace layouts.
    static let ignoredBundleIds: Set<String> = [
        "",
        "com.spaceboot.SpaceBoot",
        "com.apple.WindowManager",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.screencaptureui",
        "com.apple.UserNotificationCenter"
    ]

    /// Returns true if `bundlePath` is a standard user-launchable macOS application bundle
    /// (excluding embedded helper/sub-browser bundles inside Library/Application Support or another .app/Contents).
    static func isStandaloneApplicationPath(_ bundlePath: String) -> Bool {
        let standardized = (bundlePath as NSString).standardizingPath
        if standardized.contains("/Library/Application Support/") {
            return false
        }
        // Reject helper apps nested inside another .app bundle (e.g. Foo.app/Contents/Helpers/Bar.app).
        if let firstAppRange = standardized.range(of: ".app/Contents/") {
            let suffix = standardized[firstAppRange.upperBound...]
            if suffix.contains(".app") {
                return false
            }
        }
        let standardRoots = [
            "/Applications/",
            "/System/Applications/",
            "/System/Library/CoreServices/Finder.app",
            "\(NSHomeDirectory())/Applications/"
        ]
        return standardRoots.contains { standardized.hasPrefix($0) }
    }
}

// MARK: - Persisted Profile Schema

struct WindowRect: Codable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    func isApproximatelyEqual(to other: WindowRect, tolerance: Int) -> Bool {
        abs(x - other.x) <= tolerance &&
        abs(y - other.y) <= tolerance &&
        abs(width - other.width) <= tolerance &&
        abs(height - other.height) <= tolerance
    }
}

struct LaunchConfig: Codable, Equatable {
    /// Supported kinds:
    /// - "app": Launch app via LaunchServices (cold) or AXMenuBar New Window (warm).
    /// - "command": Execute custom shell command in the user's login shell ($SHELL -l -c).
    var kind: String
    /// Application bundle path (for "app") or shell command string (for "command").
    var target: String
    /// Optional URL or file path to open with the app (for "app").
    var url: String?
}

struct WindowRecord: Codable {
    var appId: String
    var appName: String
    var titleHint: String?
    var frame: WindowRect
    var zIndex: Int
    var launch: LaunchConfig?
}

enum SpaceKind: String, Codable, Equatable {
    case desktop
    case fullscreen
    case split
}

struct SpaceLayout: Codable {
    /// 0-based order of this Space on this display (across Desktop, Fullscreen, and Split View Spaces).
    var spaceIndex: Int
    /// Nil in legacy profiles (treated as `.desktop`).
    var kind: SpaceKind? = nil
    /// For `.split`: left window width fraction of total tiled width (e.g. 0.5, 0.65).
    var splitRatio: Double? = nil
    var windows: [WindowRecord]

    var effectiveKind: SpaceKind { kind ?? .desktop }
}

struct DisplayLayout: Codable {
    var displayUUID: String
    var displayName: String
    var spaceCount: Int
    var activeSpaceIndex: Int
    var spaces: [SpaceLayout]

    /// Number of Desktop Spaces actually required to host all recorded non-empty Desktop spaces on this display.
    var requiredDesktopSpaceCount: Int {
        let nonEmptyDesktops = spaces.filter { $0.effectiveKind == .desktop && !$0.windows.isEmpty }
        if spaces.allSatisfy({ $0.effectiveKind == .desktop }) {
            return nonEmptyDesktops.map { $0.spaceIndex + 1 }.max() ?? 0
        }
        return nonEmptyDesktops.count
    }

    /// Total non-empty Spaces recorded on this display (Desktop + Fullscreen + Split).
    var requiredSpaceCount: Int {
        spaces.filter { !$0.windows.isEmpty }.count
    }
}

struct SpaceBootProfile: Codable {
    var name: String
    var updatedAt: String
    var displays: [DisplayLayout]
    /// ⌥1–⌥9 order of this profile's recorded Spaces (display + recorded Space index), chosen right after
    /// recording and applied whenever the profile boots. Absent in profiles recorded before this existed.
    var hotkeyOrder: [SpaceSlotKey]? = nil

    var totalWindowCount: Int {
        displays.reduce(0) { sum, d in
            sum + d.spaces.reduce(0) { $0 + $1.windows.count }
        }
    }

    var totalSpaceCount: Int {
        displays.reduce(0) { $0 + $1.requiredSpaceCount }
    }
}

// MARK: - Live Runtime Snapshot Models

struct LiveTileInfo {
    let windowId: Int
    let pid: pid_t
    let tileSpaceId: Int
    let tileType: String
    let tileRect: WindowRect
}

struct LiveSpaceInfo {
    let id: Int
    let kind: SpaceKind
    /// Empty for `.desktop`; 1 tile for `.fullscreen`; 2 tiles sorted left-to-right by `tileRect.x` for `.split`.
    let tiles: [LiveTileInfo]
    let layoutRect: WindowRect?
    let interTileSpacing: Int

    var splitRatio: Double? {
        guard kind == .split, tiles.count >= 2 else { return nil }
        let totalWidth = Double(tiles[0].tileRect.width + tiles[1].tileRect.width)
        guard totalWidth > 0 else { return nil }
        return (Double(tiles[0].tileRect.width) / totalWidth * 1000.0).rounded() / 1000.0
    }
}

struct LiveDisplayInfo {
    let uuid: String
    let name: String
    let cgFrame: CGRect
    /// All managed Spaces (`.desktop`, `.fullscreen`, `.split`) in Mission Control left-to-right order.
    let spaces: [LiveSpaceInfo]
    let currentSpaceId: Int

    var allSpaceIds: [Int] { spaces.map(\.id) }
    var desktopSpaceIds: [Int] { spaces.filter { $0.kind == .desktop }.map(\.id) }
    var currentSpace: LiveSpaceInfo? { spaces.first { $0.id == currentSpaceId } }
    var currentSpaceIndex: Int? { spaces.firstIndex { $0.id == currentSpaceId } }
    var currentDesktopIndex: Int? { desktopSpaceIds.firstIndex(of: currentSpaceId) }

    var cgCenter: CGPoint {
        CGPoint(x: cgFrame.midX, y: cgFrame.midY)
    }
}

struct AXWindowMeta {
    let role: String
    let subrole: String
    let title: String
    let isSizeSettable: Bool
    let isPositionSettable: Bool
    let isMinimized: Bool
    let isFullScreen: Bool

    var isStandardMainWindow: Bool {
        role == "AXWindow" && (subrole == "AXStandardWindow" || isFullScreen) && !isMinimized
    }
}

struct LiveWindowInfo {
    let windowId: Int
    let pid: pid_t
    let appId: String
    let appName: String
    let title: String
    let frame: WindowRect
    let spaceIds: [Int]
    let zIndex: Int
    let isOnscreen: Bool
}
