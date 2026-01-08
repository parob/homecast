import Foundation
import Network
import HomeKit

/// A simple HTTP server using NWListener for health checks and API access
@MainActor
class SimpleHTTPServer: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16 = 5656

    private var listener: NWListener?
    private weak var homeKitManager: HomeKitManager?

    init(homeKitManager: HomeKitManager, port: UInt16 = 5656) {
        self.homeKitManager = homeKitManager
        self.port = port
    }

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        print("[HTTPServer] Server listening on port \(self?.port ?? 0)")
                    case .failed(let error):
                        self?.isRunning = false
                        print("[HTTPServer] Server failed: \(error)")
                    case .cancelled:
                        self?.isRunning = false
                        print("[HTTPServer] Server cancelled")
                    case .setup:
                        print("[HTTPServer] Server setup...")
                    case .waiting(let error):
                        print("[HTTPServer] Server waiting: \(error)")
                    @unknown default:
                        print("[HTTPServer] Server unknown state")
                    }
                }
            }

            print("[HTTPServer] Starting listener...")

            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            listener?.start(queue: .main)

        } catch {
            print("[HTTPServer] Failed to create listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    self?.handleRequest(data: data, connection: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func handleRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid request")
            return
        }

        // Parse HTTP request line
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid request")
            return
        }

        let method = parts[0]
        let path = parts[1].components(separatedBy: "?").first ?? parts[1]

        print("[HTTPServer] \(method) \(path)")

        // Route the request
        Task { @MainActor in
            switch (method, path) {
            case ("GET", "/health"):
                self.handleHealth(connection: connection)

            case ("GET", "/homes"):
                self.handleListHomes(connection: connection)

            case ("GET", "/accessories"):
                self.handleListAccessories(connection: connection)

            case ("GET", "/"):
                self.handleRoot(connection: connection)

            default:
                self.sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\": \"Not found\"}")
            }
        }
    }

    // MARK: - Route Handlers

    private func handleHealth(connection: NWConnection) {
        guard let manager = homeKitManager else {
            sendResponse(connection: connection, status: "503 Service Unavailable", body: "{\"error\": \"HomeKit not available\"}")
            return
        }

        var homesData: [[String: Any]] = []

        for home in manager.homes {
            var roomsData: [[String: Any]] = []
            for room in home.rooms {
                let roomAccessories = home.accessories.filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
                roomsData.append([
                    "id": room.uniqueIdentifier.uuidString,
                    "name": room.name,
                    "accessoryCount": roomAccessories.count
                ])
            }

            var accessoriesData: [[String: Any]] = []
            for accessory in home.accessories {
                var servicesData: [[String: Any]] = []
                for service in accessory.services {
                    var characteristicsData: [[String: Any]] = []
                    for characteristic in service.characteristics {
                        characteristicsData.append([
                            "type": CharacteristicMapper.fromHomeKitType(characteristic.characteristicType),
                            "value": characteristic.value.map { "\($0)" } ?? "null",
                            "isReadable": characteristic.properties.contains(HMCharacteristicPropertyReadable),
                            "isWritable": characteristic.properties.contains(HMCharacteristicPropertyWritable)
                        ])
                    }
                    servicesData.append([
                        "name": service.name,
                        "type": CharacteristicMapper.fromHomeKitServiceType(service.serviceType),
                        "characteristics": characteristicsData
                    ])
                }

                accessoriesData.append([
                    "id": accessory.uniqueIdentifier.uuidString,
                    "name": accessory.name,
                    "room": accessory.room?.name ?? "Unassigned",
                    "category": accessory.category.localizedDescription,
                    "isReachable": accessory.isReachable,
                    "services": servicesData
                ])
            }

            var scenesData: [[String: Any]] = []
            for scene in home.actionSets {
                scenesData.append([
                    "id": scene.uniqueIdentifier.uuidString,
                    "name": scene.name,
                    "actionCount": scene.actions.count
                ])
            }

            homesData.append([
                "id": home.uniqueIdentifier.uuidString,
                "name": home.name,
                "isPrimary": home.isPrimary,
                "rooms": roomsData,
                "accessories": accessoriesData,
                "scenes": scenesData
            ])
        }

        let response: [String: Any] = [
            "status": "ok",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "homekit": [
                "ready": manager.isReady,
                "homeCount": manager.homes.count,
                "accessoryCount": manager.homes.reduce(0) { $0 + $1.accessories.count },
                "homes": homesData
            ]
        ]

        sendJSONResponse(connection: connection, data: response)
    }

    private func handleRoot(connection: NWConnection) {
        let response: [String: Any] = [
            "name": "Homecast",
            "version": "1.0.0",
            "endpoints": [
                "/health": "Health check",
                "/homes": "List all homes",
                "/accessories": "List all accessories"
            ]
        ]

        sendJSONResponse(connection: connection, data: response)
    }

    private func handleListHomes(connection: NWConnection) {
        guard let manager = homeKitManager else {
            sendResponse(connection: connection, status: "503 Service Unavailable", body: "{\"error\": \"HomeKit not available\"}")
            return
        }

        let homes = manager.listHomes()

        do {
            let jsonData = try JSONEncoder().encode(homes)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: jsonString)
            }
        } catch {
            sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\": \"\(error.localizedDescription)\"}")
        }
    }

    private func handleListAccessories(connection: NWConnection) {
        guard let manager = homeKitManager else {
            sendResponse(connection: connection, status: "503 Service Unavailable", body: "{\"error\": \"HomeKit not available\"}")
            return
        }

        do {
            let accessories = try manager.listAccessories()
            let jsonArray = JSONValue.array(accessories.map { $0.toJSON() })
            let jsonData = try JSONEncoder().encode(jsonArray)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: jsonString)
            }
        } catch {
            sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\": \"\(error.localizedDescription)\"}")
        }
    }

    // MARK: - Response Helpers

    private func sendJSONResponse(connection: NWConnection, data: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: jsonString)
            }
        } catch {
            sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\": \"JSON encoding failed\"}")
        }
    }

    private func sendResponse(connection: NWConnection, status: String, contentType: String = "application/json", body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
