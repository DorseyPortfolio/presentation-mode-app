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
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "PresentationMode.ScreenCapture")
    nonisolated(unsafe) private var frameHandler: ((CMSampleBuffer) -> Void)?

    func availableDisplays() async throws -> [DisplayChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.displays.map { display in
            let screenName = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            })?.localizedName ?? "Display \(display.displayID)"
            return DisplayChoice(id: display.displayID, name: screenName, width: display.width, height: display.height)
        }
    }

    func start(displayID: CGDirectDisplayID, frameHandler: @escaping (CMSampleBuffer) -> Void) async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }

        self.frameHandler = frameHandler
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 1920
        configuration.height = 1080
        configuration.minimumFrameInterval = CMTime(value: 1001, timescale: 60_000)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        frameHandler = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        frameHandler?(sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.stream = nil
            self.frameHandler = nil
        }
    }

    enum CaptureError: LocalizedError {
        case displayUnavailable

        var errorDescription: String? { "The selected Canva display is no longer connected." }
    }
}
