import Accelerate
import CoreMedia
import CoreVideo
import DeckLinkBridge
import Foundation

struct DeckLinkOutput: Identifiable, Equatable {
    let id: String
    let name: String
    let supports1080p5994: Bool
}

/// DeckLink is intentionally isolated here so the controller and capture pipeline
/// remain testable without Blackmagic hardware. The production implementation will
/// bind this service to the Blackmagic Desktop Video SDK.
final class DeckLinkService {
    private(set) var outputs: [DeckLinkOutput] = []
    private(set) var isRunning = false
    private let session = pm_decklink_session_create()

    deinit {
        pm_decklink_session_destroy(session)
    }

    var dependencyMessage: String? {
        if outputs.isEmpty {
            return "No active playback-capable DeckLink outputs were found. Check Desktop Video Setup and the card profile."
        }
        let unsupported = outputs.filter { !$0.supports1080p5994 }
        if !unsupported.isEmpty {
            return "Some DeckLink endpoints do not support 1080p59.94 BGRA in the current profile."
        }
        return nil
    }

    func discover() {
        let count = pm_decklink_discover(nil, 0)
        guard count > 0 else {
            outputs = []
            return
        }

        var records = Array(repeating: PMDeckLinkDeviceInfo(), count: Int(count))
        let discovered = records.withUnsafeMutableBufferPointer { buffer in
            pm_decklink_discover(buffer.baseAddress, count)
        }
        guard discovered >= 0 else {
            outputs = []
            return
        }

        let discoveredOutputs = records.prefix(Int(min(discovered, count))).compactMap { record -> DeckLinkOutput? in
            guard record.supports_playback, record.is_active else { return nil }
            let name = withUnsafePointer(to: record.display_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 256) {
                    String(cString: $0)
                }
            }
            let stableID = String(format: "%016llx:%lld", record.persistent_id, record.subdevice_index)
            return DeckLinkOutput(
                id: stableID,
                name: name.isEmpty ? "DeckLink output" : name,
                supports1080p5994: record.supports_1080p5994_bgra
            )
        }

        let nameCounts = Dictionary(grouping: discoveredOutputs, by: \.name).mapValues(\.count)
        var duplicateIndexes: [String: Int] = [:]
        outputs = discoveredOutputs.sorted { $0.id < $1.id }.map { output in
            guard nameCounts[output.name, default: 0] > 1 else { return output }
            let index = duplicateIndexes[output.name, default: 0]
            duplicateIndexes[output.name] = index + 1
            let suffix = String(UnicodeScalar(65 + index)!)
            return DeckLinkOutput(
                id: output.id,
                name: "\(output.name) — Card \(suffix)",
                supports1080p5994: output.supports1080p5994
            )
        }

        for output in outputs {
            print("DeckLink: \(output.name) [\(output.id)] 1080p59.94 BGRA=\(output.supports1080p5994)")
        }
    }

    func start(outputIDs: Set<String>, standard: String) throws {
        guard !outputs.isEmpty else { throw DeckLinkError.runtimeUnavailable }
        guard !outputIDs.isEmpty else { throw DeckLinkError.noOutputsSelected }
        guard standard == "1080p59.94" else { throw DeckLinkError.unsupportedStandard(standard) }

        let selected = outputIDs.sorted()
        let allocatedStrings = selected.map { strdup($0) }
        let cStrings: [UnsafePointer<CChar>?] = allocatedStrings.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        defer { allocatedStrings.forEach { free($0) } }
        var errorBuffer = Array<CChar>(repeating: 0, count: 512)
        let result = cStrings.withUnsafeBufferPointer { ids in
            errorBuffer.withUnsafeMutableBufferPointer { error in
                pm_decklink_session_start(
                    session,
                    ids.baseAddress,
                    Int32(ids.count),
                    error.baseAddress,
                    error.count
                )
            }
        }
        guard result == 0 else {
            throw DeckLinkError.playbackFailure(Self.decodeError(errorBuffer))
        }
        isRunning = true
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard Self.forceOpaqueAlpha(pixelBuffer) else {
            fputs("DeckLink playback error: captured frame is not writable 32-bit BGRA.\n", stderr)
            return
        }
        var errorBuffer = Array<CChar>(repeating: 0, count: 512)
        let result = errorBuffer.withUnsafeMutableBufferPointer { error in
            pm_decklink_session_enqueue_pixel_buffer(
                session,
                Unmanaged.passUnretained(pixelBuffer).toOpaque(),
                error.baseAddress,
                error.count
            )
        }
        if result < 0 {
            let message = Self.decodeError(errorBuffer)
            fputs("DeckLink playback error: \(message)\n", stderr)
        }
    }

    func stop() {
        pm_decklink_session_stop(session)
        isRunning = false
    }

    private static func decodeError(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// ScreenCaptureKit supplies BGRA. DeckLink and downstream keyers may
    /// preserve its fourth byte, so make the presentation desktop explicitly
    /// opaque before scheduling it. For BGRA memory order, vImage's channel
    /// mask bit 0x1 addresses the fourth (alpha) byte.
    private static func forceOpaqueAlpha(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let image = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        var source = image
        var destination = image
        return vImageOverwriteChannelsWithScalar_ARGB8888(
            255,
            &source,
            &destination,
            0x1,
            vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError
    }

    enum DeckLinkError: LocalizedError {
        case runtimeUnavailable
        case noOutputsSelected
        case unsupportedStandard(String)
        case playbackFailure(String)

        var errorDescription: String? {
            switch self {
            case .runtimeUnavailable:
                "No active playback-capable DeckLink output is available. Check Desktop Video Setup and the card profile."
            case .noOutputsSelected:
                "Select at least one DeckLink SDI output before entering Canva Mode."
            case .unsupportedStandard(let standard):
                "The configured video standard \(standard) is not supported. Choose 1080p59.94."
            case .playbackFailure(let message):
                message.isEmpty ? "DeckLink scheduled playback could not start." : message
            }
        }
    }
}
