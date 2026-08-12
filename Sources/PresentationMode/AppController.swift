import AppKit
import CoreGraphics

@MainActor
final class AppController: NSObject {
    private let store: ConfigurationStoring
    private let captureService = DisplayCaptureService()
    private let deckLinkService = DeckLinkService()
    private let ndiService = NDIService()

    private var configuration: RoomConfiguration
    private var mode: PlayoutMode = .production
    private var displays: [DisplayChoice] = []
    private var isTransitioning = false
    private var companionServer: CompanionControlServer?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let displayPopup = NSPopUpButton()
    private let outputStack = NSStackView()
    private let ndiCheckbox = NSButton(checkboxWithTitle: "Enable NDI output", target: nil, action: nil)
    private let ndiSourceField = NSTextField()
    private let canvaButton = NSButton(title: "CANVA MODE", target: nil, action: nil)
    private let productionButton = NSButton(title: "PRODUCTION MODE", target: nil, action: nil)
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 610),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )

    init(store: ConfigurationStoring = DefaultsConfigurationStore()) {
        self.store = store
        self.configuration = store.load()
        if self.configuration.ndiEnabled == nil {
            self.configuration.ndiEnabled = true
        }
        if self.configuration.ndiSourceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            let hostName = Host.current().localizedName ?? "Presentation Mode"
            self.configuration.ndiSourceName = "\(hostName) - NDI 1"
        }
        super.init()
        store.save(self.configuration)
    }

    func launch() {
        deckLinkService.discover()
        configureWindow()
        configureStatusItem()
        companionServer = CompanionControlServer(
            statusProvider: { [weak self] in self?.companionStatus ?? CompanionStatus(deviceID: CompanionControlServer.deviceID, deviceName: Host.current().localizedName ?? "Presentation Mode", mode: "offline", proPresenterRunning: false, ndiRunning: false, ndiSource: "") },
            commandHandler: { [weak self] command in await self?.handleCompanionCommand(command) }
        )
        do { try companionServer?.start() }
        catch { renderState(message: "Companion API could not start: \(error.localizedDescription)") }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(workspaceApplicationChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(workspaceApplicationChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        Task {
            await refreshDisplays()
            await reconcileModeWithProPresenter()
        }
    }

    deinit {
        companionServer?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func prepareForTermination() async {
        companionServer?.stop()
        companionServer = nil
        await captureService.stop()
        ndiService.stop()
        deckLinkService.stop()
        mode = .production
    }

    private var companionStatus: CompanionStatus {
        CompanionStatus(deviceID: CompanionControlServer.deviceID,
                        deviceName: Host.current().localizedName ?? "Presentation Mode",
                        mode: mode.rawValue, proPresenterRunning: isProPresenterRunning,
                        ndiRunning: ndiService.isRunning,
                        ndiSource: configuration.ndiEnabled == true ? (configuration.ndiSourceName ?? "") : "")
    }

    private func handleCompanionCommand(_ command: String) async {
        switch command {
        case "canva": await enterCanvaMode()
        case "production": await enterProductionMode(message: "Production Mode selected from Companion.")
        default: await reconcileModeWithProPresenter()
        }
    }

    private func configureWindow() {
        window.title = "Presentation Mode"
        window.center()
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "Room Display Mode")
        title.font = .systemFont(ofSize: 28, weight: .bold)

        let subtitle = NSTextField(wrappingLabelWithString: "Automatically releases outputs for ProPresenter, then mirrors Canva to the enabled DeckLink and NDI outputs when ProPresenter is closed.")
        subtitle.textColor = .secondaryLabelColor

        let displayLabel = NSTextField(labelWithString: "Canva display")
        displayLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)

        let outputsLabel = NSTextField(labelWithString: "Mirrored SDI outputs")
        outputsLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        outputStack.orientation = .horizontal
        outputStack.spacing = 14
        if configuration.videoStandard != "1080p59.94" || configuration.enabledOutputIDs.isEmpty {
            configuration.videoStandard = "1080p59.94"
            configuration.enabledOutputIDs = Set(deckLinkService.outputs.lazy.filter(\.supports1080p5994).prefix(2).map(\.id))
            store.save(configuration)
        }
        for output in deckLinkService.outputs {
            let checkbox = NSButton(checkboxWithTitle: output.name, target: self, action: #selector(outputChanged(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(output.id)
            checkbox.state = configuration.enabledOutputIDs.contains(output.id) ? .on : .off
            checkbox.isEnabled = output.supports1080p5994
            outputStack.addArrangedSubview(checkbox)
        }

        let ndiLabel = NSTextField(labelWithString: "NDI output (optional)")
        ndiLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        ndiCheckbox.target = self
        ndiCheckbox.action = #selector(ndiEnabledChanged)
        ndiCheckbox.state = configuration.ndiEnabled == true ? .on : .off
        ndiSourceField.stringValue = configuration.ndiSourceName ?? ""
        ndiSourceField.placeholderString = "ProPresenter NDI source name"
        ndiSourceField.target = self
        ndiSourceField.action = #selector(ndiSourceChanged)
        ndiSourceField.isEnabled = configuration.ndiEnabled == true

        canvaButton.bezelStyle = .regularSquare
        canvaButton.font = .systemFont(ofSize: 20, weight: .bold)
        canvaButton.contentTintColor = .systemGreen
        canvaButton.target = self
        canvaButton.action = #selector(canvaPressed)
        canvaButton.heightAnchor.constraint(equalToConstant: 74).isActive = true

        productionButton.bezelStyle = .regularSquare
        productionButton.font = .systemFont(ofSize: 20, weight: .bold)
        productionButton.target = self
        productionButton.action = #selector(productionPressed)
        productionButton.heightAnchor.constraint(equalToConstant: 74).isActive = true

        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, subtitle, displayLabel, displayPopup, outputsLabel, outputStack, ndiLabel, ndiCheckbox, ndiSourceField, canvaButton, productionButton, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(24, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            canvaButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            productionButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            displayPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ndiSourceField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        renderState(message: deckLinkService.dependencyMessage)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        if let image = Bundle.main.image(forResource: "MenuBarIcon") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Presentation Mode")
        }
        button.imagePosition = .imageOnly
        button.toolTip = "Presentation Mode"

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Presentation Mode", action: #selector(showWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Presentation Mode", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu = menu
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let statusItem, let statusMenu {
            statusItem.menu = statusMenu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            showWindow()
        }
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func refreshDisplays() async {
        do {
            displays = try await captureService.availableDisplays()
            displayPopup.removeAllItems()
            displays.forEach { displayPopup.addItem(withTitle: "\($0.name) — \($0.width)×\($0.height)") }
            if let savedID = configuration.sourceDisplayID,
               let index = displays.firstIndex(where: { $0.id == savedID }) {
                displayPopup.selectItem(at: index)
            } else if displays.count > 1 {
                displayPopup.selectItem(at: 1)
                configuration.sourceDisplayID = displays[1].id
                store.save(configuration)
            } else if let first = displays.first {
                configuration.sourceDisplayID = first.id
                store.save(configuration)
            }
            renderState(message: deckLinkService.dependencyMessage)
        } catch {
            renderState(message: error.localizedDescription)
        }
    }

    private func enterCanvaMode() async {
        guard !isProPresenterRunning else {
            await enterProductionMode(message: "Production Mode is locked while ProPresenter is running.")
            return
        }
        guard let displayID = configuration.sourceDisplayID else {
            renderState(message: "Connect the HDMI display emulator, then choose the Canva display.")
            return
        }
        do {
            try deckLinkService.start(outputIDs: configuration.enabledOutputIDs, standard: configuration.videoStandard)
            if configuration.ndiEnabled == true {
                try ndiService.start(sourceName: configuration.ndiSourceName ?? "")
            }
            try await captureService.start(displayID: displayID) { [weak self] frame in
                self?.deckLinkService.enqueue(frame)
                if self?.configuration.ndiEnabled == true {
                    self?.ndiService.send(frame)
                }
            }
            mode = .canva
            let ndiStatus = configuration.ndiEnabled == true ? " and NDI source ‘\(configuration.ndiSourceName ?? "")’" : ""
            renderState(message: "Canva Mode active on selected DeckLinks\(ndiStatus). ProPresenter will automatically reclaim production outputs when it opens.")
        } catch {
            deckLinkService.stop()
            ndiService.stop()
            renderState(message: error.localizedDescription)
        }
    }

    private func enterProductionMode(message: String = "DeckLink outputs are released for production software.") async {
        await captureService.stop()
        ndiService.stop()
        deckLinkService.stop()
        mode = .production
        renderState(message: message)
    }

    private var isProPresenterRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            application.localizedName?.caseInsensitiveCompare("ProPresenter") == .orderedSame &&
                !application.isTerminated
        }
    }

    private func reconcileModeWithProPresenter() async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        if isProPresenterRunning {
            await enterProductionMode(message: "Production Mode is locked while ProPresenter is running.")
        } else {
            await enterCanvaMode()
        }
    }

    private func renderState(message: String?) {
        canvaButton.state = mode == .canva ? .on : .off
        productionButton.state = mode == .production ? .on : .off
        statusLabel.stringValue = message ?? (mode == .canva ? "Canva Mode active" : "Production Mode active")
    }

    @objc private func canvaPressed() { Task { await enterCanvaMode() } }
    @objc private func productionPressed() { Task { await enterProductionMode() } }

    @objc private func workspaceApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.localizedName?.caseInsensitiveCompare("ProPresenter") == .orderedSame else { return }
        Task { await reconcileModeWithProPresenter() }
    }

    @objc private func displayChanged() {
        guard displayPopup.indexOfSelectedItem >= 0 else { return }
        configuration.sourceDisplayID = displays[displayPopup.indexOfSelectedItem].id
        store.save(configuration)
    }

    @objc private func outputChanged(_ sender: NSButton) {
        guard let outputID = sender.identifier?.rawValue else { return }
        if sender.state == .on { configuration.enabledOutputIDs.insert(outputID) }
        else { configuration.enabledOutputIDs.remove(outputID) }
        store.save(configuration)
    }

    @objc private func ndiEnabledChanged() {
        configuration.ndiEnabled = ndiCheckbox.state == .on
        ndiSourceField.isEnabled = configuration.ndiEnabled == true
        store.save(configuration)
    }

    @objc private func ndiSourceChanged() {
        let trimmed = ndiSourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.ndiSourceName = trimmed
        ndiSourceField.stringValue = trimmed
        store.save(configuration)
    }
}
