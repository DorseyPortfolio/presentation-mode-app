import Foundation

enum OutputTiming: String, Codable, CaseIterable {
    case p2398 = "1080p23.98", p24 = "1080p24", p25 = "1080p25", p2997 = "1080p29.97"
    case p30 = "1080p30", p50 = "1080p50", p5994 = "1080p59.94", p60 = "1080p60"
    var duration: Int64 { [2502,2500,2400,2002,2000,1200,1001,1000][Self.allCases.firstIndex(of: self)!] }
    var mask: UInt32 { 1 << Self.allCases.firstIndex(of: self)! }
}
struct OutputCapability: Equatable {
    var id: String
    var name: String
    var modes: UInt32
    var physicalGroup: Int64?
    var synchronized: Bool
}
struct Destination: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var picture: String
    var key: String?
    var timing: OutputTiming
}
struct RoomProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var destinations: [Destination]
    // Deliberately one supported matte policy: opaque desktop, white active key,
    // black key on stop. Transparency needs a separate capture/output design.
    var matte = "opaqueDesktop"
    static let largo = RoomProfile(name: "Largo Pro1", destinations: [
        Destination(name: "Side Screens", picture: "00000000254a3ad3:3", key: "00000000254a3ad1:1", timing: .p50),
        Destination(name: "LED Wall", picture: "0000000002cf3ad0:0", key: "0000000002cf3ad3:3", timing: .p5994),
        Destination(name: "Confidence", picture: "0000000002cf3ad1:1", key: nil, timing: .p5994)
    ])
    func problems(devices: [OutputCapability]? = nil) -> [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Name the room profile.") }
        if matte != "opaqueDesktop" { errors.append("Unsupported matte policy.") }
        if destinations.isEmpty || destinations.count > 16 { errors.append("Configure 1–16 destinations.") }
        var names = Set<String>(), ids = Set<String>(), destinationIDs = Set<UUID>()
        for d in destinations {
            if !destinationIDs.insert(d.id).inserted { errors.append("Duplicate destination identity.") }
            let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name.isEmpty || !names.insert(name).inserted { errors.append("Destination names must be nonempty and unique.") }
            for id in [d.picture, d.key].compactMap({ $0 }) {
                if id.isEmpty || !ids.insert(id).inserted { errors.append("\(d.name): select distinct, unshared endpoints.") }
                if let devices {
                    guard let device = devices.first(where: { $0.id == id }) else {
                        errors.append("\(d.name): endpoint \(id) is missing or inactive."); continue
                    }
                    if device.modes & d.timing.mask == 0 { errors.append("\(d.name): \(device.name) does not support \(d.timing.rawValue).") }
                }
            }
            if let key = d.key, let devices,
               let fill = devices.first(where: { $0.id == d.picture }),
               let matte = devices.first(where: { $0.id == key }) {
                if !fill.synchronized || !matte.synchronized || fill.physicalGroup == nil || fill.physicalGroup != matte.physicalGroup {
                    errors.append("\(d.name): fill/key requires synchronized outputs on the same card.")
                }
            }
        }
        return errors
    }
}
struct RoomProfileLibrary: Codable, Equatable {
    var schemaVersion = 1
    var activeID: UUID
    var profiles: [RoomProfile]
    static var initial: Self { let p = RoomProfile.largo; return Self(activeID: p.id, profiles: [p]) }
    var active: RoomProfile? { profiles.first { $0.id == activeID } }
    func validate() throws {
        guard schemaVersion == 1, active != nil, !profiles.isEmpty,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == profiles.count,
              profiles.allSatisfy({ $0.problems().isEmpty }) else {
            throw ProfileError.invalid("Invalid or unsupported saved room profiles. Existing data has been preserved.")
        }
    }
}
enum ProfileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
struct RoomProfileStore {
    let defaults: UserDefaults
    private let key = "roomProfiles.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> RoomProfileLibrary {
        // 0.4.5 routing was fixed in native code: migrate that exact verified
        // route. Legacy enabledOutputIDs never represented the fill/key roles.
        guard let data = defaults.data(forKey: key) else { return .initial }
        let library = try JSONDecoder().decode(RoomProfileLibrary.self, from: data)
        try library.validate(); return library
    }
    func save(_ library: RoomProfileLibrary) throws {
        try library.validate()
        let data = try JSONEncoder().encode(library)
        defaults.set(data, forKey: key)
    }
}
