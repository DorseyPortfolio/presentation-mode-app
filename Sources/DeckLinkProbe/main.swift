import DeckLinkBridge
import Foundation

let count = pm_decklink_discover(nil, 0)
guard count >= 0 else {
    fputs("DeckLink runtime unavailable\n", stderr)
    exit(1)
}

var records = Array(repeating: PMDeckLinkDeviceInfo(), count: Int(count))
let result = records.withUnsafeMutableBufferPointer {
    pm_decklink_discover($0.baseAddress, count)
}
guard result >= 0 else {
    fputs("DeckLink discovery failed\n", stderr)
    exit(1)
}

print("DeckLink devices: \(result)")
for record in records.prefix(Int(min(count, result))) {
    let name = withUnsafePointer(to: record.display_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    let id = String(format: "%016llx:%lld", record.persistent_id, record.subdevice_index)
    print("\(id) | \(name) | playback=\(record.supports_playback) active=\(record.is_active) 1080p59.94-bgra=\(record.supports_1080p5994_bgra)")
}
