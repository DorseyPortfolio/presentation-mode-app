import Accelerate
import CoreMedia
import CoreVideo
import DeckLinkBridge
import Foundation

struct DeckLinkOutput: Identifiable, Equatable {
    let id: String
    let name: String
    let capability: OutputCapability
    var supports1080p5994: Bool { capability.modes & OutputTiming.p5994.mask != 0 }
}

/// DeckLink is intentionally isolated here so the controller and capture pipeline
/// remain testable without Blackmagic hardware. The production implementation will
/// bind this service to the Blackmagic Desktop Video SDK.
// UI discovery state is main-thread owned; frame submission uses the native mutex.
final class DeckLinkService: @unchecked Sendable {
    private(set) var outputs: [DeckLinkOutput] = []
    var isRunning: Bool { state.code > 0 }
    var state: (code: Int32, message: String) {
        var buffer = Array<CChar>(repeating: 0, count: 1024)
        let code = pm_decklink_session_status(session, &buffer, buffer.count)
        return (code, Self.decodeError(buffer))
    }
    private let session = pm_decklink_session_create()

    deinit {
        pm_decklink_session_destroy(session)
    }

    var dependencyMessage: String? {
        if outputs.isEmpty {
            return "No active playback-capable DeckLink outputs were found. Check Desktop Video Setup and the card profile."
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
                capability: OutputCapability(id: stableID, name: name, modes: record.mode_mask, physicalGroup: record.has_physical_group ? record.physical_group : nil, synchronized: record.supports_sync_group)
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
                capability: output.capability
            )
        }

        for output in outputs {
            print("DeckLink: \(output.name) [\(output.id)] 1080p59.94 BGRA=\(output.supports1080p5994)")
        }
    }

    func configure(_ profile: RoomProfile, validateDevices: Bool = true) throws {
        let problems = profile.problems(devices: validateDevices ? outputs.map(\.capability) : nil)
        guard problems.isEmpty else { throw ProfileError.invalid(problems.joined(separator: "\n")) }
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func owned(_ text: String) -> UnsafePointer<CChar> {
            let pointer = strdup(text)!
            strings.append(pointer); return UnsafePointer(pointer)
        }
        var routes: [PMDeckLinkRoute] = []
        for (group, d) in profile.destinations.enumerated() {
            routes.append(PMDeckLinkRoute(id: owned(d.picture), label: owned(d.name + " picture"), group: Int32(group), key: false, duration: d.timing.duration))
            if let key = d.key {
                routes.append(PMDeckLinkRoute(id: owned(key), label: owned(d.name + " key"), group: Int32(group), key: true, duration: d.timing.duration))
            }
        }
        var error = Array<CChar>(repeating: 0, count: 1024)
        let result = routes.withUnsafeBufferPointer { pm_decklink_session_configure(session, $0.baseAddress, $0.count, &error, error.count) }
        guard result == 0 else { throw ProfileError.invalid(Self.decodeError(error)) }
    }

    func start() throws {
        var errorBuffer = Array<CChar>(repeating: 0, count: 1024)
        let result = pm_decklink_session_start(session, &errorBuffer, errorBuffer.count)
        guard result == 0 else { throw DeckLinkError.playbackFailure(Self.decodeError(errorBuffer)) }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var errorBuffer = Array<CChar>(repeating: 0, count: 1024)
        let result = pm_decklink_session_enqueue_pixel_buffer(session,
            Unmanaged.passUnretained(pixelBuffer).toOpaque(), &errorBuffer, errorBuffer.count)
        if result < 0 { fputs("DeckLink frame rejected: \(Self.decodeError(errorBuffer))\n", stderr) }
    }

    @discardableResult
    func stop() -> String? {
        var errorBuffer = Array<CChar>(repeating: 0, count: 1024)
        let result = pm_decklink_session_stop(session, &errorBuffer, errorBuffer.count)
        return result < 0 ? Self.decodeError(errorBuffer) : nil
    }

    private static func decodeError(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
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
