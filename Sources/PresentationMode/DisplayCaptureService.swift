import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit

struct DisplayChoice: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
}

@MainActor
final class DisplayCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFailure: (@MainActor (String) -> Void)?
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "PresentationMode.ScreenCapture")
    nonisolated private let delivery = CaptureDelivery()

    func availableDisplays() async throws -> [DisplayChoice] {
        // Display enumeration does not require capturing or requesting consent.
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return DisplayChoice(id: id, name: screen.localizedName,
                                 width: Int(CGDisplayPixelsWide(id)), height: Int(CGDisplayPixelsHigh(id)))
        }
    }

    func start(displayID: CGDirectDisplayID, frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        await stop()
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 1920
        configuration.height = 1080
        configuration.minimumFrameInterval = CMTime(value: 1001, timescale: 60_000)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        // This app only forwards screen frames; avoid requesting unused audio.
        configuration.capturesAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        delivery.install(streamID: ObjectIdentifier(stream), handler: frameHandler)
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        delivery.clear()
        try? await stream.stopCapture()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        delivery.send(sampleBuffer, streamID: ObjectIdentifier(stream))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.stream = nil
            self.delivery.clear()
            self.onFailure?(error.localizedDescription)
        }
    }

    enum CaptureError: LocalizedError {
        case displayUnavailable
        case permissionUnavailable

        var errorDescription: String? {
            switch self {
            case .displayUnavailable: return "The selected Canva display is no longer connected."
            case .permissionUnavailable:
                return "Screen Recording access is unavailable for \(Bundle.main.bundleIdentifier ?? "this executable") at \(Bundle.main.bundlePath). No permission request was made."
            }
        }
    }
}

/// Only the sample callback crosses queues. Drop late callbacks from old streams.
private final class CaptureDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var streamID: ObjectIdentifier?
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?
    func install(streamID: ObjectIdentifier, handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.streamID = streamID; self.handler = handler
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        streamID = nil; handler = nil
    }
    func send(_ sample: CMSampleBuffer, streamID: ObjectIdentifier) {
        lock.lock()
        let callback = self.streamID == streamID ? handler : nil
        lock.unlock()
        callback?(sample)
    }
}
