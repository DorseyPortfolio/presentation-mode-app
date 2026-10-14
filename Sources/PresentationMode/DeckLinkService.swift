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
    private(set) var inventory = HardwareInventory()
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
        // A bounded retry handles device-count changes between count and copy.
        // A failed rescan clears availability, but never edits saved assignments.
        var records: [PMDeckLinkDeviceInfo] = []
        var complete = false
        for _ in 0..<3 {
            let count = pm_decklink_discover(nil, 0)
            guard count >= 0 else { break }
            if count == 0 { complete = true; break }
            var buffer = Array(repeating: PMDeckLinkDeviceInfo(), count: Int(count))
            let found = buffer.withUnsafeMutableBufferPointer { pm_decklink_discover($0.baseAddress, count) }
            if found >= 0 && found <= count { records = Array(buffer.prefix(Int(found))); complete = true; break }
        }
        guard complete else {
            inventory = HardwareInventory(issues: ["DeckLink discovery failed or devices changed during rescan. Refresh devices."])
            outputs = []; return
        }
        func text<T>(_ value: T) -> String {
            withUnsafePointer(to: value) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
            }
        }
        var endpoints: [HardwareEndpoint] = []
        for record in records {
            let id = String(format: "%016llx:%lld", record.persistent_id, record.subdevice_index)
            var modes: [HardwareMode] = []
            var issue: String?
            if record.is_active && record.supports_playback {
                var copied = false
                for _ in 0..<3 {
                    let count = id.withCString { pm_decklink_output_modes($0, nil, 0) }
                    guard count >= 0 else { break }
                    if count == 0 { copied = true; break }
                    var buffer = Array(repeating: PMDeckLinkModeInfo(), count: Int(count))
                    let found = id.withCString { outputID in
                        buffer.withUnsafeMutableBufferPointer { pm_decklink_output_modes(outputID, $0.baseAddress, count) }
                    }
                    if found >= 0 && found <= count {
                        modes = buffer.prefix(Int(found)).map { mode in
                            HardwareMode(id: mode.mode_id, name: text(mode.name), width: Int(mode.width), height: Int(mode.height), frameDuration: mode.frame_duration, timeScale: mode.time_scale, progressive: mode.progressive, bgra: mode.supports_bgra, yuv: mode.supports_yuv)
                        }
                        copied = true; break
                    }
                }
                if !copied { issue = "Mode discovery failed; refresh devices." }
            }
            let name = text(record.display_name)
            endpoints.append(HardwareEndpoint(id: id, connectorIndex: record.subdevice_index,
                connectorLabel: name.isEmpty ? "DeckLink output \(record.subdevice_index)" : name,
                modelLabel: text(record.model_name), physicalGroup: record.has_physical_group ? record.physical_group : nil,
                active: record.is_active, playback: record.supports_playback, synchronized: record.supports_sync_group,
                modes: modes, discoveryIssue: issue))
        }
        let duplicates = Dictionary(grouping: endpoints, by: \.id).filter { $0.value.count > 1 }
        if !duplicates.isEmpty {
            inventory = HardwareInventory(issues: ["DeckLink returned duplicate endpoint identities; assignments are blocked until a clean rescan."])
            outputs = []; return
        }
        inventory = HardwareInventory(endpoints: endpoints)
        outputs = inventory.cards.flatMap { card in
            card.outputs.filter(\.selectable).map { endpoint in
                DeckLinkOutput(id: endpoint.id, name: "\(card.label) / \(endpoint.connectorLabel)", capability: endpoint.capability)
            }
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
