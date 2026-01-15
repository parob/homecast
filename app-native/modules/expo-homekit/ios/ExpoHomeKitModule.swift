import ExpoModulesCore
import HomeKit

public class ExpoHomeKitModule: Module {
    private lazy var homeKitManager = HomeKitManager()
    private var isObserving = false

    public func definition() -> ModuleDefinition {
        Name("ExpoHomeKit")

        // Events
        Events(
            "onHomesUpdated",
            "onCharacteristicChanged",
            "onReachabilityChanged"
        )

        // Check if HomeKit is available
        Function("isAvailable") { () -> Bool in
            return true
        }

        // Get authorization status
        AsyncFunction("getAuthorizationStatus") { () -> String in
            let status = HMHomeManager().authorizationStatus
            return self.authStatusToString(status)
        }

        // Request authorization
        AsyncFunction("requestAuthorization") { (promise: Promise) in
            self.homeKitManager.requestAuthorization { status in
                promise.resolve(self.authStatusToString(status))
            }
        }

        // List all homes
        AsyncFunction("listHomes") { () -> [[String: Any]] in
            return self.homeKitManager.listHomes().map { $0.toDictionary() }
        }

        // List rooms in a home
        AsyncFunction("listRooms") { (homeId: String) -> [[String: Any]] in
            return self.homeKitManager.listRooms(homeId: homeId).map { $0.toDictionary() }
        }

        // List accessories
        AsyncFunction("listAccessories") { (homeId: String?, roomId: String?) -> [[String: Any]] in
            return self.homeKitManager.listAccessories(homeId: homeId, roomId: roomId).map { $0.toDictionary() }
        }

        // Get single accessory
        AsyncFunction("getAccessory") { (accessoryId: String) -> [String: Any]? in
            return self.homeKitManager.getAccessory(accessoryId: accessoryId)?.toDictionary()
        }

        // Read characteristic value
        AsyncFunction("readCharacteristic") { (accessoryId: String, characteristicType: String, promise: Promise) in
            self.homeKitManager.readCharacteristic(accessoryId: accessoryId, characteristicType: characteristicType) { result in
                switch result {
                case .success(let value):
                    promise.resolve(value)
                case .failure(let error):
                    promise.reject(error)
                }
            }
        }

        // Set characteristic value
        // Note: value is passed as Double to handle both Int and Float values from JS
        // Booleans are passed as 0/1
        AsyncFunction("setCharacteristic") { (accessoryId: String, characteristicType: String, value: Double, promise: Promise) in
            self.homeKitManager.setCharacteristic(accessoryId: accessoryId, characteristicType: characteristicType, value: value) { result in
                switch result {
                case .success(let response):
                    promise.resolve(response)
                case .failure(let error):
                    promise.reject(error)
                }
            }
        }

        // List scenes
        AsyncFunction("listScenes") { (homeId: String) -> [[String: Any]] in
            return self.homeKitManager.listScenes(homeId: homeId).map { $0.toDictionary() }
        }

        // Execute scene
        AsyncFunction("executeScene") { (sceneId: String, promise: Promise) in
            self.homeKitManager.executeScene(sceneId: sceneId) { result in
                switch result {
                case .success(let response):
                    promise.resolve(response)
                case .failure(let error):
                    promise.reject(error)
                }
            }
        }

        // List zones
        AsyncFunction("listZones") { (homeId: String) -> [[String: Any]] in
            return self.homeKitManager.listZones(homeId: homeId).map { $0.toDictionary() }
        }

        // List service groups
        AsyncFunction("listServiceGroups") { (homeId: String) -> [[String: Any]] in
            return self.homeKitManager.listServiceGroups(homeId: homeId).map { $0.toDictionary() }
        }

        // Start observing changes
        Function("startObserving") {
            guard !self.isObserving else { return }
            self.isObserving = true
            self.homeKitManager.delegate = self
            self.homeKitManager.startObserving()
        }

        // Stop observing changes
        Function("stopObserving") {
            guard self.isObserving else { return }
            self.isObserving = false
            self.homeKitManager.delegate = nil
            self.homeKitManager.stopObserving()
        }
    }

    private func authStatusToString(_ status: HMHomeManagerAuthorizationStatus) -> String {
        if status.contains(.authorized) {
            return "authorized"
        } else if status.contains(.restricted) {
            return "restricted"
        } else if status.contains(.determined) {
            return "denied"
        } else {
            return "notDetermined"
        }
    }
}

// MARK: - HomeKitManagerDelegate
extension ExpoHomeKitModule: HomeKitManagerDelegate {
    func homesDidUpdate(_ homes: [HomeModel]) {
        sendEvent("onHomesUpdated", [
            "homes": homes.map { $0.toDictionary() }
        ])
    }

    func characteristicDidChange(accessoryId: String, characteristicType: String, value: Any) {
        sendEvent("onCharacteristicChanged", [
            "accessoryId": accessoryId,
            "characteristicType": characteristicType,
            "value": value
        ])
    }

    func reachabilityDidChange(accessoryId: String, isReachable: Bool) {
        sendEvent("onReachabilityChanged", [
            "accessoryId": accessoryId,
            "isReachable": isReachable
        ])
    }
}
