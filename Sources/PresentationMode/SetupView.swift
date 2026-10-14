import AppKit

@MainActor
private final class TopAlignedClipView: NSClipView { override var isFlipped: Bool { true } }

/// Hardware is the navigation model. RoomProfile.destinations remains the
/// compatible persistence format; its old display names never organize Setup.
@MainActor
final class SetupView: NSView {
    private var draft: RoomProfileLibrary
    private let saved: () -> RoomProfileLibrary
    private let inventory: () -> HardwareInventory
    private let stopped: () -> Bool
    private let refresh: () -> Void
    private let apply: (RoomProfileLibrary) throws -> Void
    private let loadDiagnostic: () -> String?
    private var selectedID: String?
    private let profilePicker = NSPopUpButton()
    private let roomName = NSTextField()
    private let outputRows = NSStackView()
    private let outputTitle = NSTextField(labelWithString: "Select an output")
    private let cardLabel = NSTextField(wrappingLabelWithString: "")
    private let role = NSPopUpButton()
    private let key = NSPopUpButton()
    private let keyLabel = NSTextField(labelWithString: "Key output")
    private let timing = NSPopUpButton()
    private let relation = NSTextField(wrappingLabelWithString: "")
    private let configure = NSButton(title: "Configure output", target: nil, action: nil)
    private let diagnostics = NSTextField(wrappingLabelWithString: "")

    init(loadDiagnostic: @escaping () -> String?, saved: @escaping () -> RoomProfileLibrary, inventory: @escaping () -> HardwareInventory, stopped: @escaping () -> Bool, refresh: @escaping () -> Void, apply: @escaping (RoomProfileLibrary) throws -> Void) {
        self.loadDiagnostic = loadDiagnostic; self.saved = saved; self.inventory = inventory
        self.stopped = stopped; self.refresh = refresh; self.apply = apply; draft = saved()
        super.init(frame: .zero)
        profilePicker.target = self; profilePicker.action = #selector(selectProfile)
        roomName.placeholderString = "Room profile name"; roomName.target = self; roomName.action = #selector(renameRoom)
        let new = NSButton(title: "New room", target: self, action: #selector(newRoom))
        let duplicate = NSButton(title: "Duplicate", target: self, action: #selector(duplicateRoom))
        let top = NSStackView(views: [profilePicker, roomName, new, duplicate]); top.distribution = .fillProportionally
        let title = NSTextField(labelWithString: "Outputs"); title.font = .systemFont(ofSize: 16, weight: .semibold)
        outputRows.orientation = .vertical; outputRows.alignment = .leading; outputRows.spacing = 6
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.contentView = TopAlignedClipView(); scroll.documentView = outputRows
        outputRows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([outputRows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), outputRows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), outputRows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        let scan = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        let left = NSStackView(views: [title, scroll, scan]); left.orientation = .vertical; left.alignment = .leading; left.spacing = 12
        outputTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        cardLabel.textColor = .secondaryLabelColor; cardLabel.font = .systemFont(ofSize: 11)
        role.addItems(withTitles: ["Direct", "Fill + Key"]); role.target = self; role.action = #selector(roleChanged)
        key.target = self; key.action = #selector(keyChanged)
        timing.target = self; timing.action = #selector(timingChanged)
        configure.target = self; configure.action = #selector(configureOutput)
        relation.font = .systemFont(ofSize: 13, weight: .medium)
        let right = NSStackView(views: [outputTitle, cardLabel, configure, NSTextField(labelWithString: "Output mode"), role, keyLabel, key, NSTextField(labelWithString: "Timing"), timing, relation])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 12
        for view in [role, key, timing] { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        let divider = NSBox(); divider.boxType = .separator
        let panes = NSStackView(views: [left, divider, right]); panes.orientation = .horizontal; panes.alignment = .top; panes.spacing = 24
        let validate = NSButton(title: "Validate", target: self, action: #selector(validateDraft))
        let revert = NSButton(title: "Revert draft", target: self, action: #selector(revertDraft))
        let applyButton = NSButton(title: "Apply profile", target: self, action: #selector(applyDraft))
        let actions = NSStackView(views: [validate, revert, applyButton])
        let note = NSTextField(labelWithString: "Draft changes • Apply with outputs stopped")
        note.textColor = .secondaryLabelColor
        diagnostics.maximumNumberOfLines = 6; diagnostics.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [top, note, panes, actions, diagnostics]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor), panes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            left.widthAnchor.constraint(equalToConstant: 310), scroll.widthAnchor.constraint(equalTo: left.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360), left.heightAnchor.constraint(equalTo: panes.heightAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalTo: panes.heightAnchor),
            diagnostics.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var index: Int { draft.profiles.firstIndex { $0.id == draft.activeID } ?? 0 }
    private var profile: RoomProfile { draft.profiles[index] }
    private var model: HardwareSetupDraft { HardwareSetupDraft(profile: profile, inventory: inventory()) }
    private var bindingIndex: Int? { profile.destinations.firstIndex { $0.picture == selectedID } }
    private func captureName() { draft.profiles[index].name = roomName.stringValue }
    private func displayName(_ id: String) -> String {
        guard let endpoint = inventory().endpoints.first(where: { $0.id == id }) else { return id.isEmpty ? "Choose key output" : "Missing output [\(id)]" }
        let duplicate = inventory().endpoints.filter { $0.connectorLabel == endpoint.connectorLabel }.count > 1
        return duplicate ? "\(endpoint.connectorLabel) [\(endpoint.id)]" : endpoint.connectorLabel
    }
    private func reload() {
        profilePicker.removeAllItems(); profilePicker.addItems(withTitles: draft.profiles.map(\.name)); profilePicker.selectItem(at: index)
        roomName.stringValue = profile.name
        outputRows.arrangedSubviews.forEach { outputRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let rows = model.cards.flatMap(\.outputs)
        if selectedID == nil { selectedID = rows.first(where: { $0.role != .key && $0.endpoint.selectable })?.id }
        for row in rows {
            let d = profile.destinations.first { $0.picture == row.id }
            let subtext: String
            if row.collision { subtext = "Assignment conflict" }
            else if row.role == .key { subtext = "Key source for \(displayName(row.pairedOutputID ?? ""))" }
            else if let d { subtext = "\(d.key == nil ? "Direct" : "Fill + Key") • \(d.timing.rawValue)" }
            else if !row.endpoint.playback { subtext = "Input only" }
            else if !row.endpoint.active { subtext = "Inactive" }
            else { subtext = "Not configured" }
            let button = NSButton(title: "\(displayName(row.id))\n\(subtext)", target: self, action: #selector(selectOutput(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(row.id); button.bezelStyle = .regularSquare
            button.setButtonType(.toggle); button.state = selectedID == row.id ? .on : .off
            button.alignment = .left; button.font = .systemFont(ofSize: 12)
            button.contentTintColor = selectedID == row.id ? .controlAccentColor : .labelColor
            button.isEnabled = row.role != .key || row.collision
            button.toolTip = "\(row.endpoint.modelLabel) • \(row.endpoint.cardID) • output \(row.endpoint.connectorIndex)"
            outputRows.addArrangedSubview(button); button.widthAnchor.constraint(equalTo: outputRows.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 56).isActive = true
        }
        // Retain a repair path for saved outputs absent after a rescan.
        // They are explicitly marked missing rather than silently reassigned.
        let missingFills = profile.destinations.filter { d in !inventory().endpoints.contains { $0.id == d.picture } }
        for destination in missingFills {
            let button = NSButton(title: "Missing output [\(destination.picture)]\nSaved assignment", target: self, action: #selector(selectOutput(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(destination.picture); button.bezelStyle = .regularSquare
            button.alignment = .left; button.font = .systemFont(ofSize: 11)
            outputRows.addArrangedSubview(button); button.widthAnchor.constraint(equalTo: outputRows.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 56).isActive = true
        }
        renderEditor()
        let missing = model.missingAssignments.count
        diagnostics.stringValue = loadDiagnostic() ?? (inventory().issues + (missing > 0 ? ["\(missing) saved assignment(s) reference missing hardware. Rescan before applying."] : [])).joined(separator: "\n")
    }
    private func renderEditor() {
        let endpoint = inventory().endpoints.first { $0.id == selectedID }
        let binding = bindingIndex.map { profile.destinations[$0] }
        let keyOwner = profile.destinations.first { $0.key == selectedID }
        outputTitle.stringValue = selectedID.map(displayName) ?? "Select an output"
        cardLabel.stringValue = endpoint.map { "\($0.modelLabel) • \($0.cardID)\n\($0.id)" } ?? "Rescan to detect DeckLink hardware."
        configure.title = binding == nil ? "Configure output" : "Remove assignment"
        configure.isEnabled = (binding != nil || endpoint?.selectable == true) && keyOwner == nil
        role.selectItem(at: binding?.key == nil ? 0 : 1); role.isEnabled = binding != nil && keyOwner == nil
        key.removeAllItems(); key.addItem(withTitle: "Choose key output…"); key.lastItem?.representedObject = ""
        if let selectedID {
            let used = Set(profile.destinations.filter { $0.id != binding?.id }.flatMap { [$0.picture, $0.key].compactMap { $0 } })
            for other in inventory().endpoints where !used.contains(other.id) && !inventory().selectableTimings(fill: selectedID, key: other.id).isEmpty {
                key.addItem(withTitle: displayName(other.id)); key.lastItem?.representedObject = other.id
            }
        }
        if let selected = binding?.key, !selected.isEmpty {
            if let item = key.itemArray.first(where: { $0.representedObject as? String == selected }) { key.select(item) }
            else { key.addItem(withTitle: "Unavailable: \(displayName(selected))"); key.lastItem?.representedObject = selected; key.lastItem?.isEnabled = false; key.select(key.lastItem) }
        }
        key.isHidden = binding?.key == nil; keyLabel.isHidden = key.isHidden
        key.isEnabled = binding?.key != nil && keyOwner == nil
        timing.removeAllItems()
        let options = selectedID.map { inventory().selectableTimings(fill: $0, key: binding?.key) } ?? []
        for option in options { timing.addItem(withTitle: option.rawValue); timing.lastItem?.representedObject = option.rawValue }
        if let current = binding?.timing {
            if options.contains(current) { timing.selectItem(withTitle: current.rawValue) }
            else { timing.addItem(withTitle: "Unavailable: \(current.rawValue)"); timing.lastItem?.isEnabled = false; timing.select(timing.lastItem) }
        }
        timing.isEnabled = binding != nil && !options.isEmpty && keyOwner == nil
        if let owner = keyOwner { relation.stringValue = "Key source for \(displayName(owner.picture))" }
        else if let keyID = binding?.key { relation.stringValue = "Fill: \(outputTitle.stringValue)\n↳ Key: \(displayName(keyID))" }
        else { relation.stringValue = binding == nil ? "Select Configure output to add it to this room." : "Direct picture output" }
        if let issue = endpoint?.discoveryIssue { relation.stringValue = issue }
    }
    @objc private func selectOutput(_ sender: NSButton) { captureName(); selectedID = sender.identifier?.rawValue; reload() }
    @objc private func selectProfile() { let selected = profilePicker.indexOfSelectedItem; captureName(); draft.activeID = draft.profiles[selected].id; selectedID = nil; reload() }
    @objc private func renameRoom() { captureName(); reload() }
    @objc private func newRoom() { captureName(); let p = RoomProfile(name: "New room", destinations: []); draft.profiles.append(p); draft.activeID = p.id; selectedID = nil; reload() }
    @objc private func duplicateRoom() { captureName(); var p = profile; p.id = UUID(); p.name += " copy"; p.destinations = p.destinations.map { var d = $0; d.id = UUID(); return d }; draft.profiles.append(p); draft.activeID = p.id; reload() }
    @objc private func rescan() { captureName(); refresh(); reload() }
    @objc private func configureOutput() {
        captureName()
        if let i = bindingIndex { draft.profiles[index].destinations.remove(at: i) }
        else if let selectedID {
            let choices = inventory().selectableTimings(fill: selectedID)
            guard let rate = choices.contains(.p5994) ? OutputTiming.p5994 : choices.first else { diagnostics.stringValue = "No modes supported by this app on the selected output."; return }
            draft.profiles[index].destinations.append(Destination(name: "Output \(selectedID)", picture: selectedID, key: nil, timing: rate))
        }
        reload()
    }
    @objc private func roleChanged() {
        captureName(); guard let i = bindingIndex else { return }
        draft.profiles[index].destinations[i].key = role.indexOfSelectedItem == 0 ? nil : (profile.destinations[i].key ?? "")
        reload()
    }
    @objc private func keyChanged() {
        captureName(); guard let i = bindingIndex else { return }
        draft.profiles[index].destinations[i].key = key.selectedItem?.representedObject as? String ?? ""
        reload()
    }
    @objc private func timingChanged() {
        captureName(); guard let i = bindingIndex, let raw = timing.selectedItem?.representedObject as? String, let rate = OutputTiming(rawValue: raw) else { return }
        draft.profiles[index].destinations[i].timing = rate; reload()
    }
    @objc private func validateDraft() {
        captureName(); let issues = model.problems
        guard issues.isEmpty else { diagnostics.stringValue = issues.joined(separator: "\n"); return }
        do { try draft.validate(); diagnostics.stringValue = "Draft valid. Not applied." } catch { diagnostics.stringValue = error.localizedDescription }
    }
    @objc private func applyDraft() {
        guard stopped() else { diagnostics.stringValue = "Stop outputs before applying settings."; return }
        captureName()
        do { try apply(draft); reload(); diagnostics.stringValue = "Applied and saved. Outputs remain stopped." } catch { diagnostics.stringValue = error.localizedDescription }
    }
    @objc private func revertDraft() {
        guard stopped() else { diagnostics.stringValue = "Stop outputs before reverting settings."; return }
        draft = saved(); selectedID = nil; reload(); diagnostics.stringValue = "Draft reverted to the last applied profile."
    }
}
