import AppKit

@MainActor
final class SetupView: NSView {
    private var draft: RoomProfileLibrary
    private let saved: () -> RoomProfileLibrary
    private let devices: () -> [OutputCapability]
    private let stopped: () -> Bool
    private let refresh: () -> Void
    private let apply: (RoomProfileLibrary) throws -> Void
    private let profilePicker = NSPopUpButton()
    private let name = NSTextField()
    private let rows = NSStackView()
    private let diagnostics = NSTextField(wrappingLabelWithString: "")
    private var editors: [DestinationEditor] = []
    private let applyButton = NSButton(title: "Apply profile", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert draft", target: nil, action: nil)

    init(saved: @escaping () -> RoomProfileLibrary, devices: @escaping () -> [OutputCapability], stopped: @escaping () -> Bool, refresh: @escaping () -> Void, apply: @escaping (RoomProfileLibrary) throws -> Void) {
        self.saved = saved; self.devices = devices; self.stopped = stopped; self.refresh = refresh; self.apply = apply
        self.draft = saved()
        super.init(frame: .zero)
        profilePicker.target = self; profilePicker.action = #selector(selectProfile)
        name.placeholderString = "Room name"
        let duplicate = NSButton(title: "Duplicate room", target: self, action: #selector(duplicateProfile))
        let add = NSButton(title: "Add destination", target: self, action: #selector(addDestination))
        let scan = NSButton(title: "Refresh devices", target: self, action: #selector(refreshDevices))
        let check = NSButton(title: "Validate draft", target: self, action: #selector(validateDraft))
        applyButton.target = self; applyButton.action = #selector(applyDraft)
        revertButton.target = self; revertButton.action = #selector(revertDraft)
        let intro = NSTextField(wrappingLabelWithString: "SETUP • Changes stay in this draft until you Apply with all outputs stopped. Select Direct for an ordinary picture output, or Fill + Key for a synchronized pair.")
        let matte = NSTextField(wrappingLabelWithString: "Opaque desktop: picture alpha is solid. Paired key is white while active, black on stop. Direct destinations send picture only. Confidence remains direct in the Largo profile.")
        matte.textColor = .secondaryLabelColor
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 12
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        scroll.documentView = rows; rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnostics.maximumNumberOfLines = 8
        let top = NSStackView(views: [profilePicker, name, duplicate]); top.distribution = .fillEqually
        let buttons = NSStackView(views: [add, scan, check, revertButton, applyButton])
        let stack = NSStackView(views: [intro, top, matte, scroll, buttons, diagnostics])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24), top.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260), diagnostics.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var index: Int { draft.profiles.firstIndex { $0.id == draft.activeID } ?? 0 }
    private func collect() {
        draft.profiles[index].name = name.stringValue
        draft.profiles[index].destinations = editors.map { $0.value }
    }
    private func reload() {
        profilePicker.removeAllItems(); profilePicker.addItems(withTitles: draft.profiles.map(\.name)); profilePicker.selectItem(at: index)
        name.stringValue = draft.profiles[index].name
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        editors = draft.profiles[index].destinations.map { destination in
            DestinationEditor(destination, devices: devices()) { [weak self] id in
                guard let self else { return }; self.collect()
                self.draft.profiles[self.index].destinations.removeAll { $0.id == id }; self.reload()
            }
        }
        for editor in editors { rows.addArrangedSubview(editor); editor.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
        diagnostics.stringValue = "Draft only. \(devices().count) active playback endpoints found. Apply rechecks device support."
    }
    @objc private func selectProfile() { let selected = profilePicker.indexOfSelectedItem; collect(); draft.activeID = draft.profiles[selected].id; reload() }
    @objc private func duplicateProfile() {
        collect(); var copy = draft.profiles[index]; copy.id = UUID(); copy.name += " copy"
        copy.destinations = copy.destinations.map { var d = $0; d.id = UUID(); return d }
        draft.profiles.append(copy); draft.activeID = copy.id; reload()
    }
    @objc private func addDestination() { collect(); draft.profiles[index].destinations.append(Destination(name: "Destination \(editors.count + 1)", picture: "", key: nil, timing: .p5994)); reload() }
    @objc private func refreshDevices() { collect(); refresh(); reload() }
    @objc private func validateDraft() {
        collect()
        let errors = draft.profiles[index].problems(devices: devices())
        do { try draft.validate() } catch { diagnostics.stringValue = error.localizedDescription; return }
        diagnostics.stringValue = errors.isEmpty ? "Draft valid. \(devices().count) active endpoints. Hardware availability is checked again at start. Changes are not applied." : errors.joined(separator: "\n")
    }
    @objc private func applyDraft() {
        guard stopped() else { diagnostics.stringValue = "Stop outputs before applying settings."; return }
        collect()
        do { try apply(draft); reload(); diagnostics.stringValue = "Applied and saved. Outputs remain stopped." }
        catch { diagnostics.stringValue = error.localizedDescription }
    }
    @objc private func revertDraft() {
        guard stopped() else { diagnostics.stringValue = "Stop outputs before reverting settings."; return }
        draft = saved(); reload(); diagnostics.stringValue = "Draft reverted to the last applied profile."
    }
}

@MainActor
private final class DestinationEditor: NSStackView {
    private var destination: Destination
    private let name = NSTextField()
    private let role = NSPopUpButton()
    private let picture = NSPopUpButton()
    private let key = NSPopUpButton()
    private let timing = NSPopUpButton()
    private let remove: (UUID) -> Void
    init(_ destination: Destination, devices: [OutputCapability], remove: @escaping (UUID) -> Void) {
        self.destination = destination; self.remove = remove
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 5
        name.stringValue = destination.name
        role.addItems(withTitles: ["Direct / unkeyed", "Fill + Key"]); role.selectItem(at: destination.key == nil ? 0 : 1)
        role.target = self; role.action = #selector(roleChanged)
        func fill(_ popup: NSPopUpButton, selected: String?) {
            popup.addItem(withTitle: "Choose endpoint…"); popup.lastItem?.representedObject = ""
            for d in devices { popup.addItem(withTitle: "\(d.name) [\(d.id)]"); popup.lastItem?.representedObject = d.id
                popup.lastItem?.toolTip = OutputTiming.allCases.filter { d.modes & $0.mask != 0 }.map(\.rawValue).joined(separator: ", ")
            }
            if let selected, !selected.isEmpty {
                if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == selected }) { popup.select(item) }
                else { popup.addItem(withTitle: "Missing: \(selected)"); popup.lastItem?.representedObject = selected; popup.select(popup.lastItem) }
            }
        }
        fill(picture, selected: destination.picture); fill(key, selected: destination.key)
        timing.addItems(withTitles: OutputTiming.allCases.map(\.rawValue)); timing.selectItem(withTitle: destination.timing.rawValue)
        let delete = NSButton(title: "Remove", target: self, action: #selector(removeDestination))
        let heading = NSStackView(views: [name, role, timing, delete]); heading.distribution = .fillProportionally
        addArrangedSubview(heading)
        let fillRow = NSStackView(views: [NSTextField(labelWithString: "Picture / Fill"), picture]); addArrangedSubview(fillRow)
        let keyRow = NSStackView(views: [NSTextField(labelWithString: "Key"), key]); addArrangedSubview(keyRow)
        for row in [heading, fillRow, keyRow] { row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        picture.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        key.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        roleChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func roleChanged() { key.isEnabled = role.indexOfSelectedItem == 1 }
    @objc private func removeDestination() { remove(destination.id) }
    var value: Destination {
        var d = destination; d.name = name.stringValue
        d.picture = picture.selectedItem?.representedObject as? String ?? ""
        d.key = role.indexOfSelectedItem == 1 ? (key.selectedItem?.representedObject as? String ?? "") : nil
        d.timing = OutputTiming(rawValue: timing.titleOfSelectedItem ?? "") ?? .p5994
        return d
    }
}
