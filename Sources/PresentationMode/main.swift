import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var isPreparingToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        controller?.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate, let controller else { return .terminateNow }
        isPreparingToTerminate = true
        Task { @MainActor in
            await controller.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

let application = NSApplication.shared
let delegate = ApplicationDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
