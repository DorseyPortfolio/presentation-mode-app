import Foundation
@main struct HardwareSetupTests {
    static func main() throws {
        func mode(_ id: UInt32 = 1, duration: Int64 = 1001, scale: Int64 = 60000, width: Int = 1920) -> HardwareMode {
            HardwareMode(id: id, name: "SDK mode", width: width, height: 1080, frameDuration: duration, timeScale: scale, progressive: true, bgra: true, yuv: false)
        }
        func endpoint(_ id: String, card: Int64?, index: Int64 = 0, modes: [HardwareMode]? = nil, active: Bool = true, playback: Bool = true, sync: Bool = true) -> HardwareEndpoint {
            HardwareEndpoint(id: id, connectorIndex: index, connectorLabel: "Connector \(index)", modelLabel: "DeckLink Duo", physicalGroup: card, active: active, playback: playback, synchronized: sync, modes: modes ?? [mode(),mode(2,duration:1200)], discoveryIssue: nil)
        }
        var endpoints: [HardwareEndpoint] = []
        for card in 1...4 { for output in 0..<4 { endpoints.append(endpoint("\(card):\(output)", card: Int64(card), index: Int64(output))) } }
        var inventory = HardwareInventory(endpoints: endpoints)
        assert(inventory.cards.count == 4 && inventory.cards.allSatisfy { $0.outputs.count == 4 })
        assert(inventory.selectableTimings(fill: "1:0", key: "1:1") == [.p50,.p5994])
        assert(inventory.commonModes(fill: "1:0", key: "2:0").isEmpty)
        assert(inventory.commonModes(fill: "1:0", key: "1:0").isEmpty)
        let original = RoomProfile.largo
        var preserved = HardwareSetupDraft(profile: original, inventory: inventory)
        assert(preserved.missingAssignments.count == 3 && preserved.profile == original)
        preserved.rescan(HardwareInventory()); assert(preserved.profile == original)
        var draft = HardwareSetupDraft(profile: RoomProfile(name: "Four cards", destinations: []), inventory: inventory)
        try draft.assign(fill: "1:0", key: "1:1", timing: .p50)
        assert(draft.cards[0].outputs[0].role == .fill && draft.cards[0].outputs[0].pairedOutputID == "1:1")
        assert(draft.cards[0].outputs[1].role == .key && draft.cards[0].outputs[1].pairedOutputID == "1:0")
        let pair = draft.profile.destinations[0]
        do { try draft.assign(fill: "1:1", key: nil, timing: .p50); assertionFailure("duplicate accepted") } catch {}
        assert(draft.profile.destinations.count == 1)
        try draft.assign(fill: "1:0", key: nil, timing: .p5994, replacing: pair.id)
        assert(draft.profile.destinations[0].id == pair.id && draft.profile.destinations[0].name == pair.name)
        assert(draft.cards[0].outputs[1].role == .unused)
        try draft.assign(fill: "1:1", key: nil, timing: .p5994)
        draft.removeAssignment(pair.id); assert(draft.cards[0].outputs[0].role == .unused)
        endpoints[1] = endpoint("1:1", card: 1, modes: [mode(2,duration:1200)])
        inventory = HardwareInventory(endpoints: endpoints)
        assert(inventory.selectableTimings(fill: "1:0", key: "1:1") == [.p50])
        assert(mode(duration:2002,scale:120000).supportedTiming == .p5994)
        assert(mode(width:3840).supportedTiming == nil)
        assert(mode(duration:1001,scale:24000).supportedTiming == .p2398)
        assert(mode(duration:0).supportedTiming == nil)
        let uhd = endpoint("uhd",card:5,modes:[mode(width:3840)])
        assert(HardwareInventory(endpoints:[uhd]).commonModes(fill:"uhd").count == 1)
        assert(HardwareInventory(endpoints:[uhd]).selectableTimings(fill:"uhd").isEmpty)
        let unknowns = HardwareInventory(endpoints:[endpoint("a",card:nil),endpoint("b",card:nil)])
        assert(unknowns.cards.count == 2 && unknowns.cards.allSatisfy { !$0.groupingKnown })
        assert(unknowns.commonModes(fill:"a",key:"b").isEmpty)
        let unavailable = HardwareInventory(endpoints:[endpoint("off",card:1,active:false), endpoint("input",card:1,playback:false)])
        assert(unavailable.cards[0].outputs.count == 2 && unavailable.commonModes(fill:"off").isEmpty)
        let unsynced = HardwareInventory(endpoints:[endpoint("a",card:1),endpoint("b",card:1,sync:false)])
        assert(unsynced.commonModes(fill:"a",key:"b").isEmpty)
        let mismatch = HardwareInventory(endpoints:[endpoint("a",card:1,modes:[mode()]),endpoint("b",card:1,modes:[mode(duration:1200)])])
        assert(mismatch.commonModes(fill:"a",key:"b").isEmpty)
        print("PASS: four-card inventory, connector grouping, pair links/common modes, direct transitions, duplicate rejection, rescan preservation, missing/inactive/unknown cards, rational timing and app-format limits")
    }
}
