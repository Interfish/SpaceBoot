import Foundation

// MARK: - App Constants

enum SpaceBootConfig {
    static let appName = "SpaceBoot"
    static let bundleIdentifier = "com.spaceboot.SpaceBoot"
    static let profilesDirectory = "\(NSHomeDirectory())/.config/spaceboot/profiles"
    static let chromeExecutablePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    static let minimumWindowWidth: Double = 150
    static let minimumWindowHeight: Double = 150
    static let normalWindowLayer = 0
    static let desktopSpaceType = 0

    static let spaceSwitchTimeoutSeconds: TimeInterval = 2.0
    static let spaceSwitchPollMicros: useconds_t = 80_000
    static let spaceAnimationSettleMicros: useconds_t = 400_000
    static let launchWindowTimeoutSeconds: TimeInterval = 10.0
    static let launchPollMicros: useconds_t = 300_000
    static let raiseWindowDelayMicros: useconds_t = 70_000

    /// System/helper processes excluded from recorded layouts.
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

    /// Sub-browsers or child apps launched by a parent host app rather than standalone.
    static let hostManagedBundleIds: Set<String> = [
        "com.adspower.SunBrowser",
        "org.mozilla.FlowerBrowser"
    ]

    /// Resolves the Cursor CLI binary across common installation locations.
    static func resolveCursorCliPath() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/cursor",
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Persisted Profile Schema

struct WindowRect: Codable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct LaunchConfig: Codable, Equatable {
    /// Supported kinds: "app" | "chrome_new_window" | "cursor_new_window" | "cursor_uri"
    var kind: String
    /// App path (for "app"), optional URL (for "chrome_new_window"), or workspace URI (for "cursor_uri").
    var target: String
}

struct WindowRecord: Codable {
    var appId: String
    var appName: String
    var titleHint: String?
    var frame: WindowRect
    var zIndex: Int
    var launch: LaunchConfig?
}

struct SpaceLayout: Codable {
    /// 0-based Desktop index on this display (excluding fullscreen spaces).
    var spaceIndex: Int
    var windows: [WindowRecord]
}

struct DisplayLayout: Codable {
    var displayUUID: String
    var displayName: String
    var spaceCount: Int
    var activeSpaceIndex: Int
    var spaces: [SpaceLayout]
}

struct SpaceBootProfile: Codable {
    var name: String
    var updatedAt: String
    var displays: [DisplayLayout]

    var totalWindowCount: Int {
        displays.reduce(0) { sum, d in
            sum + d.spaces.reduce(0) { $0 + $1.windows.count }
        }
    }

    var totalSpaceCount: Int {
        displays.reduce(0) { $0 + $1.spaceCount }
    }
}

// MARK: - Live Runtime Snapshot Models

struct LiveDisplayInfo {
    let uuid: String
    let name: String
    let cgFrame: CGRect
    /// Ordered normal desktop space IDs (type == 0), left-to-right.
    let desktopSpaceIds: [Int]
    let currentSpaceId: Int

    var currentSpaceIndex: Int? {
        desktopSpaceIds.firstIndex(of: currentSpaceId)
    }

    var cgCenter: CGPoint {
        CGPoint(x: cgFrame.midX, y: cgFrame.midY)
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
}
