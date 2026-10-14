import Foundation
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}
@main struct ProfileTests {
    static func main() throws {
        let largo = RoomProfile.largo
        assert(largo.problems().isEmpty && largo.destinations.count == 3)
        assert(largo.destinations[0].timing == .p50 && largo.destinations[2].key == nil)
        let defaults = MemoryDefaults()
        let store = RoomProfileStore(defaults: defaults)
        var library = try store.load()
        assert(library.active == largo)
        var direct = RoomProfile(name: "Direct room", destinations: [Destination(name: "Screen", picture: "out1", key: nil, timing: .p24)])
        var devices = [OutputCapability(id: "out1", name: "One", modes: 255, physicalGroup: nil, synchronized: false)]
        assert(direct.problems(devices: devices).isEmpty)
        library.profiles.append(direct); library.activeID = direct.id
        try store.save(library)
        let reloaded = try store.load(); assert(reloaded == library)
        direct.destinations[0].key = "out2"
        assert(!direct.problems(devices: devices).isEmpty)
        devices.append(OutputCapability(id: "out2", name: "Two", modes: 255, physicalGroup: 2, synchronized: true))
        assert(!direct.problems(devices: devices).isEmpty)
        devices[0].physicalGroup = 2; devices[0].synchronized = true
        assert(direct.problems(devices: devices).isEmpty)
        devices[1].modes = OutputTiming.p50.mask
        assert(!direct.problems(devices: devices).isEmpty)
        direct.destinations[0].key = "out1"
        assert(!direct.problems().isEmpty)
        direct.destinations[0].key = nil
        direct.destinations.append(direct.destinations[0])
        assert(!direct.problems().isEmpty)
        library.schemaVersion = 99
        do { try store.save(library); assertionFailure("unsupported schema saved") } catch {}
        let preserved = try store.load(); assert(preserved.schemaVersion == 1)
        defaults.set(Data("broken".utf8), forKey: "roomProfiles.v1")
        do { _ = try store.load(); assertionFailure("corrupt profile silently accepted") } catch {}
        assert(defaults.data(forKey: "roomProfiles.v1") == Data("broken".utf8))
        assert(OutputTiming.allCases.map(\.duration) == [2502,2500,2400,2002,2000,1200,1001,1000])
        print("PASS: Largo migration, direct/pair validation, collisions, unsupported modes/cards, versioned persistence and corrupt-data preservation")
    }
}
