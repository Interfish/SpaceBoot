import Cocoa
import Foundation

/// Represents a native Fullscreen (1 window) or Split View (2 windows) Space to assemble or adjust during a boot.
final class FullScreenGroup {
    let displayUUID: String
    let displayName: String
    let kind: SpaceKind
    let splitRatio: Double?
    let stagingSpaceId: Int
    let isHomeSpace: Bool
    var memberSlots: [BootSlot] = []
    var liveFullScreenSpaceId: Int?
    var completed = false
    var attempts = 0
    var notBefore: Date?

    init(
        displayUUID: String,
        displayName: String,
        kind: SpaceKind,
        splitRatio: Double?,
        stagingSpaceId: Int,
        isHomeSpace: Bool
    ) {
        self.displayUUID = displayUUID
        self.displayName = displayName
        self.kind = kind
        self.splitRatio = splitRatio
        self.stagingSpaceId = stagingSpaceId
        self.isHomeSpace = isHomeSpace
    }

    var label: String {
        let names = memberSlots.map(\.record.appName).joined(separator: " | ")
        return "\(kind.rawValue) [\(names)] → \(displayName)"
    }
}

/// A profile window resolved against the live displays when a boot starts.
/// Targets are bound to Space IDs (not positions), so macOS reordering Spaces mid-boot cannot redirect windows.
final class BootSlot {
    let record: WindowRecord
    let order: Int
    let displayUUID: String
    let displayName: String
    let spaceIndex: Int
    let targetSpaceId: Int
    let isHomeSpace: Bool
    let isFullScreenMember: Bool
    weak var fullScreenGroup: FullScreenGroup?

    var windowId: Int?
    var pid: pid_t = 0
    var boundAt: Date?
    /// False while bound to a window whose Accessibility metadata could not be checked yet (it sat on a hidden Space).
    var verified = true
    var verifyAttempts = 0
    var placedAt: Date?
    /// Backoff after a failed placement attempt.
    var notBefore: Date?
    var placementFailures = 0
    var missingSince: Date?
    var expectedFrame: WindowRect
    var driftStreak = 0
    var relocations = 0
    var windowRequests = 0
    var requestSwitchFailures = 0
    /// While in the future, a launch / New Window request for this slot is still being answered.
    var requestInFlightUntil: Date?
    /// Cleared once a placed window closed: the slot then only waits for the app's own replacement window.
    var allowWindowRequests = true
    var waitDeadline: Date?
    var gaveUp = false

    init(
        record: WindowRecord,
        order: Int,
        displayUUID: String,
        displayName: String,
        spaceIndex: Int,
        targetSpaceId: Int,
        isHomeSpace: Bool,
        isFullScreenMember: Bool = false,
        fullScreenGroup: FullScreenGroup? = nil
    ) {
        self.record = record
        self.order = order
        self.displayUUID = displayUUID
        self.displayName = displayName
        self.spaceIndex = spaceIndex
        self.targetSpaceId = targetSpaceId
        self.isHomeSpace = isHomeSpace
        self.isFullScreenMember = isFullScreenMember
        self.fullScreenGroup = fullScreenGroup
        self.expectedFrame = record.frame
    }

    var appId: String { record.appId }
    /// Still waiting for a window.
    var isOpen: Bool { windowId == nil && !gaveUp }
    var awaitsPlacement: Bool { windowId != nil && placedAt == nil }
    var label: String { "\(record.appName) → \(displayName) space[\(spaceIndex)]" }
}

/// Event-driven boot pipeline:
/// 1. Every missing app is cold-launched up front (one per `coldLaunchStaggerSeconds`), without waiting on any Space.
/// 2. A single executor — the only code that switches Spaces or moves windows — places each window as soon as it is
///    ready. Windows that opened on the wrong Space are relocated (`WindowController.relocateWindow`), so a slow app
///    no longer lands on whatever Space happens to be visible when it finally opens.
/// 3. Once the fast apps are done, control returns to the user. Slow or login-gated apps (e.g. WeChat waiting for
///    "Enter WeChat") keep being watched in the background and are placed whenever their window shows up.
///
/// Apps whose display has several Desktops but no helper display to bounce through (single display, or every
/// other display in fullscreen) are instead launched on their own Space, which is held until their window opens.
final class BootSession {
    struct Summary {
        let placed: Int
        let total: Int
        /// Apps whose windows are still expected (foreground) or never arrived (background).
        let waitingApps: [String]
    }

    private enum HomeTarget {
        case desktop(displayUUID: String, spaceId: Int)
        case fullScreenGroup(displayUUID: String, group: FullScreenGroup)
    }

    private let inspector: SpaceInspector
    private let controller: WindowController
    private let launcher: AppLauncher
    private let profileName: String
    private let launchMissing: Bool
    private let slots: [BootSlot]
    private let fullScreenGroups: [FullScreenGroup]
    private let homeTargets: [HomeTarget]
    private let managedSpaceIds: Set<Int>
    private let startedAt = Date()
    /// Cold apps that are not launched up front because a window of theirs could not be moved to its Space later.
    private var deferredApps: Set<String> = []

    /// Windows open before the boot; they are moved into place but never settle-guarded afterwards.
    private var preexistingIds: Set<Int> = []
    /// Windows that do not count as new arrivals.
    private var baselineIds: Set<Int> = []
    private var claimedIds: Set<Int> = []
    private var rejectedIds: Set<Int> = []
    private var runningAtStart: Set<String> = []
    private var lastArrivalAt: [String: Date] = [:]
    private var promptSince: [String: Date] = [:]
    private var promptNudges: [String: Int] = [:]
    private var foregroundEndedAt: Date?
    private var pendingAtForegroundEnd: [BootSlot] = []
    private var isBackground = false

    // Shared with the cold-launch thread.
    private let stateLock = NSLock()
    private var coldLaunchedAt: [String: Date] = [:]
    private var queuedColdLaunches: Set<String> = []
    private var failedLaunches: Set<String> = []
    private var cancelled = false

    init(
        profile: SpaceBootProfile,
        displayPairs: [(saved: DisplayLayout, live: LiveDisplayInfo)],
        launchMissing: Bool,
        inspector: SpaceInspector,
        controller: WindowController,
        launcher: AppLauncher
    ) {
        self.inspector = inspector
        self.controller = controller
        self.launcher = launcher
        self.profileName = profile.name
        self.launchMissing = launchMissing

        var slots: [BootSlot] = []
        var groups: [FullScreenGroup] = []
        var homes: [HomeTarget] = []

        for pair in displayPairs {
            let desktopIds = pair.live.desktopSpaceIds
            var desktopRank = 0
            var displayHome: HomeTarget?

            for space in pair.saved.spaces.sorted(by: { $0.spaceIndex < $1.spaceIndex }) where !space.windows.isEmpty {
                let isHome = space.spaceIndex == pair.saved.activeSpaceIndex
                switch space.effectiveKind {
                case .desktop:
                    guard desktopRank < desktopIds.count else { continue }
                    let targetSpaceId = desktopIds[desktopRank]
                    desktopRank += 1
                    for record in space.windows {
                        slots.append(BootSlot(
                            record: record,
                            order: slots.count,
                            displayUUID: pair.live.uuid,
                            displayName: pair.saved.displayName,
                            spaceIndex: space.spaceIndex,
                            targetSpaceId: targetSpaceId,
                            isHomeSpace: isHome
                        ))
                    }
                    if isHome {
                        displayHome = .desktop(displayUUID: pair.live.uuid, spaceId: targetSpaceId)
                    }

                case .fullscreen, .split:
                    guard let stagingId = desktopIds.last else { continue }
                    let groupKind: SpaceKind = (space.effectiveKind == .split && space.windows.count >= 2) ? .split : .fullscreen
                    let group = FullScreenGroup(
                        displayUUID: pair.live.uuid,
                        displayName: pair.saved.displayName,
                        kind: groupKind,
                        splitRatio: groupKind == .split ? space.splitRatio : nil,
                        stagingSpaceId: stagingId,
                        isHomeSpace: isHome
                    )
                    let targetRecords = groupKind == .split ? Array(space.windows.prefix(2)) : Array(space.windows.prefix(1))
                    for record in targetRecords {
                        let slot = BootSlot(
                            record: record,
                            order: slots.count,
                            displayUUID: pair.live.uuid,
                            displayName: pair.saved.displayName,
                            spaceIndex: space.spaceIndex,
                            targetSpaceId: stagingId,
                            isHomeSpace: isHome,
                            isFullScreenMember: true,
                            fullScreenGroup: group
                        )
                        group.memberSlots.append(slot)
                        slots.append(slot)
                    }
                    groups.append(group)
                    if isHome {
                        displayHome = .fullScreenGroup(displayUUID: pair.live.uuid, group: group)
                    }
                }
            }

            if let displayHome {
                homes.append(displayHome)
            } else if !desktopIds.isEmpty {
                homes.append(.desktop(displayUUID: pair.live.uuid, spaceId: desktopIds[0]))
            }
        }
        self.slots = slots
        self.fullScreenGroups = groups
        self.homeTargets = homes
        self.managedSpaceIds = Set(slots.map(\.targetSpaceId))
    }

    var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
    }

    /// True while late windows are still expected or fresh placements are still being guarded.
    var hasPendingWork: Bool { !isCancelled && hasBackgroundWork() }

    // MARK: - Phases

    /// Busy phase: launches everything and places every window that shows up within a reasonable time.
    func runForeground() -> Summary {
        SpaceBootLogger.log("=== APPLY START profile=\(profileName) launchMissing=\(launchMissing) windows=\(slots.count) ===")
        bindExistingWindows()
        if launchMissing {
            startColdLaunches()
        }

        let deadline = startedAt.addingTimeInterval(SpaceBootConfig.foregroundPhaseMaxSeconds)
        while !isCancelled && Date() < deadline {
            if step() { continue }
            if !hasForegroundWork() { break }
            usleep(SpaceBootConfig.executorPollMicros)
        }
        guard !isCancelled else {
            SpaceBootLogger.log("=== APPLY CANCELLED profile=\(profileName) (superseded by a newer boot) ===")
            return makeSummary()
        }

        skipUnreachableSlots()
        for home in homeTargets {
            switch home {
            case .desktop(let displayUUID, let spaceId):
                controller.ensureSpaceVisible(displayUUID: displayUUID, spaceId: spaceId)
            case .fullScreenGroup(let displayUUID, let group):
                if let fsId = group.liveFullScreenSpaceId {
                    controller.ensureSpaceVisible(displayUUID: displayUUID, spaceId: fsId)
                } else {
                    controller.ensureSpaceVisible(displayUUID: displayUUID, spaceId: group.stagingSpaceId)
                }
            }
        }
        nudgeBlockedApps(
            windows: inspector.listAllUserWindows(),
            visibleIds: Set(inspector.listDisplays().map(\.currentSpaceId)),
            force: true
        )
        foregroundEndedAt = Date()
        pendingAtForegroundEnd = slots.filter(\.isOpen)

        let summary = makeSummary()
        SpaceBootLogger.log("=== APPLY FOREGROUND DONE profile=\(profileName) placed=\(summary.placed)/\(summary.total) waiting=\(summary.waitingApps) elapsed=\(elapsedText) ===")
        return summary
    }

    /// Background phase: places late windows (switching Spaces only while the user is idle, then switching back)
    /// and keeps guarding fresh placements, without blocking the user.
    func runBackground(completion: ((Summary) -> Void)?) {
        isBackground = true
        let deadline = startedAt.addingTimeInterval(SpaceBootConfig.pendingWindowWatchSeconds)

        while !isCancelled && hasBackgroundWork() {
            if Date() >= deadline {
                giveUpOpenSlots()
                break
            }
            if !step() {
                usleep(SpaceBootConfig.executorPollMicros * 2)
            }
        }

        let placed = slots.filter { $0.windowId != nil }.count
        let missed = orderedUnique(pendingAtForegroundEnd.filter { $0.windowId == nil }.map(\.record.appName))
        SpaceBootLogger.log("=== APPLY BACKGROUND DONE profile=\(profileName) placed=\(placed)/\(slots.count) missed=\(missed) cancelled=\(isCancelled) elapsed=\(elapsedText) ===")
        guard !isCancelled else { return }
        completion?(Summary(placed: placed, total: slots.count, waitingApps: missed))
    }

    // MARK: - Scheduling

    /// One scheduling round. Returns true if it acted, so the caller schedules again right away.
    private func step() -> Bool {
        let now = Date()
        let displays = inspector.listDisplays()
        let windows = inspector.listAllUserWindows()
        let byId = Dictionary(windows.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })
        var visible: [String: Int] = [:]
        for display in displays {
            visible[display.uuid] = display.currentSpaceId
        }
        let visibleIds = Set(visible.values)
        let idle = !isBackground || userIsIdle()
        // In the background, never switch while the user is active, or while a display shows a fullscreen Space
        // (switching back to it afterwards is not possible with Desktop shortcuts).
        let mayIntrude = idle && (!isBackground || displays.allSatisfy { $0.desktopSpaceIds.contains($0.currentSpaceId) })

        expireSlots(now: now)
        reapMissingWindows(byId: byId, now: now)
        if guardPlacedSlots(byId: byId, visible: visible, idle: idle, now: now) { return true }
        bindNewWindows(windows, displays: displays, visibleIds: visibleIds)
        markAlreadyInPlace(byId: byId)
        if idle && nudgeBlockedApps(windows: windows, visibleIds: visibleIds, force: false) { return true }

        // Moving a window that is already reachable never switches a Space, so it runs even while the user is busy.
        if let slot = nextPlacement(byId: byId, visible: visible, allowSwitch: false, held: [], now: now) {
            runSequence { place(slot, allowSwitch: false) }
            return true
        }
        guard mayIntrude else { return false }

        let held = heldDisplays(displays: displays, now: now)
        if let slot = nextWindowRequest(visible: visible, allowSwitch: false, held: held, now: now) {
            runSequence { requestWindow(slot) }
            return true
        }
        if let slot = nextPlacement(byId: byId, visible: visible, allowSwitch: true, held: held, now: now) {
            runSequence { place(slot, allowSwitch: true) }
            return true
        }
        if let slot = nextWindowRequest(visible: visible, allowSwitch: true, held: held, now: now) {
            runSequence { requestWindow(slot) }
            return true
        }
        if applyReadyFullScreenGroups(byId: byId, now: now) {
            return true
        }
        return false
    }

    /// Non-home Spaces first (so each display ends on its home Space without extra switches), then profile order.
    private func scheduledBefore(_ a: BootSlot, _ b: BootSlot) -> Bool {
        if a.isHomeSpace != b.isHomeSpace { return !a.isHomeSpace }
        return a.order < b.order
    }

    private func nextPlacement(byId: [Int: LiveWindowInfo], visible: [String: Int], allowSwitch: Bool, held: Set<String>, now: Date) -> BootSlot? {
        let ready = slots.filter { slot in
            guard slot.awaitsPlacement, let wid = slot.windowId, byId[wid] != nil else { return false }
            return slot.notBefore.map { now >= $0 } ?? true
        }.sorted(by: scheduledBefore)

        if let direct = ready.first(where: { !placementNeedsSwitch($0, byId[$0.windowId!]!, visible: visible) }) {
            return direct
        }
        return allowSwitch ? ready.first(where: { !held.contains($0.displayUUID) }) : nil
    }

    /// Accessibility only reaches windows on visible Spaces, and changing Space on one display needs a switch,
    /// so a placement is switch-free only if the window is visible and its target Space is showing.
    private func placementNeedsSwitch(_ slot: BootSlot, _ win: LiveWindowInfo, visible: [String: Int]) -> Bool {
        guard slot.verified, visible[slot.displayUUID] == slot.targetSpaceId else { return true }
        let visibleIds = Set(visible.values)
        return !win.spaceIds.contains(where: visibleIds.contains)
    }

    private func nextWindowRequest(visible: [String: Int], allowSwitch: Bool, held: Set<String>, now: Date) -> BootSlot? {
        let candidates = slots.filter { canRequestWindow($0, now: now) }.sorted(by: scheduledBefore)
        if let onVisible = candidates.first(where: { visible[$0.displayUUID] == $0.targetSpaceId }) {
            return onVisible
        }
        return allowSwitch ? candidates.first(where: { !held.contains($0.displayUUID) }) : nil
    }

    /// Without a helper display, a window can only reach its Space by opening there: while a launch on a
    /// display's visible Space is still opening its window, that display must not be switched away.
    private func heldDisplays(displays: [LiveDisplayInfo], now: Date) -> Set<String> {
        var held: Set<String> = []
        for display in displays where !hasHelper(for: display.uuid, displays: displays) {
            if slots.contains(where: { slot in
                slot.isOpen && slot.displayUUID == display.uuid && slot.targetSpaceId == display.currentSpaceId &&
                    (slot.requestInFlightUntil.map { now < $0 } ?? false)
            }) {
                held.insert(display.uuid)
            }
        }
        return held
    }

    /// A helper display (any other display showing a Desktop Space) is what lets a window change Space later.
    private func hasHelper(for displayUUID: String, displays: [LiveDisplayInfo]) -> Bool {
        displays.contains { $0.uuid != displayUUID && $0.cgFrame.width > 0 && $0.desktopSpaceIds.contains($0.currentSpaceId) }
    }

    /// Whether `win` can be brought onto `slot`'s Space: it is already there, it sits on another display
    /// (a straight cross-display move), or its display has a helper display to bounce through.
    private func canReach(_ slot: BootSlot, from win: LiveWindowInfo, displays: [LiveDisplayInfo]) -> Bool {
        if win.spaceIds.contains(slot.targetSpaceId) { return true }
        if let source = displays.first(where: { d in win.spaceIds.contains(where: d.desktopSpaceIds.contains) }) {
            return source.uuid != slot.displayUUID || hasHelper(for: source.uuid, displays: displays)
        }
        if slot.isFullScreenMember, inspector.fullScreenSpace(hostingWindow: win.windowId, in: displays) != nil {
            return true
        }
        return false
    }

    private func canRequestWindow(_ slot: BootSlot, now: Date) -> Bool {
        guard launchMissing, slot.isOpen, slot.allowWindowRequests, slot.waitDeadline == nil,
              let spec = slot.record.launch else {
            return false
        }
        if let until = slot.requestInFlightUntil, now < until { return false }
        // One request in flight per app, so every new window maps unambiguously onto its slot.
        let appHasRequestInFlight = slots.contains { other in
            other !== slot && other.appId == slot.appId && other.isOpen && (other.requestInFlightUntil.map { now < $0 } ?? false)
        }
        guard !appHasRequestInFlight else { return false }

        // A shell command runs once; its window is then awaited like a cold launch.
        guard AppLauncher.isAppBundleLaunch(spec) else { return slot.windowRequests == 0 }

        guard !NSRunningApplication.runningApplications(withBundleIdentifier: slot.appId).isEmpty else {
            // Not launched up front: launch it right on its own Space (busy phase only, since the Space is then
            // held until the window opens).
            return deferredApps.contains(slot.appId) && !isBackground && slot.windowRequests == 0
        }
        guard slot.windowRequests < SpaceBootConfig.maxWindowRequestsPerSlot else { return false }
        if runningAtStart.contains(slot.appId) { return true }
        // Cold-launched: ask for extra windows only after its main window showed (and restored windows had a moment).
        guard let arrived = lastArrivalAt[slot.appId] else { return false }
        return now.timeIntervalSince(arrived) >= SpaceBootConfig.postReadyGraceSeconds
    }

    /// The busy phase lasts while SpaceBoot has work it can finish soon. Apps slower than
    /// `foregroundWaitPerAppSeconds` are handed to the background phase so the user gets control back.
    private func hasForegroundWork() -> Bool {
        let now = Date()
        stateLock.lock()
        let launchesQueued = !queuedColdLaunches.isEmpty
        let launched = coldLaunchedAt
        stateLock.unlock()
        if launchesQueued { return true }

        for slot in slots {
            if slot.awaitsPlacement { return true }
            guard slot.isOpen, launchMissing, slot.waitDeadline == nil, slot.record.launch != nil else { continue }
            if let until = slot.requestInFlightUntil, now < until { return true }
            if canRequestWindow(slot, now: now) { return true }
            if let at = launched[slot.appId], now.timeIntervalSince(at) < SpaceBootConfig.foregroundWaitPerAppSeconds { return true }
            if let arrived = lastArrivalAt[slot.appId], now.timeIntervalSince(arrived) < SpaceBootConfig.postReadyGraceSeconds + 1 { return true }
        }
        if fullScreenGroups.contains(where: { !$0.completed && $0.attempts < 2 && $0.memberSlots.allSatisfy { $0.windowId != nil } }) {
            return true
        }
        return false
    }

    private func hasBackgroundWork() -> Bool {
        let now = Date()
        return slots.contains { $0.isOpen || $0.awaitsPlacement || watchesHandover($0, now: now) } ||
            fullScreenGroups.contains { !$0.completed && $0.attempts < 2 && $0.memberSlots.allSatisfy { $0.windowId != nil } }
    }

    /// A launched app may swap its first window for the real one (loader → main, login → main) well after it was
    /// placed — e.g. a long SSO login — so its windows are watched for a handover for a while after launch.
    private func watchesHandover(_ slot: BootSlot, now: Date) -> Bool {
        if slot.fullScreenGroup?.completed == true { return false }
        guard let wid = slot.windowId, slot.placedAt != nil, !preexistingIds.contains(wid) else { return false }
        if isGuarded(slot, now: now) { return true }
        stateLock.lock()
        let launchedAt = coldLaunchedAt[slot.appId]
        stateLock.unlock()
        guard let launchedAt else { return false }
        return now < launchedAt.addingTimeInterval(SpaceBootConfig.handoverWatchSeconds)
    }

    /// Windows SpaceBoot launched are guarded for a while after placement (and after the busy phase ends), to
    /// catch apps that move themselves or swap their startup window for the real one. Windows that were already
    /// open before the boot are left to the user once placed.
    private func isGuarded(_ slot: BootSlot, now: Date) -> Bool {
        guard !slot.isFullScreenMember else { return false }
        guard let wid = slot.windowId, let placedAt = slot.placedAt, !preexistingIds.contains(wid) else { return false }
        guard let ended = foregroundEndedAt else { return true }
        let until = max(
            placedAt.addingTimeInterval(SpaceBootConfig.postBootSettleGuardSeconds),
            ended.addingTimeInterval(SpaceBootConfig.settleAfterForegroundSeconds)
        )
        return now < until
    }

    /// Runs one placement or window request atomically with respect to other Space switches (⌥ hotkeys wait).
    /// In the background phase it also puts every display, the cursor and the frontmost app back afterwards.
    private func runSequence(_ body: () -> Void) {
        controller.withSpaceLock {
            guard isBackground else {
                body()
                return
            }
            let spacesBefore = inspector.listDisplays().map { (uuid: $0.uuid, spaceId: $0.currentSpaceId) }
            let cursor = CGEvent(source: nil)?.location
            let frontmost = NSWorkspace.shared.frontmostApplication

            body()

            let spacesAfter = Dictionary(uniqueKeysWithValues: inspector.listDisplays().map { ($0.uuid, $0.currentSpaceId) })
            for before in spacesBefore where spacesAfter[before.uuid] != before.spaceId {
                controller.switchDisplay(before.uuid, toSpaceId: before.spaceId)
            }
            if let cursor, let now = CGEvent(source: nil)?.location, hypot(now.x - cursor.x, now.y - cursor.y) > 2 {
                CGWarpMouseCursorPosition(cursor)
            }
            if let frontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier != frontmost.processIdentifier {
                frontmost.activate()
            }
        }
    }

    private func userIsIdle() -> Bool {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return true }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return idle >= SpaceBootConfig.userIdleBeforeSwitchSeconds
    }

    // MARK: - Launching & Window Requests

    private func startColdLaunches() {
        let displays = inspector.listDisplays()
        var seen: Set<String> = []
        let coldApps = slots.filter { slot in
            guard slot.isOpen, let spec = slot.record.launch, AppLauncher.isAppBundleLaunch(spec),
                  !runningAtStart.contains(slot.appId) else { return false }
            return seen.insert(slot.appId).inserted
        }
        // Launch up front only apps whose every target Space stays reachable wherever their window opens: its
        // display has a single Desktop, or a helper display to bounce through.
        let plan = coldApps.filter { app in
            let reachable = slots.filter { $0.isOpen && $0.appId == app.appId }.allSatisfy { slot in
                guard let display = displays.first(where: { $0.uuid == slot.displayUUID }) else { return false }
                return display.desktopSpaceIds.count == 1 || hasHelper(for: slot.displayUUID, displays: displays)
            }
            if !reachable { deferredApps.insert(app.appId) }
            return reachable
        }
        if !deferredApps.isEmpty {
            SpaceBootLogger.log("No helper display to move windows between Spaces; launching on their own Space instead: \(coldApps.filter { deferredApps.contains($0.appId) }.map(\.record.appName).joined(separator: ", "))")
        }
        guard !plan.isEmpty else { return }

        stateLock.lock()
        queuedColdLaunches = Set(plan.map(\.appId))
        stateLock.unlock()
        SpaceBootLogger.log("Cold-launching \(plan.count) app(s) \(SpaceBootConfig.coldLaunchStaggerSeconds)s apart: \(plan.map(\.record.appName).joined(separator: ", "))")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for (i, slot) in plan.enumerated() {
                if isCancelled { break }
                if i > 0 { Thread.sleep(forTimeInterval: SpaceBootConfig.coldLaunchStaggerSeconds) }
                let outcome = launcher.coldLaunchIfNeeded(appId: slot.appId, spec: slot.record.launch!)

                stateLock.lock()
                coldLaunchedAt[slot.appId] = Date()
                queuedColdLaunches.remove(slot.appId)
                if case .failed? = outcome {
                    failedLaunches.insert(slot.appId)
                }
                stateLock.unlock()

                switch outcome {
                case .failed(let reason)?:
                    SpaceBootLogger.log("Cold launch [\(i + 1)/\(plan.count)] \(slot.record.appName) failed: \(reason)")
                case nil:
                    SpaceBootLogger.log("Cold launch [\(i + 1)/\(plan.count)] \(slot.record.appName): already running")
                default:
                    SpaceBootLogger.log("Cold launch [\(i + 1)/\(plan.count)] \(slot.record.appName)")
                }
            }
            stateLock.lock()
            queuedColdLaunches.removeAll()
            stateLock.unlock()
        }
    }

    private func requestWindow(_ slot: BootSlot) {
        guard let spec = slot.record.launch else {
            slot.gaveUp = true
            return
        }
        let wasRunning = AppLauncher.isAppBundleLaunch(spec)
            && !NSRunningApplication.runningApplications(withBundleIdentifier: slot.appId).isEmpty

        // Show the target Space and focus its display, so the new window opens right there.
        guard controller.switchDisplay(slot.displayUUID, toSpaceId: slot.targetSpaceId) else {
            // Not a real attempt yet (launches and shell commands only get one): retry shortly, a few times.
            slot.requestSwitchFailures += 1
            slot.requestInFlightUntil = Date().addingTimeInterval(2.0)
            if slot.requestSwitchFailures >= SpaceBootConfig.maxRequestSwitchFailures {
                slot.windowRequests += 1
                slot.requestSwitchFailures = 0
            }
            SpaceBootLogger.log("Window request for \(slot.label) postponed: could not switch to its Space")
            return
        }
        slot.windowRequests += 1
        // A New Window answers within seconds; a launch or shell command may take much longer to open its window.
        slot.requestInFlightUntil = Date().addingTimeInterval(
            wasRunning ? SpaceBootConfig.windowRequestRetrySeconds : SpaceBootConfig.foregroundWaitPerAppSeconds
        )
        let before = Set(inspector.listAllUserWindows().filter { $0.appId == slot.appId }.map(\.windowId))
        if !wasRunning {
            stateLock.lock()
            coldLaunchedAt[slot.appId] = Date()
            stateLock.unlock()
        }

        switch launcher.launchWindow(appId: slot.appId, spec: spec, appAlreadyHasWindow: !before.isEmpty) {
        case .triggered:
            SpaceBootLogger.log("Requested window #\(slot.windowRequests) for \(slot.label)\(wasRunning ? "" : " (launch)")")
            // A running app answers quickly: wait while the Space is still showing so its window lands in place directly.
            guard wasRunning, let win = waitForNewWindow(of: slot, excluding: before) else { return }
            bind(slot, to: win, verified: true)
            SpaceBootLogger.log("Ready: wid=\(win.windowId) (\(win.appName)) answered the request on sp=\(win.spaceIds) -> \(slot.label)")
            place(slot, allowSwitch: false)
        case .singleWindowAlreadyOpen:
            adoptOnlyWindow(for: slot)
        case .failed(let reason):
            SpaceBootLogger.log("Window request for \(slot.label) failed: \(reason)")
            slot.gaveUp = true
        }
    }

    private func waitForNewWindow(of slot: BootSlot, excluding before: Set<Int>) -> LiveWindowInfo? {
        let deadline = Date().addingTimeInterval(SpaceBootConfig.windowRequestResponseSeconds)
        while Date() < deadline && !isCancelled {
            usleep(150_000)
            if let win = inspector.listAllUserWindows().first(where: { win in
                win.appId == slot.appId && !before.contains(win.windowId) &&
                    !claimedIds.contains(win.windowId) && !rejectedIds.contains(win.windowId) &&
                    controller.isLikelyMainWindow(win, expectedFrame: slot.record.frame, requireAXMetadata: true)
            }) {
                return win
            }
        }
        return nil
    }

    /// Single-window apps (no "New Window" item) cannot open a second window: reuse their one window wherever it is.
    private func adoptOnlyWindow(for slot: BootSlot) {
        let displays = inspector.listDisplays()
        let visibleIds = Set(displays.map(\.currentSpaceId))
        guard let win = inspector.listAllUserWindows().first(where: { win in
            win.appId == slot.appId && !claimedIds.contains(win.windowId) && !rejectedIds.contains(win.windowId) &&
                canReach(slot, from: win, displays: displays) &&
                controller.isLikelyMainWindow(win, expectedFrame: slot.record.frame)
        }) else {
            SpaceBootLogger.log("\(slot.record.appName) is a single-window app whose window is already used; skipping \(slot.label)")
            slot.gaveUp = true
            return
        }
        SpaceBootLogger.log("\(slot.record.appName) is a single-window app; moving its open window wid=\(win.windowId) to \(slot.label)")
        bind(slot, to: win, verified: win.spaceIds.contains(where: visibleIds.contains))
    }

    // MARK: - Binding Windows to Slots

    /// Claims windows that are already open:
    /// 1. Live Fullscreen/Split Spaces that already match recorded FullscreenGroups;
    /// 2. Desktop windows already on their target Space;
    /// 3. Surplus open windows sitting on other reachable Spaces.
    private func bindExistingWindows() {
        let displays = inspector.listDisplays()
        let windows = inspector.listAllUserWindows()
        let windowsById = Dictionary(windows.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })
        let visibleIds = Set(displays.map(\.currentSpaceId))
        preexistingIds = Set(windows.map(\.windowId))
        baselineIds = preexistingIds
        runningAtStart = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        var fullScreenWindowIds: Set<Int> = []
        for display in displays {
            for space in display.spaces where space.kind != .desktop {
                for tile in space.tiles {
                    fullScreenWindowIds.insert(tile.windowId)
                }
            }
        }

        // Pass 0: Match already-live Fullscreen / Split View Spaces to FullScreenGroups.
        var matchedLiveFsSpaceIds: Set<Int> = []
        for requireTitleHint in [true, false] {
            for group in fullScreenGroups where group.liveFullScreenSpaceId == nil {
                guard let liveDisplay = displays.first(where: { $0.uuid == group.displayUUID }) else { continue }
                for space in liveDisplay.spaces where !matchedLiveFsSpaceIds.contains(space.id) && space.kind == group.kind {
                    guard let pairedWins = matchFullScreenSpace(space, to: group, windowsById: windowsById, requireTitleHint: requireTitleHint) else {
                        continue
                    }
                    matchedLiveFsSpaceIds.insert(space.id)
                    for (slot, win) in zip(group.memberSlots, pairedWins) {
                        bind(slot, to: win, verified: true)
                        slot.placedAt = Date()
                    }
                    group.liveFullScreenSpaceId = space.id
                    if group.kind == .fullscreen {
                        group.completed = true
                    } else if let targetRatio = group.splitRatio, let liveRatio = space.splitRatio {
                        group.completed = abs(liveRatio - targetRatio) <= SpaceBootConfig.splitRatioTolerance
                    } else {
                        group.completed = true
                    }
                    SpaceBootLogger.log("Matched live \(group.kind.rawValue) sp=\(space.id) for \(group.label) (completed=\(group.completed))")
                    break
                }
            }
        }

        // Pass 1: Desktop slots on their target Desktop Space (do not steal windows already in Fullscreen/Split).
        let desktopSlots = slots.filter { !$0.isFullScreenMember && $0.isOpen }
        for (spaceId, group) in Dictionary(grouping: desktopSlots, by: \.targetSpaceId) {
            let onSpace = windows.filter {
                $0.spaceIds.contains(spaceId) && !claimedIds.contains($0.windowId) && !fullScreenWindowIds.contains($0.windowId)
            }
            for (slot, win) in matchSlots(group.sorted { $0.order < $1.order }, to: onSpace) {
                bind(slot, to: win, verified: win.spaceIds.contains(where: visibleIds.contains))
            }
        }

        // Pass 2: Reuse unclaimed open windows across managed Spaces (or FullscreenGroup member slots).
        for slot in slots where slot.isOpen {
            guard let stray = windows.first(where: { win in
                guard !claimedIds.contains(win.windowId) && win.appId == slot.appId else { return false }
                let allowedOnDesktop = win.spaceIds.contains(where: managedSpaceIds.contains)
                let allowedInFs = slot.isFullScreenMember && fullScreenWindowIds.contains(win.windowId)
                guard allowedOnDesktop || allowedInFs else { return false }
                return canReach(slot, from: win, displays: displays) &&
                    controller.isLikelyMainWindow(win, expectedFrame: slot.record.frame)
            }) else { continue }
            SpaceBootLogger.log("Reusing open wid=\(stray.windowId) (\(stray.appName)) from sp=\(stray.spaceIds) for \(slot.label)")
            bind(slot, to: stray, verified: stray.spaceIds.contains(where: visibleIds.contains))
        }

        SpaceBootLogger.log("Matched \(slots.filter { $0.windowId != nil }.count)/\(slots.count) already-open window(s)")
    }

    private func matchFullScreenSpace(
        _ space: LiveSpaceInfo,
        to group: FullScreenGroup,
        windowsById: [Int: LiveWindowInfo],
        requireTitleHint: Bool
    ) -> [LiveWindowInfo]? {
        guard space.tiles.count >= group.memberSlots.count else { return nil }
        let tileWins = space.tiles.prefix(group.memberSlots.count).compactMap { windowsById[$0.windowId] }
        guard tileWins.count == group.memberSlots.count else { return nil }

        let hasAnyHint = group.memberSlots.contains { !($0.record.titleHint ?? "").isEmpty }
        if requireTitleHint && !hasAnyHint { return nil }

        for (slot, win) in zip(group.memberSlots, tileWins) {
            guard win.appId == slot.appId else { return nil }
            if requireTitleHint, let hint = slot.record.titleHint, !hint.isEmpty {
                let title = controller.inspectAXWindow(windowId: win.windowId, pid: win.pid)?.title ?? win.title
                if !title.localizedCaseInsensitiveContains(hint) {
                    return nil
                }
            }
        }
        return tileWins
    }

    private func matchSlots(_ group: [BootSlot], to live: [LiveWindowInfo]) -> [(BootSlot, LiveWindowInfo)] {
        var used: Set<Int> = []
        var matched: [ObjectIdentifier: LiveWindowInfo] = [:]

        // Title hints first (exact window identity), then any plausible main window of the same app.
        for slot in group {
            guard let hint = slot.record.titleHint, !hint.isEmpty,
                  let found = live.first(where: { win in
                      guard !used.contains(win.windowId), win.appId == slot.appId else { return false }
                      let title = controller.inspectAXWindow(windowId: win.windowId, pid: win.pid)?.title ?? win.title
                      return title.localizedCaseInsensitiveContains(hint)
                  }) else { continue }
            matched[ObjectIdentifier(slot)] = found
            used.insert(found.windowId)
        }
        for slot in group where matched[ObjectIdentifier(slot)] == nil {
            guard let found = live.first(where: {
                !used.contains($0.windowId) && $0.appId == slot.appId &&
                    controller.isLikelyMainWindow($0, expectedFrame: slot.record.frame)
            }) else { continue }
            matched[ObjectIdentifier(slot)] = found
            used.insert(found.windowId)
        }
        return group.compactMap { slot in matched[ObjectIdentifier(slot)].map { (slot, $0) } }
    }

    /// Binds main windows that appeared since the boot started — no matter how late, or on which Space — to open
    /// slots they can actually be moved to.
    private func bindNewWindows(_ windows: [LiveWindowInfo], displays: [LiveDisplayInfo], visibleIds: Set<Int>) {
        for win in windows where !baselineIds.contains(win.windowId) && !claimedIds.contains(win.windowId) && !rejectedIds.contains(win.windowId) {
            // A slot waiting for a replacement only takes a window that shows up while the app has no other main
            // window — a handover — never a window the user opened next to the ones already placed.
            let appHasOtherWindow = windows.contains {
                $0.appId == win.appId && $0.windowId != win.windowId &&
                    (claimedIds.contains($0.windowId) || preexistingIds.contains($0.windowId))
            }
            let open = slots.filter { slot in
                slot.isOpen && slot.appId == win.appId &&
                    (slot.allowWindowRequests || !appHasOtherWindow) &&
                    canReach(slot, from: win, displays: displays)
            }.sorted(by: scheduledBefore)
            guard let probe = open.first else { continue }
            let isVisible = win.spaceIds.contains(where: visibleIds.contains)
            // Splash, login and loading windows are skipped; the app keeps being watched until its main window shows.
            guard controller.isLikelyMainWindow(win, expectedFrame: probe.record.frame, requireAXMetadata: isVisible) else { continue }

            let slot = bestSlot(for: win, among: open)
            bind(slot, to: win, verified: isVisible)
            if isVisible {
                lastArrivalAt[win.appId] = Date()
            }
            promptSince[win.appId] = nil
            SpaceBootLogger.log("Ready: wid=\(win.windowId) (\(win.appName)) appeared on sp=\(win.spaceIds) -> \(slot.label)")
        }
    }

    private func bestSlot(for win: LiveWindowInfo, among open: [BootSlot]) -> BootSlot {
        let now = Date()
        // A window that shows up while a request is in flight answers that request.
        if let requested = open.first(where: { $0.requestInFlightUntil.map { now < $0 } ?? false }) {
            return requested
        }
        // Otherwise prefer the slot whose Space already hosts the window (no relocation), then a title match.
        if let sameSpace = open.first(where: { win.spaceIds.contains($0.targetSpaceId) }) {
            return sameSpace
        }
        let title = controller.inspectAXWindow(windowId: win.windowId, pid: win.pid)?.title ?? win.title
        if !title.isEmpty, let byTitle = open.first(where: { slot in
            guard let hint = slot.record.titleHint, !hint.isEmpty else { return false }
            return title.localizedCaseInsensitiveContains(hint)
        }) {
            return byTitle
        }
        return open[0]
    }

    private func bind(_ slot: BootSlot, to win: LiveWindowInfo, verified: Bool) {
        slot.windowId = win.windowId
        slot.pid = win.pid
        slot.boundAt = Date()
        slot.verified = verified
        slot.verifyAttempts = 0
        slot.placedAt = nil
        slot.notBefore = nil
        slot.placementFailures = 0
        slot.missingSince = nil
        slot.driftStreak = 0
        slot.waitDeadline = nil
        slot.requestInFlightUntil = nil
        claimedIds.insert(win.windowId)
    }

    private func unbind(_ slot: BootSlot) {
        slot.windowId = nil
        slot.placedAt = nil
        slot.notBefore = nil
        slot.missingSince = nil
    }

    // MARK: - Placement

    private func place(_ slot: BootSlot, allowSwitch: Bool) {
        guard let wid = slot.windowId,
              let win = inspector.listAllUserWindows().first(where: { $0.windowId == wid }) else {
            return
        }
        // Re-check under the Space lock: a ⌥-hotkey switch may have changed what is visible since scheduling.
        var visible: [String: Int] = [:]
        for display in inspector.listDisplays() {
            visible[display.uuid] = display.currentSpaceId
        }
        if !allowSwitch && placementNeedsSwitch(slot, win, visible: visible) { return }

        if !preexistingIds.contains(wid), let boundAt = slot.boundAt {
            // Let a just-opened window finish its own open animation / initial positioning first.
            let remaining = SpaceBootConfig.freshWindowSettleSeconds - Date().timeIntervalSince(boundAt)
            if remaining > 0 { usleep(useconds_t(remaining * 1_000_000)) }
        }
        if !slot.verified && !verifyMainWindow(slot, win) { return }

        let targetWasVisible = visible[slot.displayUUID] == slot.targetSpaceId
        let moved = !win.spaceIds.contains(slot.targetSpaceId)

        if slot.isFullScreenMember {
            if let group = slot.fullScreenGroup {
                if group.liveFullScreenSpaceId != nil {
                    slot.placedAt = Date()
                    return
                }
                if group.kind == .fullscreen,
                   let existingFs = inspector.fullScreenSpace(hostingWindow: wid),
                   existingFs.display.uuid == slot.displayUUID,
                   existingFs.space.kind == .fullscreen,
                   !fullScreenGroups.contains(where: { $0 !== group && $0.liveFullScreenSpaceId == existingFs.space.id }) {
                    group.liveFullScreenSpaceId = existingFs.space.id
                    group.completed = true
                    slot.placedAt = Date()
                    SpaceBootLogger.log("Adopted self-restored fullscreen wid=\(wid) on sp=\(existingFs.space.id) for \(slot.label)")
                    return
                }
            }
            if inspector.fullScreenSpace(hostingWindow: wid) != nil {
                _ = controller.exitFullScreen(windowId: wid, pid: win.pid)
            }
            let stagingFrame = stagingDesktopFrame(for: slot)
            let onTarget = inspector.spaceIds(forWindow: wid).contains(slot.targetSpaceId) || controller.relocateWindow(
                windowId: wid,
                pid: win.pid,
                frame: stagingFrame,
                targetDisplayUUID: slot.displayUUID,
                targetSpaceId: slot.targetSpaceId
            )
            if !onTarget {
                slot.placementFailures += 1
                if slot.placementFailures < SpaceBootConfig.maxPlacementAttempts {
                    slot.notBefore = Date().addingTimeInterval(2.0 * Double(slot.placementFailures))
                    return
                }
            }
            slot.placedAt = Date()
            SpaceBootLogger.log("Staged fullscreen member wid=\(wid) \(slot.label) on sp=\(slot.targetSpaceId) onTarget=\(onTarget)")
            return
        }

        if inspector.fullScreenSpace(hostingWindow: wid) != nil {
            _ = controller.exitFullScreen(windowId: wid, pid: win.pid)
        }

        let onTarget = controller.relocateWindow(
            windowId: wid,
            pid: win.pid,
            frame: slot.record.frame,
            targetDisplayUUID: slot.displayUUID,
            targetSpaceId: slot.targetSpaceId
        )
        if !onTarget {
            slot.placementFailures += 1
            if slot.placementFailures < SpaceBootConfig.maxPlacementAttempts {
                slot.notBefore = Date().addingTimeInterval(2.0 * Double(slot.placementFailures))
                SpaceBootLogger.log("Could not move wid=\(wid) to \(slot.label) (attempt \(slot.placementFailures)); retrying shortly")
                return
            }
            SpaceBootLogger.log("Could not move wid=\(wid) to \(slot.label) after \(slot.placementFailures) attempts; leaving it on sp=\(inspector.spaceIds(forWindow: wid))")
        }

        slot.placedAt = Date()
        slot.expectedFrame = slot.record.frame
        acceptClampedFrame(slot)
        SpaceBootLogger.log("Placed wid=\(wid) \(slot.label)\(moved ? " (moved from sp=\(win.spaceIds))" : "") onTarget=\(onTarget)")

        // Restacking raises (activates) apps: skip it on the Space the user is looking at in the background phase.
        if onTarget && (!isBackground || !targetWasVisible) {
            restack(around: slot)
        }
    }

    /// Windows bound while on a hidden Space could not be inspected. Surface their Space and check them; a
    /// transient Accessibility failure (app still starting, switch timed out) is retried rather than taken as
    /// "not a main window".
    private func verifyMainWindow(_ slot: BootSlot, _ win: LiveWindowInfo) -> Bool {
        controller.revealSpace(ofWindow: win.windowId)
        if controller.inspectAXWindow(windowId: win.windowId, pid: win.pid) != nil {
            guard controller.isLikelyMainWindow(win, expectedFrame: slot.record.frame, requireAXMetadata: true) else {
                SpaceBootLogger.log("Place: wid=\(win.windowId) (\(win.appName)) is not a main window after inspection; skipping it")
                rejectedIds.insert(win.windowId)
                unbind(slot)
                return false
            }
        } else {
            slot.verifyAttempts += 1
            guard slot.verifyAttempts >= SpaceBootConfig.maxPlacementAttempts else {
                slot.notBefore = Date().addingTimeInterval(2.0)
                SpaceBootLogger.log("Place: Accessibility cannot read wid=\(win.windowId) (\(win.appName)) yet; retrying")
                return false
            }
            SpaceBootLogger.log("Place: Accessibility still cannot read wid=\(win.windowId) (\(win.appName)); trusting its size")
        }
        slot.verified = true
        if !preexistingIds.contains(win.windowId), lastArrivalAt[slot.appId] == nil {
            lastArrivalAt[slot.appId] = Date()
        }
        return true
    }

    /// Transitions staged Fullscreen/Split member windows into native macOS Fullscreen / Split View
    /// and adjusts vertical split divider ratios once all Desktop placements on that display have settled.
    private func applyReadyFullScreenGroups(byId: [Int: LiveWindowInfo], now: Date) -> Bool {
        for group in fullScreenGroups where !group.completed && group.attempts < 2 {
            if let notBefore = group.notBefore, now < notBefore { continue }

            // Case 1: Split View already paired on boot; only the vertical divider ratio needs adjustment.
            if let liveFsId = group.liveFullScreenSpaceId, group.kind == .split, let targetRatio = group.splitRatio {
                group.attempts += 1
                runSequence {
                    let ok = controller.adjustSplitDivider(spaceId: liveFsId, onDisplay: group.displayUUID, targetRatio: targetRatio)
                    if ok || group.attempts >= 2 {
                        group.completed = true
                    } else {
                        group.notBefore = Date().addingTimeInterval(2.0)
                    }
                }
                return true
            }

            // Wait for regular Desktop placements on this display before switching into Fullscreen.
            let desktopPlacementsPending = slots.contains {
                !$0.isFullScreenMember && $0.displayUUID == group.displayUUID && $0.awaitsPlacement
            }
            if desktopPlacementsPending { continue }

            // Case 2: All member windows are bound, verified, and staged on `group.stagingSpaceId`.
            let allStaged = !group.memberSlots.isEmpty && group.memberSlots.allSatisfy { slot in
                guard slot.placedAt != nil, let wid = slot.windowId, let win = byId[wid] else { return false }
                return win.spaceIds.contains(group.stagingSpaceId)
            }
            guard allStaged else { continue }

            group.attempts += 1
            if group.kind == .fullscreen, let member = group.memberSlots.first, let wid = member.windowId {
                runSequence {
                    if let newSpaceId = controller.enterFullScreen(windowId: wid, pid: member.pid, onDisplay: group.displayUUID) {
                        group.liveFullScreenSpaceId = newSpaceId
                        group.completed = true
                    } else if group.attempts < 2 {
                        group.notBefore = Date().addingTimeInterval(2.0)
                    } else {
                        group.completed = true
                    }
                }
                return true
            }

            if group.kind == .split, group.memberSlots.count >= 2,
               let leftWid = group.memberSlots[0].windowId,
               let rightWid = group.memberSlots[1].windowId {
                let leftPid = group.memberSlots[0].pid
                let rightPid = group.memberSlots[1].pid
                runSequence {
                    if let newSpaceId = controller.enterSplitView(
                        leftWindowId: leftWid,
                        leftPid: leftPid,
                        rightWindowId: rightWid,
                        rightPid: rightPid,
                        onDisplay: group.displayUUID,
                        splitRatio: group.splitRatio
                    ) {
                        group.liveFullScreenSpaceId = newSpaceId
                        group.completed = true
                    } else if group.attempts < 2 {
                        group.notBefore = Date().addingTimeInterval(2.0)
                    } else {
                        group.completed = true
                    }
                }
                return true
            }
        }
        return false
    }

    private func stagingDesktopFrame(for slot: BootSlot) -> WindowRect {
        guard let display = inspector.listDisplays().first(where: { $0.uuid == slot.displayUUID }) else {
            return slot.record.frame
        }
        return WindowRect(
            x: Int(display.cgFrame.minX + 60),
            y: Int(display.cgFrame.minY + 60),
            width: min(max(600, slot.record.frame.width), Int(max(600, display.cgFrame.width - 120))),
            height: min(max(450, slot.record.frame.height), Int(max(450, display.cgFrame.height - 120)))
        )
    }

    /// A window already on its target Space at the recorded frame needs nothing (common when an app restores
    /// its own saved frame on launch) — and in particular no Space switch.
    private func markAlreadyInPlace(byId: [Int: LiveWindowInfo]) {
        for slot in slots where slot.awaitsPlacement {
            guard let win = byId[slot.windowId!], win.spaceIds.contains(slot.targetSpaceId) else { continue }
            if slot.isFullScreenMember {
                guard slot.verified else { continue }
                slot.placedAt = Date()
                SpaceBootLogger.log("Staged in place: wid=\(win.windowId) \(slot.label)")
                continue
            }
            guard win.frame.isApproximatelyEqual(to: slot.record.frame, tolerance: SpaceBootConfig.frameVerifyTolerancePx) else {
                continue
            }
            slot.placedAt = Date()
            SpaceBootLogger.log("In place: wid=\(win.windowId) \(slot.label)")
        }
    }

    /// Restores recorded stacking on the slot's Space: bottom-most (largest zIndex) first, top-most last.
    private func restack(around slot: BootSlot) {
        let peers = slots.filter { $0.targetSpaceId == slot.targetSpaceId && $0.placedAt != nil && $0.windowId != nil }
            .sorted { $0.record.zIndex > $1.record.zIndex }
        for peer in peers {
            controller.raiseWindow(windowId: peer.windowId!, pid: peer.pid)
            usleep(SpaceBootConfig.raiseWindowDelayMicros)
        }
    }

    /// Accepts a size the OS or app clamped (min/max size, Dock) so the settle guard does not fight it.
    private func acceptClampedFrame(_ slot: BootSlot) {
        guard let wid = slot.windowId,
              let live = inspector.listAllUserWindows().first(where: { $0.windowId == wid }),
              live.spaceIds.contains(slot.targetSpaceId),
              abs(live.frame.x - slot.expectedFrame.x) <= SpaceBootConfig.frameVerifyTolerancePx,
              abs(live.frame.y - slot.expectedFrame.y) <= SpaceBootConfig.frameVerifyTolerancePx else {
            return
        }
        slot.expectedFrame = live.frame
    }

    // MARK: - Settle Guard & Expiry

    /// Bound windows that dropped out of the window list:
    /// - closed: a launched window closing soon after launch is a startup window handing over to the real one
    ///   (Electron preloaders, login windows), so its slot waits for the replacement; one that closes before
    ///   placement just frees its slot;
    /// - still existing (minimized or hidden by the user): after a short grace it is left where it is.
    private func reapMissingWindows(byId: [Int: LiveWindowInfo], now: Date) {
        for slot in slots {
            guard let wid = slot.windowId else { continue }
            if byId[wid] != nil {
                slot.missingSince = nil
                continue
            }

            if inspector.spaceIds(forWindow: wid).isEmpty {
                if slot.placedAt != nil {
                    guard watchesHandover(slot, now: now) else { continue }
                    SpaceBootLogger.log("wid=\(wid) of \(slot.label) closed; waiting for its replacement window")
                    slot.allowWindowRequests = false
                    slot.waitDeadline = now.addingTimeInterval(SpaceBootConfig.replacementWaitSeconds)
                } else {
                    SpaceBootLogger.log("wid=\(wid) of \(slot.label) closed before placement; waiting for another window")
                }
                unbind(slot)
                // Some apps briefly order their window out and back in under the same ID (Prisma did during login),
                // so a returning window must be bindable again like a fresh arrival.
                claimedIds.remove(wid)
                baselineIds.remove(wid)
                continue
            }

            let since = slot.missingSince ?? now
            slot.missingSince = since
            if slot.awaitsPlacement, now.timeIntervalSince(since) >= SpaceBootConfig.missingWindowGraceSeconds {
                SpaceBootLogger.log("wid=\(wid) of \(slot.label) is minimized or hidden; leaving it where it is")
                slot.placedAt = now
            }
        }
    }

    /// Re-snaps launched apps that move themselves after startup (e.g. Electron's `center()`) and re-places
    /// windows that wandered off their Space.
    private func guardPlacedSlots(byId: [Int: LiveWindowInfo], visible: [String: Int], idle: Bool, now: Date) -> Bool {
        for slot in slots where isGuarded(slot, now: now) {
            guard let wid = slot.windowId, let win = byId[wid],
                  visible[slot.displayUUID] == slot.targetSpaceId else { continue }

            let onTarget = win.spaceIds.contains(slot.targetSpaceId)
            let frame = controller.readAXWindowFrame(windowId: wid, pid: win.pid) ?? win.frame
            if onTarget && frame.isApproximatelyEqual(to: slot.expectedFrame, tolerance: SpaceBootConfig.frameVerifyTolerancePx) {
                slot.driftStreak = 0
                continue
            }
            // Require the drift on two consecutive polls so we never fight a window mid-animation, and never
            // touch it while the user is active in the background phase (they may be dragging it).
            slot.driftStreak += 1
            guard slot.driftStreak >= 2, idle else { continue }
            slot.driftStreak = 0

            if !onTarget {
                guard slot.relocations < SpaceBootConfig.maxRelocationAttempts else { continue }
                slot.relocations += 1
                SpaceBootLogger.log("Settle: wid=\(wid) of \(slot.label) left its Space (now sp=\(win.spaceIds)); re-placing")
                slot.placedAt = nil
                return true
            }
            SpaceBootLogger.log("Settle: drift on wid=\(wid) \(slot.label): got \(frame), restoring \(slot.expectedFrame)")
            runSequence {
                controller.setWindowFrameVerified(windowId: wid, pid: win.pid, frame: slot.expectedFrame, targetSpaceId: slot.targetSpaceId)
            }
            acceptClampedFrame(slot)
            return true
        }
        return false
    }

    private func expireSlots(now: Date) {
        stateLock.lock()
        let failed = failedLaunches
        stateLock.unlock()

        for slot in slots where slot.isOpen {
            if let deadline = slot.waitDeadline, now >= deadline {
                SpaceBootLogger.log("No replacement window for \(slot.label); giving up on it")
                slot.gaveUp = true
            } else if failed.contains(slot.appId) {
                slot.gaveUp = true
            } else if slot.allowWindowRequests,
                      slot.windowRequests >= SpaceBootConfig.maxWindowRequestsPerSlot,
                      let until = slot.requestInFlightUntil, now >= until {
                let appShowsMainWindow = inspector.listAllUserWindows().contains {
                    $0.appId == slot.appId && controller.isLikelyMainWindow($0, expectedFrame: slot.record.frame)
                }
                if appShowsMainWindow {
                    // The app opens windows fine but not for us (e.g. it opened a tab instead): give up, so a window
                    // the user opens later is never taken over.
                    SpaceBootLogger.log("No window appeared for \(slot.label) after \(slot.windowRequests) request(s); giving up on it")
                    slot.gaveUp = true
                } else {
                    // No main window at all yet: the app may be behind a prompt (e.g. a logged-out WeChat). Stop
                    // asking, but keep waiting for its window.
                    SpaceBootLogger.log("No window yet for \(slot.label) after \(slot.windowRequests) request(s); waiting for the app to open one")
                    slot.allowWindowRequests = false
                }
            }
        }
    }

    /// Slots nothing will ever fill are skipped instead of awaited: restore-only mode, no launch recipe, or an app
    /// that had to be launched on its own Space but the busy phase ended before it got there.
    private func skipUnreachableSlots() {
        for slot in slots where slot.isOpen {
            let neverLaunched = deferredApps.contains(slot.appId) && slot.windowRequests == 0 &&
                NSRunningApplication.runningApplications(withBundleIdentifier: slot.appId).isEmpty
            guard !launchMissing || slot.record.launch == nil || neverLaunched else { continue }
            if neverLaunched {
                SpaceBootLogger.log("Busy phase ended before \(slot.record.appName) could be launched on its Space; skipping \(slot.label)")
            }
            slot.gaveUp = true
        }
    }

    private func giveUpOpenSlots() {
        for slot in slots where slot.isOpen {
            SpaceBootLogger.log("Gave up waiting for \(slot.label) after \(Int(SpaceBootConfig.pendingWindowWatchSeconds))s")
            slot.gaveUp = true
        }
    }

    // MARK: - Login / Splash Prompts

    /// Apps are cold-launched in the background, which can leave a login prompt hidden behind other windows
    /// (e.g. WeChat's "Enter WeChat"). Once a waiting app shows only non-main windows for a moment, raise its
    /// prompt so the user can act on it.
    @discardableResult
    private func nudgeBlockedApps(windows: [LiveWindowInfo], visibleIds: Set<Int>, force: Bool) -> Bool {
        let now = Date()
        stateLock.lock()
        let launched = Set(coldLaunchedAt.keys)
        stateLock.unlock()

        for appId in orderedUnique(slots.filter(\.isOpen).map(\.appId)) where launched.contains(appId) {
            guard (promptNudges[appId] ?? 0) < (force ? 2 : 1) else { continue }
            guard let prompt = windows.first(where: {
                $0.appId == appId && !baselineIds.contains($0.windowId) && !claimedIds.contains($0.windowId) &&
                    $0.spaceIds.contains(where: visibleIds.contains)
            }) else {
                promptSince[appId] = nil
                continue
            }
            let since = promptSince[appId] ?? now
            promptSince[appId] = since
            guard force || now.timeIntervalSince(since) >= SpaceBootConfig.promptNudgeDelaySeconds else { continue }

            promptNudges[appId, default: 0] += 1
            SpaceBootLogger.log("\(prompt.appName) is waiting on a prompt/splash window wid=\(prompt.windowId); bringing it to the front")
            controller.raiseWindow(windowId: prompt.windowId, pid: prompt.pid)
            return true
        }
        return false
    }

    // MARK: - Helpers

    private func makeSummary() -> Summary {
        Summary(
            placed: slots.filter { $0.windowId != nil }.count,
            total: slots.count,
            waitingApps: orderedUnique(slots.filter(\.isOpen).map(\.record.appName))
        )
    }

    private var elapsedText: String {
        String(format: "%.1fs", Date().timeIntervalSince(startedAt))
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
