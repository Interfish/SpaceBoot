import Cocoa
import ApplicationServices
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let inspector = SpaceInspector()
    private lazy var controller = WindowController(inspector: inspector)
    private lazy var profileManager = ProfileManager(inspector: inspector, controller: controller)

    private var statusItem: NSStatusItem!
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(busy: false)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
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

            for d in liveDisplays {
                let activeIdx = (d.currentSpaceIndex ?? 0) + 1
                let count = d.desktopSpaceIds.count
                let spaceWord = count == 1 ? "Space" : "Spaces"
                let info = NSMenuItem(
                    title: "  \(d.name): \(count) \(spaceWord) (Desktop \(activeIdx))",
                    action: nil,
                    keyEquivalent: ""
                )
                info.isEnabled = false
                menu.addItem(info)
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

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SpaceBoot", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

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
        performApply(named: name, launchMissing: true)
    }

    @objc private func handleRepositionProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        performApply(named: name, launchMissing: false)
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

        Optional tips:
        • Enable "Reduce motion" in System Settings → Accessibility → Display for faster Space transitions.
        • Bind Option+1/2/3/4 in System Settings → Keyboard Shortcuts → Mission Control.
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

    @objc private func handleQuit() {
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
            showErrorAlert(title: "Record Failed", message: error.localizedDescription)
        }
    }

    private func performApply(named name: String, launchMissing: Bool) {
        guard let profile = profileManager.loadProfile(named: name) else { return }
        if !AXIsProcessTrusted() {
            handleRequestAccessibility()
            showErrorAlert(title: "Accessibility Required", message: ProfileActionError.missingAccessibility.localizedDescription)
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
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.showErrorAlert(title: "Unable to Boot \"\(profile.name)\"", message: error.localizedDescription)
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
