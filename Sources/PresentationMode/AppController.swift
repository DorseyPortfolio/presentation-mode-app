import AppKit
import CoreGraphics

@MainActor
final class AppController: NSObject {
    private let profileStore = RoomProfileStore()
    private var profiles = RoomProfileLibrary.initial
    private var profileLoadError: String?
    private let store: ConfigurationStoring
    private let captureService = DisplayCaptureService()
    private let deckLinkService = DeckLinkService()
    private let ndiService = NDIService()

    private var configuration: RoomConfiguration
    private var mode: PlayoutMode = .production
    private var displays: [DisplayChoice] = []
    private var isTransitioning = false
    private var healthTimer: Timer?
    private var lastError = ""
    private var startTime: Date?
    private var transitionGeneration = 0
    private var companionServer: CompanionControlServer?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let displayPopup = NSPopUpButton()
    private let outputStack = NSStackView()
    private let automaticSwitchingCheckbox = NSButton(checkboxWithTitle: "Automatically switch when ProPresenter opens or closes", target: nil, action: nil)
    private let ndiCheckbox = NSButton(checkboxWithTitle: "Enable NDI output", target: nil, action: nil)
    private let ndiSourceField = NSTextField()
    private let canvaButton = NSButton(title: "CANVA MODE", target: nil, action: nil)
    private let productionButton = NSButton(title: "PRODUCTION MODE", target: nil, action: nil)
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 790),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )

    init(store: ConfigurationStoring = DefaultsConfigurationStore()) {
        self.store = store
        self.configuration = store.load()
        if self.configuration.automaticProPresenterSwitchingEnabled == nil {
            self.configuration.automaticProPresenterSwitchingEnabled = BuildPolicy.isProduction
        }
        if self.configuration.ndiEnabled == nil {
            self.configuration.ndiEnabled = BuildPolicy.isProduction
        }
        if self.configuration.ndiSourceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            let hostName = Host.current().localizedName ?? "Presentation Mode"
            self.configuration.ndiSourceName = BuildPolicy.isProduction ? "\(hostName) - NDI" : "\(hostName) - Validation NDI"
        }
        super.init()
        store.save(self.configuration)
    }

    func launch() {
        deckLinkService.discover()
        do {
            profiles = try profileStore.load()
            if let active = profiles.active { try deckLinkService.configure(active, validateDevices: false) }
        } catch { profileLoadError = error.localizedDescription }
        configureWindow()
        configureStatusItem()
        // Expose validation controls before the operator hands over outputs.
        showWindow()
        companionServer = CompanionControlServer(
            statusProvider: { [weak self] in self?.companionStatus ?? CompanionStatus(deviceID: CompanionControlServer.deviceID, deviceName: Host.current().localizedName ?? "Presentation Mode", mode: "offline", proPresenterRunning: false, automaticProPresenterSwitchingEnabled: true, ndiRunning: false, ndiSource: "") },
            commandHandler: { [weak self] command in await self?.handleCompanionCommand(command) }
        )
        do {
            if BuildPolicy.companionEnabled() { try companionServer?.start(port: BuildPolicy.companionPort) }
        }
        catch { renderState(message: "Companion API could not start: \(error.localizedDescription)") }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(workspaceApplicationChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(workspaceApplicationChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        captureService.onFailure = { [weak self] message in
            Task { @MainActor in await self?.failPlayback("Capture stopped: " + message) }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkPlaybackHealth() }
        }
        Task {
            await refreshDisplays()
            if BuildPolicy.isProduction { await reconcileModeWithProPresenter() }
        }
        // Validation always opens stopped; production honors saved automatic switching.
    }

    deinit {
        companionServer?.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func prepareForTermination() async {
        healthTimer?.invalidate()
        companionServer?.stop()
        companionServer = nil
        deckLinkService.stop()
        ndiService.stop()
        await captureService.stop()
        mode = .production
    }

    private var companionStatus: CompanionStatus {
        CompanionStatus(deviceID: CompanionControlServer.deviceID,
                        deviceName: Host.current().localizedName ?? "Presentation Mode",
                        mode: mode.rawValue, lastError: lastError, routing: "largo-opaque-desktop", proPresenterRunning: isProPresenterRunning,
                        automaticProPresenterSwitchingEnabled: automaticSwitchingEnabled,
                        ndiRunning: ndiService.isRunning,
                        ndiSource: configuration.ndiEnabled == true ? (configuration.ndiSourceName ?? "") : "")
    }

    private func handleCompanionCommand(_ command: String) async {
        switch command {
        case "canva": await enterCanvaMode()
        case "production": await enterProductionMode(message: "Production Mode selected from Companion.")
        case "auto-enable": await setAutomaticSwitching(true, source: "Companion")
        case "auto-disable": await setAutomaticSwitching(false, source: "Companion")
        case "auto-toggle": await setAutomaticSwitching(!automaticSwitchingEnabled, source: "Companion")
        default: await reconcileModeWithProPresenter()
        }
    }

    private func configureWindow() {
        window.title = BuildPolicy.isProduction ? "Presentation Mode" : "Presentation Mode — Settings Preview"
        window.center()
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "Room Display Mode")
        title.font = .systemFont(ofSize: 28, weight: .bold)


        automaticSwitchingCheckbox.target = self
        automaticSwitchingCheckbox.action = #selector(automaticSwitchingChanged)
        automaticSwitchingCheckbox.state = automaticSwitchingEnabled ? .on : .off

        let displayLabel = NSTextField(labelWithString: "Canva display")
        displayLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)

        outputStack.orientation = .vertical
        outputStack.alignment = .leading
        outputStack.spacing = 4
        refreshProfileSummary()

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

        let stack = NSStackView(views: [title, outputStack, automaticSwitchingCheckbox, displayLabel, displayPopup, ndiLabel, ndiCheckbox, ndiSourceField, canvaButton, productionButton, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(24, after: outputStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let controls = NSView()
        controls.addSubview(stack)
        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 960, height: 790))
        let controlTab = NSTabViewItem(identifier: "controls"); controlTab.label = "Controls"; controlTab.view = controls
        let setupTab = NSTabViewItem(identifier: "setup"); setupTab.label = "Setup"
        setupTab.view = SetupView(loadDiagnostic: { [unowned self] in self.profileLoadError }, saved: { [unowned self] in self.profiles }, inventory: { [unowned self] in self.deckLinkService.inventory }, stopped: { [unowned self] in self.outputsStopped }, refresh: { [unowned self] in self.deckLinkService.discover() }, apply: { [unowned self] library in try self.applyProfiles(library) })
        tabs.addTabViewItem(controlTab); tabs.addTabViewItem(setupTab); tabs.selectTabViewItem(at: 0)
        window.contentView = tabs
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: controls.topAnchor, constant: 28),
            canvaButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            productionButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            displayPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ndiSourceField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        renderState(message: deckLinkService.dependencyMessage)
    }

    private var outputsStopped: Bool { !isTransitioning && mode == .production && !deckLinkService.isRunning && !ndiService.isRunning }
    private func refreshProfileSummary() {
        outputStack.arrangedSubviews.forEach { outputStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let active = profileLoadError == nil ? profiles.active : nil
        let heading = NSTextField(labelWithString: active == nil ? "No room profile loaded" : "Room profile loaded")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        outputStack.addArrangedSubview(heading)
        outputStack.addArrangedSubview(NSTextField(labelWithString: active?.name ?? "Open Setup to select a room profile."))
    }

    private func applyProfiles(_ library: RoomProfileLibrary) throws {
        guard outputsStopped else { throw ProfileError.invalid("Stop all outputs before applying settings.") }
        if let active = library.active {
            let errors = active.problems()
            guard errors.isEmpty else { throw ProfileError.invalid(errors.joined(separator: "\n")) }
        }
        try library.validate()
        guard let active = library.active else { throw ProfileError.invalid("Select a room profile.") }
        deckLinkService.discover()
        try deckLinkService.configure(active)
        do { try profileStore.save(library) }
        catch {
            if let previous = profiles.active { try? deckLinkService.configure(previous, validateDevices: false) }
            throw error
        }
        profiles = library; profileLoadError = nil; refreshProfileSummary()
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

    @objc func showWindow() {
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
        guard !isTransitioning, mode != .canva else { return }
        isTransitioning = true
        transitionGeneration += 1
        let generation = transitionGeneration
        defer { isTransitioning = false }
        guard !automaticSwitchingEnabled || !isProPresenterRunning else {
            await enterProductionMode(message: "Production Mode is locked while ProPresenter is running.")
            return
        }
        guard let displayID = configuration.sourceDisplayID else {
            renderState(message: "Connect the HDMI display emulator, then choose the Canva display.")
            return
        }
        do {
            lastError = ""
            // Check permission before claiming outputs; never prompt in a retry loop.
            guard CGPreflightScreenCaptureAccess() else { throw DisplayCaptureService.CaptureError.permissionUnavailable }
            if let error = profileLoadError { throw ProfileError.invalid(error) }
            guard let active = profiles.active else { throw ProfileError.invalid("No active room profile.") }
            deckLinkService.discover()
            try deckLinkService.configure(active)
            try deckLinkService.start()
            if configuration.ndiEnabled == true {
                try ndiService.start(sourceName: configuration.ndiSourceName ?? "")
            }
            let deckLinkSink = deckLinkService
            let ndiSink = ndiService
            let sendNDI = configuration.ndiEnabled == true
            try await captureService.start(displayID: displayID) { frame in
                deckLinkSink.enqueue(frame)
                if sendNDI { ndiSink.send(frame) }
            }
            guard generation == transitionGeneration else {
                deckLinkService.stop()
                ndiService.stop()
                await captureService.stop()
                return
            }
            mode = .canva
            startTime = Date()
            let ndiStatus = configuration.ndiEnabled == true ? " and NDI source ‘\(configuration.ndiSourceName ?? "")’" : ""
            let automaticStatus = automaticSwitchingEnabled ? " ProPresenter will automatically reclaim production outputs when it opens." : " Automatic ProPresenter switching is off."
            renderState(message: "Canva Mode active on selected DeckLinks\(ndiStatus).\(automaticStatus)")
        } catch { await failPlayback(error.localizedDescription) }
    }

    private func enterProductionMode(message: String = "DeckLink outputs are released for production software.") async {
        transitionGeneration += 1
        let cleanupError = deckLinkService.stop()
        ndiService.stop()
        await captureService.stop()
        mode = .production
        startTime = nil
        if let cleanupError { lastError = cleanupError }
        renderState(message: cleanupError ?? message)
    }

    private var isProPresenterRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            application.localizedName?.caseInsensitiveCompare("ProPresenter") == .orderedSame &&
                !application.isTerminated
        }
    }

    private var automaticSwitchingEnabled: Bool {
        configuration.automaticProPresenterSwitchingEnabled != false
    }

    private func setAutomaticSwitching(_ enabled: Bool, source: String? = nil) async {
        configuration.automaticProPresenterSwitchingEnabled = enabled
        automaticSwitchingCheckbox.state = enabled ? .on : .off
        store.save(configuration)
        if enabled {
            await reconcileModeWithProPresenter()
        } else {
            let suffix = source.map { " from \($0)" } ?? ""
            renderState(message: "Automatic ProPresenter switching turned off\(suffix). Mode changes are now manual.")
        }
    }

    private func reconcileModeWithProPresenter() async {
        guard automaticSwitchingEnabled else {
            renderState(message: "Automatic ProPresenter switching is off. Mode changes are manual.")
            return
        }
        if isProPresenterRunning {
            await enterProductionMode(message: "Production Mode is locked while ProPresenter is running.")
        } else if !isTransitioning {
            await enterCanvaMode()
        }
    }

    private func failPlayback(_ message: String) async {
        lastError = message
        await enterProductionMode(message: message)
    }

    private func checkPlaybackHealth() async {
        guard mode == .canva, !isTransitioning else { return }
        let state = deckLinkService.state
        if state.code < 0 { await failPlayback(state.message) }
        else if state.code == 1, let startTime, Date().timeIntervalSince(startTime) > 3 {
            await failPlayback("No complete capture frame arrived; keys cleared and outputs released.")
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
        guard automaticSwitchingEnabled else { return }
        Task { await reconcileModeWithProPresenter() }
    }

    @objc private func automaticSwitchingChanged() {
        Task { await setAutomaticSwitching(automaticSwitchingCheckbox.state == .on) }
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
