import Foundation

enum PlayoutMode: String, Codable {
    case production
    case canva
}

struct RoomConfiguration: Codable, Equatable {
    var sourceDisplayID: UInt32?
    var enabledOutputIDs: Set<String> = []
    var videoStandard = "1080p59.94"
    var restoreCanvaModeAtLogin = false
    // Optional preserves decoding of roomConfiguration.v1 data written by
    // earlier builds. A missing value defaults to enabled on upgrade.
    var ndiEnabled: Bool?
    var ndiSourceName: String?
}

protocol ConfigurationStoring {
    func load() -> RoomConfiguration
    func save(_ configuration: RoomConfiguration)
}

struct DefaultsConfigurationStore: ConfigurationStoring {
    private let key = "roomConfiguration.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RoomConfiguration {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(RoomConfiguration.self, from: data) else {
            return RoomConfiguration()
        }
        return value
    }

    func save(_ configuration: RoomConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}
