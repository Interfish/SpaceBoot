import Cocoa
import ApplicationServices
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let hotKeysPrefKey = "SpaceBootGlobalHotKeysEnabled"
    private static let globalScopePrefKey = "SpaceBootHotKeyGlobalScope"

    private let inspector = SpaceInspector()
    private lazy var controller = WindowController(inspector: inspector)
    private lazy var profileManager = ProfileManager(inspector: inspector, controller: controller)
    private let hotKeyManager = HotKeyManager()
    private let interactiveSwitchQueue = DispatchQueue(label: "com.spaceboot.interactive-switch", qos: .userInteractive)

    private var statusItem: NSStatusItem!
    private var isBusy = false
    private var isSwitchingSpace = false

    private var hotKeysEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.hotKeysPrefKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.hotKeysPrefKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.hotKeysPrefKey)
        }
    }

    /// false (default): ⌥1..⌥9 switch Spaces 1..9 on the display under the mouse cursor.
    /// true: ⌥1..⌥9 switch global Desktop 1..9 sequentially across all displays.
    private var useGlobalDesktopScope: Bool {
        get { UserDefaults.standard.bool(forKey: Self.globalScopePrefKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.globalScopePrefKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(busy: false)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        SpaceBootLogger.log("SpaceBoot launched. AXIsProcessTrusted=\(AXIsProcessTrusted())")
        registerDistributedCommands()
        syncHotKeysState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager.unregister()
    }

    // MARK: - Runtime Global Hotkeys (Option+1..9 & Option+Shift+B)

    private func syncHotKeysState() {
        if hotKeysEnabled {
            hotKeyManager.register { [weak self] action in
                self?.handleHotKeyAction(action)
            }
        } else {
            hotKeyManager.unregister()
        }
    }

    private func handleHotKeyAction(_ action: HotKeyAction) {
        guard !isBusy else { return }

        switch action {
        case .switchDesktop(let index):
            guard !isSwitchingSpace else { return }
            isSwitchingSpace = true
            let useGlobal = useGlobalDesktopScope
            interactiveSwitchQueue.async { [weak self] in
                defer {
                    DispatchQueue.main.async { self?.isSwitchingSpace = false }
                }
                guard let self = self else { return }
                if !AXIsProcessTrusted() {
                    SpaceBootLogger.log("Hotkey ⌥\(index + 1) ignored: AXIsProcessTrusted is false")
                    return
                }
                if useGlobal {
                    _ = self.controller.switchToGlobalDesktop(index: index)
                } else {
                    _ = self.controller.switchActiveDisplay(toSpaceIndex: index)
                }
            }

        case .bootMatchingProfile:
            let liveDisplays = inspector.listDisplays()
            let profiles = profileManager.listProfiles()
            if let matching = profiles.first(where: { profile in
                profile.displays.count == liveDisplays.count &&
                profile.displays.allSatisfy { inspector.matchLiveDisplay(for: $0, in: liveDisplays) != nil }
            }) ?? profiles.first(where: { profile in
                profile.displays.allSatisfy { inspector.matchLiveDisplay(for: $0, in: liveDisplays) != nil }
            }) {
                SpaceBootLogger.log("Hotkey ⌥⇧B booting matched profile '\(matching.name)'")
                performApply(named: matching.name, launchMissing: true, silentErrors: false)
            } else {
                sendNotification(title: "SpaceBoot", body: "No saved profile matches the currently connected displays.")
            }
        }
    }

    // MARK: - Distributed Notification IPC (for CLI / automation triggers)

    private func registerDistributedCommands() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedCommand(_:)),
            name: Notification.Name("com.spaceboot.command"),
            object: nil
        )
    }

    @objc private func handleDistributedCommand(_ notification: Notification) {
        guard let payload = notification.object as? String else { return }
        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
        let action = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""

        SpaceBootLogger.log("IPC command received: action=\(action) arg=\(arg)")

        switch action {
        case "inspect":
            DispatchQueue.global(qos: .userInitiated).async {
                self.profileManager.dumpDiagnostics()
            }
        case "switch":
            if let oneBased = Int(arg), oneBased >= 1 {
                handleHotKeyAction(.switchDesktop(globalIndex: oneBased - 1))
            }
        case "record":
            guard !arg.isEmpty else { return }
            performRecord(named: arg)
        case "boot":
            guard !arg.isEmpty else { return }
            performApply(named: arg, launchMissing: true, silentErrors: true)
        case "restore":
            guard !arg.isEmpty else { return }
            performApply(named: arg, launchMissing: false, silentErrors: true)
        default:
            break
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let liveDisplays = inspector.listDisplays()

        if liveDisplays.isEmpty {
            let empty = NSMenuItem(title: "No Displays Detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Active Displays & Spaces", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            var globalDesktopNumber = 1
            for d in liveDisplays {
                let displayHeader = NSMenuItem(title: "  \(d.name)", action: nil, keyEquivalent: "")
                displayHeader.isEnabled = false
                menu.addItem(displayHeader)

                for (localIdx, spaceId) in d.desktopSpaceIds.enumerated() {
                    let isCurrent = (spaceId == d.currentSpaceId)
                    let marker = isCurrent ? "●" : "○"
                    let displayNumber = useGlobalDesktopScope ? globalDesktopNumber : (localIdx + 1)
                    let keyHint = (hotKeysEnabled && displayNumber <= 9) ? "\(displayNumber)" : ""
                    let title = useGlobalDesktopScope
                        ? "    \(marker) Desktop \(globalDesktopNumber) (Space \(localIdx + 1))"
                        : "    \(marker) Space \(localIdx + 1)"
                    let item = NSMenuItem(
                        title: title,
                        action: #selector(handleSwitchDesktopMenu(_:)),
                        keyEquivalent: keyHint
                    )
                    if !keyHint.isEmpty {
                        item.keyEquivalentModifierMask = .option
                    }
                    item.representedObject = (d.uuid, localIdx)
                    item.target = self
                    item.isEnabled = !isBusy
                    menu.addItem(item)
                    globalDesktopNumber += 1
                }
            }
        }

        menu.addItem(.separator())

        let profiles = profileManager.listProfiles()
        if profiles.isEmpty {
            let none = NSMenuItem(title: "No Profiles Yet — Click \"New Profile & Record\"", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let section = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
            section.isEnabled = false
            menu.addItem(section)

            for profile in profiles {
                let allDisplaysMatch = profile.displays.allSatisfy { saved in
                    inspector.matchLiveDisplay(for: saved, in: liveDisplays) != nil
                }
                let statusMark = allDisplaysMatch ? "●" : "○"
                let summary = "\(statusMark) \(profile.name) (\(profile.displays.count)D · \(profile.totalSpaceCount)S · \(profile.totalWindowCount)W)"

                let item = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
                let sub = NSMenu()

                let launchItem = NSMenuItem(title: "Boot Profile (Launch & Arrange)", action: #selector(handleLaunchProfile(_:)), keyEquivalent: "")
                launchItem.representedObject = profile.name
                launchItem.target = self
                launchItem.isEnabled = !isBusy
                sub.addItem(launchItem)

                let repositionItem = NSMenuItem(title: "Restore Open Windows Only", action: #selector(handleRepositionProfile(_:)), keyEquivalent: "")
                repositionItem.representedObject = profile.name
                repositionItem.target = self
                repositionItem.isEnabled = !isBusy
                sub.addItem(repositionItem)

                sub.addItem(.separator())

                let recordItem = NSMenuItem(title: "Record Current Layout (Overwrite)", action: #selector(handleOverwriteRecord(_:)), keyEquivalent: "")
                recordItem.representedObject = profile.name
                recordItem.target = self
                recordItem.isEnabled = !isBusy
                sub.addItem(recordItem)

                let revealItem = NSMenuItem(title: "Edit Profile JSON…", action: #selector(handleRevealProfile(_:)), keyEquivalent: "")
                revealItem.representedObject = profile.name
                revealItem.target = self
                sub.addItem(revealItem)

                sub.addItem(.separator())

                let deleteItem = NSMenuItem(title: "Delete Profile…", action: #selector(handleDeleteProfile(_:)), keyEquivalent: "")
                deleteItem.representedObject = profile.name
                deleteItem.target = self
                sub.addItem(deleteItem)

                item.submenu = sub
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let newItem = NSMenuItem(title: "New Profile & Record…", action: #selector(handleNewProfile), keyEquivalent: "n")
        newItem.target = self
        newItem.isEnabled = !isBusy
        menu.addItem(newItem)

        let hotKeyToggle = NSMenuItem(
            title: "Global Hotkeys (⌥1–⌥9 Switch · ⌥⇧B Boot)",
            action: #selector(handleToggleHotKeys),
            keyEquivalent: ""
        )
        hotKeyToggle.target = self
        hotKeyToggle.state = hotKeysEnabled ? .on : .off
        menu.addItem(hotKeyToggle)

        if hotKeysEnabled {
            let scopeTitle = useGlobalDesktopScope
                ? "  Scope: All Displays (Global Desktop 1–9)"
                : "  Scope: Display Under Mouse (Space 1–9)"
            let scopeItem = NSMenuItem(
                title: scopeTitle,
                action: #selector(handleToggleHotKeyScope),
                keyEquivalent: ""
            )
            scopeItem.target = self
            menu.addItem(scopeItem)
        }

        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let axItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(handleRequestAccessibility), keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
        }

        let settingsItem = NSMenuItem(title: "Optimize macOS Spaces Settings…", action: #selector(handleOptimizeSpaceSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let openDirItem = NSMenuItem(title: "Open Profiles Folder", action: #selector(handleOpenProfilesFolder), keyEquivalent: "")
        openDirItem.target = self
        menu.addItem(openDirItem)

        let openLogItem = NSMenuItem(title: "Open Log File", action: #selector(handleOpenLogFile), keyEquivalent: "")
        openLogItem.target = self
        menu.addItem(openLogItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SpaceBoot", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func handleSwitchDesktopMenu(_ sender: NSMenuItem) {
        guard !isBusy, !isSwitchingSpace,
              let target = sender.representedObject as? (String, Int) else { return }
        isSwitchingSpace = true
        interactiveSwitchQueue.async { [weak self] in
            defer { DispatchQueue.main.async { self?.isSwitchingSpace = false } }
            _ = self?.controller.switchDisplay(target.0, toSpaceIndex: target.1, settleForLaunch: false)
        }
    }

    @objc private func handleToggleHotKeys() {
        hotKeysEnabled.toggle()
        syncHotKeysState()
    }

    @objc private func handleToggleHotKeyScope() {
        useGlobalDesktopScope.toggle()
    }

    @objc private func handleNewProfile() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "New Profile & Record Layout"
        alert.informativeText = "Enter a profile name (e.g. dual-monitor or laptop). SpaceBoot will snapshot every connected display, its Desktop Spaces count, and all window frames and stacking order."
        alert.addButton(withTitle: "Record & Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "e.g. dual-monitor"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        performRecord(named: name)
    }

    @objc private func handleOverwriteRecord(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        performRecord(named: name)
    }

    @objc private func handleLaunchProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        performApply(named: name, launchMissing: true, silentErrors: false)
    }

    @objc private func handleRepositionProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        performApply(named: name, launchMissing: false, silentErrors: false)
    }

    @objc private func handleRevealProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let url = profileManager.profileURL(named: name)
        NSWorkspace.shared.open(url)
    }

    @objc private func handleDeleteProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Delete profile \"\(name)\"?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? profileManager.deleteProfile(named: name)
    }

    @objc private func handleRequestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func handleOptimizeSpaceSettings() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Recommended macOS Spaces Settings"
        alert.informativeText = """
        For reliable Space booting with native macOS Spaces, SpaceBoot recommends disabling two Dock defaults:
        1. Automatically rearrange Spaces based on most recent use (keeps Desktop 1/2/3 order fixed)
        2. When switching to an application, switch to a Space with open windows (keeps new browser windows on the active Space)

        Optional tip:
        • Enable "Reduce motion" in System Settings → Accessibility → Display for faster Space transitions.
        """
        alert.addButton(withTitle: "Apply & Restart Dock")
        alert.addButton(withTitle: "Open Display Accessibility")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            runShell("/usr/bin/defaults", ["write", "com.apple.dock", "mru-spaces", "-bool", "false"])
            runShell("/usr/bin/defaults", ["write", "com.apple.dock", "workspaces-auto-swoosh", "-bool", "false"])
            runShell("/usr/bin/killall", ["Dock"])
            sendNotification(title: "SpaceBoot", body: "Updated macOS Spaces settings and restarted Dock.")
        } else if response == .alertSecondButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func handleOpenProfilesFolder() {
        let url = URL(fileURLWithPath: SpaceBootConfig.profilesDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func handleOpenLogFile() {
        let url = URL(fileURLWithPath: SpaceBootLogger.logFilePath)
        if !FileManager.default.fileExists(atPath: url.path) {
            SpaceBootLogger.log("Log opened.")
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func handleQuit() {
        hotKeyManager.unregister()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Execution Runners

    private func performRecord(named name: String) {
        do {
            let profile = try profileManager.recordProfile(named: name)
            let detail = profile.displays
                .map { "\($0.displayName) (\($0.spaceCount)S)" }
                .joined(separator: " + ")
            sendNotification(
                title: "SpaceBoot Recorded",
                body: "\"\(profile.name)\" saved \(profile.totalWindowCount) windows — \(detail)"
            )
        } catch {
            SpaceBootLogger.log("Record error: \(error.localizedDescription)")
            showErrorAlert(title: "Record Failed", message: error.localizedDescription)
        }
    }

    private func performApply(named name: String, launchMissing: Bool, silentErrors: Bool) {
        guard let profile = profileManager.loadProfile(named: name) else { return }
        if !AXIsProcessTrusted() {
            SpaceBootLogger.log("Apply aborted: AXIsProcessTrusted is false")
            if !silentErrors {
                handleRequestAccessibility()
                showAccessibilityAlert()
            }
            return
        }

        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.profileManager.applyProfile(profile, launchMissing: launchMissing)
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.sendNotification(
                        title: "SpaceBoot Complete",
                        body: "\"\(profile.name)\" restored \(result.matched)/\(result.total) windows."
                    )
                }
            } catch let actionError as ProfileActionError {
                SpaceBootLogger.log("Apply error: \(actionError.localizedDescription)")
                DispatchQueue.main.async {
                    self.setBusy(false)
                    if !silentErrors {
                        if case .insufficientSpaces = actionError {
                            self.showInsufficientSpacesAlert(message: actionError.localizedDescription)
                        } else {
                            self.showErrorAlert(title: "Unable to Boot \"\(profile.name)\"", message: actionError.localizedDescription)
                        }
                    }
                }
            } catch {
                SpaceBootLogger.log("Apply error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.setBusy(false)
                    if !silentErrors {
                        self.showErrorAlert(title: "Unable to Boot \"\(profile.name)\"", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        updateStatusIcon(busy: busy)
    }

    private func updateStatusIcon(busy: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = busy ? "hourglass" : "bolt.horizontal.circle"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: SpaceBootConfig.appName) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.title = busy ? "…" : "SB"
        }
    }

    private func showAccessibilityAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Required"
        alert.informativeText = ProfileActionError.missingAccessibility.localizedDescription
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showInsufficientSpacesAlert(message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Not Enough Desktop Spaces"
        alert.informativeText = message
        alert.addButton(withTitle: "Open Mission Control")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            runShell("/usr/bin/open", ["-a", "Mission Control"])
        }
    }

    private func showErrorAlert(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func sendNotification(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        runShell("/usr/bin/osascript", ["-e", "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""])
    }

    private func runShell(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
