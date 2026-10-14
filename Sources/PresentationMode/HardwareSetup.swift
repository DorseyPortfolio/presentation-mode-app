import Foundation

/// Actual SDI capabilities returned by the SDK, independent of formats the
/// current 1920x1080 capture/scheduler implementation can produce.
struct HardwareMode: Equatable, Identifiable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
    let frameDuration: Int64
    let timeScale: Int64
    let progressive: Bool
    let bgra: Bool
    let yuv: Bool
    var supportedTiming: OutputTiming? {
        guard width == 1920, height == 1080, progressive, bgra || yuv,
              frameDuration > 0, timeScale > 0 else { return nil }
        return OutputTiming.allCases.first {
            // SDK uses different equivalent rational timescales; compare without
            // floating-point rounding or potentially overflowing multiplication.
            reduced(frameDuration, timeScale) == reduced($0.duration, 120000)
        }
    }
    private func reduced(_ a: Int64, _ b: Int64) -> String {
        var x = a, y = b
        while y != 0 { let r = x % y; x = y; y = r }
        return "\(a / x)/\(b / x)"
    }
    func matches(_ other: HardwareMode) -> Bool {
        id == other.id && width == other.width && height == other.height && progressive == other.progressive &&
        frameDuration > 0 && timeScale > 0 && other.frameDuration > 0 && other.timeScale > 0 &&
        reduced(frameDuration, timeScale) == reduced(other.frameDuration, other.timeScale)
    }
}
struct HardwareEndpoint: Identifiable, Equatable {
    let id: String
    let connectorIndex: Int64
    let connectorLabel: String // SDK display name; never inferred as a physical card.
    let modelLabel: String
    let physicalGroup: Int64?
    let active: Bool
    let playback: Bool
    let synchronized: Bool
    let modes: [HardwareMode]
    let discoveryIssue: String?
    var cardID: String { physicalGroup.map { String(format: "card:%016llx", $0) } ?? "unknown:\(id)" }
    var selectable: Bool { active && playback && discoveryIssue == nil && !modes.isEmpty }
    var capability: OutputCapability {
        OutputCapability(id: id, name: connectorLabel,
            modes: modes.compactMap(\.supportedTiming).reduce(0) { $0 | $1.mask },
            physicalGroup: physicalGroup, synchronized: synchronized)
    }
}
struct HardwareCard: Identifiable, Equatable {
    let id: String
    let label: String
    let groupingKnown: Bool
    let outputs: [HardwareEndpoint]
}
struct HardwareInventory: Equatable {
    var endpoints: [HardwareEndpoint] = []
    var issues: [String] = []
    var cards: [HardwareCard] {
        Dictionary(grouping: endpoints, by: \.cardID).sorted { $0.key < $1.key }.map { id, outputs in
            let ordered = outputs.sorted { ($0.connectorIndex, $0.id) < ($1.connectorIndex, $1.id) }
            let models = Set(ordered.map(\.modelLabel).filter { !$0.isEmpty }).sorted().joined(separator: " / ")
            let label = models.isEmpty ? "DeckLink" : models
            // Stable SDK group ID disambiguates identical card models. Unknown
            // groups stay separate; no guessed slot numbers or card pairings.
            return HardwareCard(id: id, label: "\(label) [\(id)]", groupingKnown: ordered[0].physicalGroup != nil, outputs: ordered)
        }
    }
    func pairingIssue(fill: String, key: String) -> String? {
        guard fill != key else { return "Fill and key must use different outputs." }
        guard let f = endpoints.first(where: { $0.id == fill }), let k = endpoints.first(where: { $0.id == key }), f.selectable, k.selectable else { return "Select active playback outputs with known capabilities." }
        guard f.synchronized, k.synchronized, let group = f.physicalGroup, group == k.physicalGroup else { return "Fill/key requires synchronization support on the same physical card." }
        return nil
    }
    func commonModes(fill: String, key: String? = nil) -> [HardwareMode] {
        guard let f = endpoints.first(where: { $0.id == fill }), f.selectable else { return [] }
        guard let key else { return f.modes }
        guard pairingIssue(fill: fill, key: key) == nil, let k = endpoints.first(where: { $0.id == key }) else { return [] }
        return f.modes.filter { mode in k.modes.contains { mode.matches($0) } }
    }
    func selectableTimings(fill: String, key: String? = nil) -> [OutputTiming] {
        let supported = Set(commonModes(fill: fill, key: key).compactMap(\.supportedTiming))
        return OutputTiming.allCases.filter { supported.contains($0) }
    }
}

enum HardwareOutputRole: Equatable { case unused, direct, fill, key }
struct HardwareOutputRow: Identifiable {
    let endpoint: HardwareEndpoint
    let assignmentIDs: [UUID]
    let role: HardwareOutputRole
    let pairedOutputID: String?
    var id: String { endpoint.id }
    var collision: Bool { assignmentIDs.count > 1 }
}
struct HardwareCardRow: Identifiable {
    let card: HardwareCard
    let outputs: [HardwareOutputRow]
    var id: String { card.id }
}

/// Hardware-first projection/edit model. Cards and connectors organize rows;
/// legacy destination names survive only as optional assignment metadata in
/// the existing profile schema. No fixed room names or connector counts.
struct HardwareSetupDraft {
    private(set) var profile: RoomProfile
    private(set) var inventory: HardwareInventory
    init(profile: RoomProfile, inventory: HardwareInventory) { self.profile = profile; self.inventory = inventory }
    var cards: [HardwareCardRow] {
        inventory.cards.map { card in
            HardwareCardRow(card: card, outputs: card.outputs.map { endpoint in
                let assignments = profile.destinations.filter { $0.picture == endpoint.id || $0.key == endpoint.id }
                let first = assignments.first
                let role: HardwareOutputRole = first.map { $0.key == endpoint.id ? .key : ($0.key == nil ? .direct : .fill) } ?? .unused
                let partner = first.flatMap { $0.picture == endpoint.id ? $0.key : $0.picture }
                return HardwareOutputRow(endpoint: endpoint, assignmentIDs: assignments.map(\.id), role: role, pairedOutputID: partner)
            })
        }
    }
    var missingAssignments: [Destination] {
        profile.destinations.filter { d in
            !inventory.endpoints.contains(where: { $0.id == d.picture }) ||
            (d.key.map { key in !inventory.endpoints.contains(where: { $0.id == key }) } ?? false)
        }
    }
    mutating func rescan(_ inventory: HardwareInventory) { self.inventory = inventory } // Never rewrites profile.
    mutating func removeAssignment(_ id: UUID) { profile.destinations.removeAll { $0.id == id } }
    mutating func assign(fill: String, key: String?, timing: OutputTiming, replacing id: UUID? = nil) throws {
        if let id, !profile.destinations.contains(where: { $0.id == id }) { throw ProfileError.invalid("The assignment no longer exists.") }
        if let key, let error = inventory.pairingIssue(fill: fill, key: key) { throw ProfileError.invalid(error) }
        guard inventory.selectableTimings(fill: fill, key: key).contains(timing) else { throw ProfileError.invalid("Choose a format supported by this output or both paired outputs and the app.") }
        let selected = Set([fill, key].compactMap { $0 })
        guard !profile.destinations.filter({ $0.id != id }).contains(where: { !selected.isDisjoint(with: [$0.picture, $0.key].compactMap { $0 }) }) else { throw ProfileError.invalid("An output is already assigned. Remove or edit its existing assignment first.") }
        var candidate = profile
        if let id, let index = candidate.destinations.firstIndex(where: { $0.id == id }) {
            candidate.destinations[index].picture = fill; candidate.destinations[index].key = key; candidate.destinations[index].timing = timing
        } else {
            candidate.destinations.append(Destination(name: "Output \(fill)", picture: fill, key: key, timing: timing))
        }
        let issues = candidate.problems()
        guard issues.isEmpty else { throw ProfileError.invalid(issues.joined(separator: "\n")) }
        profile = candidate
    }
    var problems: [String] {
        inventory.issues + profile.problems(devices: inventory.endpoints.filter(\.selectable).map(\.capability))
    }
}
