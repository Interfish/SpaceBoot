import Cocoa
import ApplicationServices
import Foundation

enum LaunchAttemptOutcome {
    /// A launch or new-window trigger was dispatched; caller should wait for a new window to appear.
    case triggered
    /// The app is already running with window(s) and exposes no "New Window" action (single-window app).
    case singleWindowAlreadyOpen
    /// Target could not be resolved or executed.
    case failed(String)
}

/// Universal, zero-hardcoding macOS application & window launcher:
/// - Cold launch: uses LaunchServices (`NSWorkspace.openApplication`) identically to clicking in Finder/Spotlight.
/// - Warm new window: inspects the running app's `AXMenuBar` and presses its localized "New Window" item.
/// - Custom command: executes inside the user's real login shell (`$SHELL -l -c`) with full `$PATH` and profile.
final class AppLauncher {
    /// Exact localized titles for creating a standard new window across common macOS languages.
    private static let exactNewWindowTitles: Set<String> = [
        "new window",
        "new browser window",
        "new editor window",
        "new finder window",
        "new terminal window",
        "新建窗口",
        "新增視窗",
        "新規ウインドウ",
        "neues fenster",
        "nouvelle fenêtre",
        "nueva ventana",
        "새 창"
    ]

    /// Substrings that indicate a private/incognito/tab/profile action rather than a standard window.
    private static let excludedMenuKeywords: [String] = [
        "incognito", "private", "inprivate", "guest", "tab", "profile", "split", "workspace",
        "无痕", "隐私", "访客", "标签", "無痕", "隱私", "シークレット", "プライベート", "タブ"
    ]

    /// Substrings that identify a window-creation menu item when falling back to Cmd+N shortcut detection.
    private static let windowHintKeywords: [String] = [
        "window", "窗口", "視窗", "ウインドウ", "fenster", "fenêtre", "ventana", "창"
    ]

    /// True if `spec` starts a regular app bundle (as opposed to a shell command).
    static func isAppBundleLaunch(_ spec: LaunchConfig) -> Bool {
        ["app", "chrome_new_window", "cursor_new_window"].contains(spec.kind)
    }

    /// Cold-starts the app behind `spec` without activating it, unless it is already running.
    /// Background launches keep a starting app from grabbing focus while SpaceBoot is switching Spaces.
    /// Returns nil when there was nothing to launch (already running, or a shell-command spec).
    func coldLaunchIfNeeded(appId: String, spec: LaunchConfig) -> LaunchAttemptOutcome? {
        let appPath: String
        var url: String?
        switch spec.kind {
        case "app":
            appPath = spec.target
            url = spec.url
        case "chrome_new_window":
            appPath = "/Applications/Google Chrome.app"
            url = spec.target
        case "cursor_new_window":
            appPath = "/Applications/Cursor.app"
        default:
            return nil
        }

        guard NSRunningApplication.runningApplications(withBundleIdentifier: appId).isEmpty else { return nil }
        guard let appURL = resolveApplicationURL(appId: appId, preferredPath: appPath) else {
            return .failed("Application not found for \(appId) (\(appPath))")
        }
        return coldLaunchViaLaunchServices(appURL: appURL, optionalURL: url, activates: false)
    }

    /// Launches a missing window for `appId` using `spec`.
    func launchWindow(appId: String, spec: LaunchConfig, appAlreadyHasWindow: Bool) -> LaunchAttemptOutcome {
        switch spec.kind {
        case "command":
            return launchInLoginShell(command: spec.target)

        case "app":
            return launchAppWindow(appId: appId, appPath: spec.target, optionalURL: spec.url, appAlreadyHasWindow: appAlreadyHasWindow)

        // Legacy profile compatibility: normalize older recorded kinds transparently to universal launch.
        case "chrome_new_window":
            let url = spec.target.trimmingCharacters(in: .whitespacesAndNewlines)
            return launchAppWindow(
                appId: appId,
                appPath: "/Applications/Google Chrome.app",
                optionalURL: url.isEmpty ? nil : url,
                appAlreadyHasWindow: appAlreadyHasWindow
            )

        case "cursor_new_window":
            return launchAppWindow(appId: appId, appPath: "/Applications/Cursor.app", optionalURL: nil, appAlreadyHasWindow: appAlreadyHasWindow)

        case "cursor_uri":
            let escaped = spec.target.replacingOccurrences(of: "'", with: "'\\''")
            return launchInLoginShell(command: "cursor --file-uri '\(escaped)'")

        default:
            return .failed("Unsupported launch kind: \(spec.kind)")
        }
    }

    // MARK: - Universal App Launch (Cold vs Warm)

    private func launchAppWindow(
        appId: String,
        appPath: String,
        optionalURL: String?,
        appAlreadyHasWindow: Bool
    ) -> LaunchAttemptOutcome {
        guard let appURL = resolveApplicationURL(appId: appId, preferredPath: appPath) else {
            return .failed("Application not found for \(appId) (\(appPath))")
        }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appId)

        // Case 1: App is NOT running -> Cold launch via LaunchServices (exact user double-click environment).
        if runningApps.isEmpty {
            return coldLaunchViaLaunchServices(appURL: appURL, optionalURL: optionalURL)
        }

        // Case 2: App IS running and an explicit URL/file was requested -> ask LaunchServices to open URL with app.
        if let urlStr = optionalURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !urlStr.isEmpty,
           let targetURL = URL(string: urlStr) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            SpaceBootLogger.log("AppLauncher: opened URL with running app \(appURL.lastPathComponent)")
            return .triggered
        }

        // Case 3: App IS running -> trigger its native File -> New Window menu item via AXMenuBar.
        if let runningApp = runningApps.first {
            if triggerNewWindowMenuItem(pid: runningApp.processIdentifier, appName: appURL.lastPathComponent) {
                return .triggered
            }

            // Some apps populate their File submenu lazily only when activated; retry once after activation.
            runningApp.activate()
            usleep(150_000)
            if triggerNewWindowMenuItem(pid: runningApp.processIdentifier, appName: appURL.lastPathComponent) {
                return .triggered
            }

            // If the app is running with 0 open windows (e.g., all windows closed with Cmd+W),
            // opening via LaunchServices reopens its default main window (Finder, Mail, WeChat, Activity Monitor, etc.).
            if !appAlreadyHasWindow {
                SpaceBootLogger.log("AppLauncher: no New Window menu item found for \(appURL.lastPathComponent) (0 open windows); reopening via LaunchServices")
                return coldLaunchViaLaunchServices(appURL: appURL, optionalURL: nil)
            }

            SpaceBootLogger.log("AppLauncher: \(appURL.lastPathComponent) already has open window(s) and exposes no New Window menu item; treating as single-window app")
            return .singleWindowAlreadyOpen
        }

        return coldLaunchViaLaunchServices(appURL: appURL, optionalURL: optionalURL)
    }

    private func coldLaunchViaLaunchServices(appURL: URL, optionalURL: String?, activates: Bool = true) -> LaunchAttemptOutcome {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates

        if let urlStr = optionalURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !urlStr.isEmpty,
           let targetURL = URL(string: urlStr) {
            NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            SpaceBootLogger.log("AppLauncher: cold-launched \(appURL.lastPathComponent) with URL via LaunchServices")
            return .triggered
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        SpaceBootLogger.log("AppLauncher: cold-launched \(appURL.lastPathComponent) via LaunchServices")
        return .triggered
    }

    private func resolveApplicationURL(appId: String, preferredPath: String) -> URL? {
        if !preferredPath.isEmpty && FileManager.default.fileExists(atPath: preferredPath) {
            return URL(fileURLWithPath: preferredPath)
        }
        if !appId.isEmpty, let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appId) {
            return resolved
        }
        return nil
    }

    // MARK: - Generic AXMenuBar "New Window" Trigger

    /// Inspects `pid`'s macOS menu bar and invokes its standard "New Window" menu item via AXPress.
    /// Works universally across Chromium, Electron, WebKit, AppKit, and terminal apps without app-specific flags.
    private func triggerNewWindowMenuItem(pid: pid_t, appName: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            SpaceBootLogger.log("AppLauncher: AXMenuBar unavailable for \(appName) (pid=\(pid))")
            return false
        }

        let menuBarElement = menuBar as! AXUIElement
        var barItemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBarElement, kAXChildrenAttribute as CFString, &barItemsRef) == .success,
              let topBarItems = barItemsRef as? [AXUIElement] else {
            return false
        }

        // Collect all enabled top-level menu items (skipping Apple menu at index 0 and App menu at index 1).
        var menuItems: [(element: AXUIElement, title: String, cmdChar: String)] = []
        for topItem in topBarItems.dropFirst(2) {
            for item in directMenuItems(of: topItem) {
                guard isAXElementEnabled(item) else { continue }
                let title = copyAXString(item, kAXTitleAttribute) ?? ""
                guard !title.isEmpty else { continue }
                let cmdChar = copyAXString(item, kAXMenuItemCmdCharAttribute) ?? ""
                menuItems.append((item, title, cmdChar))
            }
        }

        // Pass 1: Exact localized "New Window" match (handles Chrome Cmd+N, Cursor/VS Code Cmd+Shift+N, Safari, Finder, etc.).
        if let exact = menuItems.first(where: { entry in
            let normalized = normalizeMenuTitle(entry.title)
            return Self.exactNewWindowTitles.contains(normalized) && !containsExcludedKeyword(normalized)
        }) {
            let err = AXUIElementPerformAction(exact.element, kAXPressAction as CFString)
            SpaceBootLogger.log("AppLauncher: AXPress menu '\(exact.title)' on \(appName) -> err=\(err.rawValue)")
            return err == .success
        }

        // Pass 2: Any menu item with shortcut N whose title mentions "window" (and isn't private/incognito/tab).
        if let fallback = menuItems.first(where: { entry in
            let normalized = normalizeMenuTitle(entry.title)
            let isN = entry.cmdChar.caseInsensitiveCompare("N") == .orderedSame
            let mentionsWindow = Self.windowHintKeywords.contains(where: { normalized.contains($0) })
            return isN && mentionsWindow && !containsExcludedKeyword(normalized)
        }) {
            let err = AXUIElementPerformAction(fallback.element, kAXPressAction as CFString)
            SpaceBootLogger.log("AppLauncher: AXPress fallback menu '\(fallback.title)' (cmd=\(fallback.cmdChar)) on \(appName) -> err=\(err.rawValue)")
            return err == .success
        }

        return false
    }

    private func directMenuItems(of menuBarItem: AXUIElement) -> [AXUIElement] {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBarItem, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement],
              let submenu = children.first else {
            return []
        }

        var itemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(submenu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
              let items = itemsRef as? [AXUIElement] else {
            return []
        }
        return items
    }

    private func normalizeMenuTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func containsExcludedKeyword(_ normalizedTitle: String) -> Bool {
        Self.excludedMenuKeywords.contains { normalizedTitle.contains($0) }
    }

    private func copyAXString(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func isAXElementEnabled(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &ref) == .success else {
            return true
        }
        return (ref as? Bool) ?? true
    }

    // MARK: - User Login Shell Command Launcher

    private func launchInLoginShell(command: String) -> LaunchAttemptOutcome {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Empty command") }

        let loginShell = ProcessInfo.processInfo.environment["SHELL"]
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        // Run as login + interactive-friendly shell so ~/.zprofile / ~/.zshrc PATH & user wrappers are loaded.
        process.arguments = ["-l", "-c", trimmed]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            SpaceBootLogger.log("AppLauncher: executed login shell command via \(loginShell)")
            return .triggered
        } catch {
            return .failed("Failed to run shell command: \(error.localizedDescription)")
        }
    }
}
