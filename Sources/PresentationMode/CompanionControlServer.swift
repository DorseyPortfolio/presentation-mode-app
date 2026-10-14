import Foundation
import Network

struct CompanionStatus: Encodable {
    let deviceID: String
    let deviceName: String
    let mode: String
    var lastError: String = ""
    var routing: String = "largo-opaque-desktop"
    let proPresenterRunning: Bool
    let automaticProPresenterSwitchingEnabled: Bool
    let ndiRunning: Bool
    let ndiSource: String
}

final class CompanionControlServer: @unchecked Sendable {
    typealias StatusProvider = @MainActor () -> CompanionStatus
    typealias CommandHandler = @MainActor (String) async -> Void

    private let queue = DispatchQueue(label: "PresentationMode.CompanionAPI")
    private var listener: NWListener?
    private let statusProvider: StatusProvider
    private let commandHandler: CommandHandler

    init(statusProvider: @escaping StatusProvider, commandHandler: @escaping CommandHandler) {
        self.statusProvider = statusProvider
        self.commandHandler = commandHandler
    }

    func start(port: UInt16 = 9876) throws {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        // Production restores the existing 0.4.3 LAN service; validation stays local.
        let parameters = NWParameters.tcp
        if BuildPolicy.companionLoopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        if BuildPolicy.advertiseCompanion {
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "Presentation Mode",
                type: "_presentation-mode._tcp",
                txtRecord: NWTXTRecord(["id": Self.deviceID, "api": "1"])
            )
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { fputs("Companion API failed: \(error)\n", stderr) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    static let deviceID: String = {
        let key = "PresentationMode.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let line = request.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let method = parts.count > 0 ? String(parts[0]) : ""
            let path = parts.count > 1 ? String(parts[1]) : ""
            Task { @MainActor in
                if method == "GET", path == "/status" {
                    let status = self.statusProvider()
                    let body = (try? JSONEncoder().encode(status)) ?? Data("{}".utf8)
                    self.respond(connection, status: "200 OK", body: body)
                } else if method == "POST", ["/mode/canva", "/mode/production", "/mode/auto", "/auto/enable", "/auto/disable", "/auto/toggle"].contains(path) {
                    let command = path.hasPrefix("/auto/") ? path.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "auto", with: "auto-") : String(path.split(separator: "/").last ?? "auto")
                    await self.commandHandler(command)
                    let body = (try? JSONEncoder().encode(self.statusProvider())) ?? Data("{}".utf8)
                    self.respond(connection, status: "200 OK", body: body)
                } else {
                    self.respond(connection, status: "404 Not Found", body: Data("{\"error\":\"not found\"}".utf8))
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
