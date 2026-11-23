import Cocoa
import Foundation

/// Uniquely identifies a Desktop Space slot on a specific monitor.
struct SpaceSlotKey: Codable, Equatable, Hashable {
    var displayUUID: String
    var spaceIndex: Int
}

struct ResolvedSpaceSlot {
    let key: SpaceSlotKey
    let displayName: String
    let spaceId: Int
    let isCurrent: Bool
    /// Extra context shown in the order dialog (the apps recorded on that Space).
    var detail: String? = nil
}

extension SpaceBootProfile {
    /// Every recorded Space as a hotkey slot (display order, then Space order).
    var spaceSlotKeys: [SpaceSlotKey] {
        displays.flatMap { display in
            display.spaces.map { SpaceSlotKey(displayUUID: display.displayUUID, spaceIndex: $0.spaceIndex) }
        }
    }

    /// `hotkeyOrder` checked against the recorded Spaces: unknown or duplicate keys dropped, missing Spaces appended.
    var resolvedHotkeyOrder: [SpaceSlotKey] {
        let all = spaceSlotKeys
        var seen: Set<SpaceSlotKey> = []
        let ordered = (hotkeyOrder ?? []).filter { all.contains($0) && seen.insert($0).inserted }
        return ordered + all.filter { !seen.contains($0) }
    }

    /// Rows for the hotkey order dialog in `order`, each labelled with the apps recorded on that Space.
    func hotkeySlotRows(in order: [SpaceSlotKey]) -> [ResolvedSpaceSlot] {
        order.compactMap { key in
            guard let display = displays.first(where: { $0.displayUUID == key.displayUUID }),
                  let space = display.spaces.first(where: { $0.spaceIndex == key.spaceIndex }) else { return nil }
            var seen: Set<String> = []
            let apps = space.windows.sorted { $0.zIndex < $1.zIndex }.map(\.appName).filter { seen.insert($0).inserted }
            return ResolvedSpaceSlot(
                key: key,
                displayName: display.displayName,
                spaceId: 0,
                isCurrent: false,
                detail: apps.joined(separator: ", ")
            )
        }
    }
}

/// Persists the user's custom ⌥1–⌥9 Space ordering at ~/.config/spaceboot/hotkey-order.json
/// and reconciles it seamlessly when displays or Spaces are added/removed.
final class HotkeyOrderStore {
    private static let orderFilePath = "\(NSHomeDirectory())/.config/spaceboot/hotkey-order.json"

    private var savedOrder: [SpaceSlotKey] = []

    init() {
        load()
    }

    /// Returns all currently live Spaces sorted by the user's custom hotkey order.
    func orderedSlots(from displays: [LiveDisplayInfo]) -> [ResolvedSpaceSlot] {
        var liveByKey: [SpaceSlotKey: ResolvedSpaceSlot] = [:]
        var defaultSequence: [SpaceSlotKey] = []

        for display in displays {
            for (localIdx, spaceId) in display.desktopSpaceIds.enumerated() {
                let key = SpaceSlotKey(displayUUID: display.uuid, spaceIndex: localIdx)
                defaultSequence.append(key)
                liveByKey[key] = ResolvedSpaceSlot(
                    key: key,
                    displayName: display.name,
                    spaceId: spaceId,
                    isCurrent: spaceId == display.currentSpaceId
                )
            }
        }

        var result: [ResolvedSpaceSlot] = []
        var included: Set<SpaceSlotKey> = []

        // Place previously ordered slots that currently exist first.
        for key in savedOrder {
            if let slot = liveByKey[key], included.insert(key).inserted {
                result.append(slot)
            }
        }

        // Append any newly created Spaces or newly connected displays at the end.
        for key in defaultSequence {
            if let slot = liveByKey[key], included.insert(key).inserted {
                result.append(slot)
            }
        }

        return result
    }

    func updateOrder(_ newKeys: [SpaceSlotKey]) {
        // Keep unseen offline-monitor entries intact at the tail so unplugging a monitor doesn't erase its order.
        let newSet = Set(newKeys)
        let preservedOffline = savedOrder.filter { !newSet.contains($0) }
        savedOrder = newKeys + preservedOffline
        save()
    }

    // MARK: - Persistence

    private func load() {
        let url = URL(fileURLWithPath: Self.orderFilePath)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SpaceSlotKey].self, from: data) else {
            return
        }
        savedOrder = decoded
    }

    private func save() {
        let url = URL(fileURLWithPath: Self.orderFilePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(savedOrder) {
            try? data.write(to: url)
        }
    }
}

/// Floating window with drag-and-drop reordering of one profile's ⌥1–⌥9 Space order
/// (opened from the profile's "Edit Hotkey Order…" menu item).
final class HotkeyOrderWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static let rowDragType = NSPasteboard.PasteboardType("com.spaceboot.space-slot-row")

    private struct ProfileEdit {
        let name: String
        let defaultRows: [ResolvedSpaceSlot]
        let onDone: ([SpaceSlotKey]) -> Void
    }

    private var slots: [ResolvedSpaceSlot] = []
    private let tableView = NSTableView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    /// The profile being edited; its order is handed back when the window is confirmed or closed.
    private var profileEdit: ProfileEdit?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Hotkey Order"
        window.isReleasedWhenClosed = false
        window.level = .floating

        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows a profile's Spaces in `rows` order. `onDone` receives the order when the window is confirmed or closed.
    func showForProfile(
        named name: String,
        rows: [ResolvedSpaceSlot],
        defaultRows: [ResolvedSpaceSlot],
        onDone: @escaping ([SpaceSlotKey]) -> Void
    ) {
        finishProfileEdit()
        profileEdit = ProfileEdit(name: name, defaultRows: defaultRows, onDone: onDone)
        window?.title = "Hotkey Order — \(name)"
        hintLabel.stringValue = "Drag rows to choose which Space each ⌥1–⌥9 opens for “\(name)”. It is saved into the profile and applied every time the profile boots."
        slots = rows
        tableView.reloadData()

        window?.center()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finishProfileEdit()
    }

    private func finishProfileEdit() {
        guard let edit = profileEdit else { return }
        profileEdit = nil
        edit.onDone(slots.map(\.key))
    }

    // MARK: - UI Setup

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 10
        container.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        container.addArrangedSubview(hintLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("slot"))
        column.title = "Spaces"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.rowDragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        container.addArrangedSubview(scrollView)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8

        let resetBtn = NSButton(title: "Reset Default", target: self, action: #selector(handleReset))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(handleDone))
        doneBtn.keyEquivalent = "\r"

        footer.addArrangedSubview(resetBtn)
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(doneBtn)
        container.addArrangedSubview(footer)
    }

    @objc private func handleReset() {
        guard let edit = profileEdit else { return }
        slots = edit.defaultRows
        tableView.reloadData()
    }

    @objc private func handleDone() {
        finishProfileEdit()
        window?.close()
    }

    // MARK: - NSTableViewDataSource & Drag-and-Drop Reordering

    func numberOfRows(in tableView: NSTableView) -> Int {
        slots.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < slots.count else { return nil }
        let slot = slots[row]
        let cellId = NSUserInterfaceItemIdentifier("SlotCell")

        let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = cellId

            let handleLabel = NSTextField(labelWithString: "≡")
            handleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            handleLabel.textColor = .tertiaryLabelColor
            handleLabel.translatesAutoresizingMaskIntoConstraints = false

            let badgeLabel = NSTextField(labelWithString: "")
            badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            badgeLabel.textColor = .controlAccentColor
            badgeLabel.alignment = .center
            badgeLabel.tag = 1
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = NSFont.systemFont(ofSize: 13)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.tag = 2
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            v.addSubview(handleLabel)
            v.addSubview(badgeLabel)
            v.addSubview(titleLabel)

            NSLayoutConstraint.activate([
                handleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                handleLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                badgeLabel.leadingAnchor.constraint(equalTo: handleLabel.trailingAnchor, constant: 8),
                badgeLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                badgeLabel.widthAnchor.constraint(equalToConstant: 32),
                titleLabel.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: 8),
                titleLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
                titleLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor)
            ])
            return v
        }()

        if let badge = cell.viewWithTag(1) as? NSTextField {
            badge.stringValue = row < 9 ? "⌥\(row + 1)" : "—"
        }
        if let title = cell.viewWithTag(2) as? NSTextField {
            let activeTag = slot.isCurrent ? "  (Active)" : ""
            let detail = slot.detail.flatMap { $0.isEmpty ? nil : "  —  \($0)" } ?? ""
            title.stringValue = "\(slot.displayName) · Space \(slot.key.spaceIndex + 1)\(activeTag)\(detail)"
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowDragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row destinationRow: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: Self.rowDragType),
              let sourceRow = Int(str),
              sourceRow >= 0, sourceRow < slots.count else {
            return false
        }

        let moved = slots.remove(at: sourceRow)
        let insertIndex = destinationRow > sourceRow ? destinationRow - 1 : destinationRow
        let clampedIndex = max(0, min(insertIndex, slots.count))
        slots.insert(moved, at: clampedIndex)
        tableView.reloadData()
        return true
    }
}
