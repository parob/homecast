package expo.modules.homekit

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoHomeKitModule : Module() {
    override fun definition() = ModuleDefinition {
        Name("ExpoHomeKit")

        // Events (never fired on Android, but declared for compatibility)
        Events(
            "onHomesUpdated",
            "onCharacteristicChanged",
            "onReachabilityChanged"
        )

        // Always returns false on Android - HomeKit is iOS only
        Function("isAvailable") {
            false
        }

        // Always returns unavailable on Android
        AsyncFunction("getAuthorizationStatus") {
            "unavailable"
        }

        // Always returns unavailable on Android
        AsyncFunction("requestAuthorization") {
            "unavailable"
        }

        // Returns empty array on Android
        AsyncFunction("listHomes") {
            emptyList<Map<String, Any>>()
        }

        // Returns empty array on Android
        AsyncFunction("listRooms") { _: String ->
            emptyList<Map<String, Any>>()
        }

        // Returns empty array on Android
        AsyncFunction("listAccessories") { _: String?, _: String? ->
            emptyList<Map<String, Any>>()
        }

        // Returns null on Android
        AsyncFunction("getAccessory") { _: String ->
            null
        }

        // Returns error on Android
        AsyncFunction("readCharacteristic") { _: String, _: String ->
            mapOf(
                "error" to "HomeKit is not available on Android"
            )
        }

        // Returns failure on Android
        AsyncFunction("setCharacteristic") { accessoryId: String, characteristicType: String, _: Any ->
            mapOf(
                "success" to false,
                "accessoryId" to accessoryId,
                "characteristicType" to characteristicType,
                "error" to "HomeKit is not available on Android"
            )
        }

        // Returns empty array on Android
        AsyncFunction("listScenes") { _: String ->
            emptyList<Map<String, Any>>()
        }

        // Returns failure on Android
        AsyncFunction("executeScene") { sceneId: String ->
            mapOf(
                "success" to false,
                "sceneId" to sceneId,
                "error" to "HomeKit is not available on Android"
            )
        }

        // Returns empty array on Android
        AsyncFunction("listZones") { _: String ->
            emptyList<Map<String, Any>>()
        }

        // Returns empty array on Android
        AsyncFunction("listServiceGroups") { _: String ->
            emptyList<Map<String, Any>>()
        }

        // No-op on Android
        Function("startObserving") {
            // HomeKit is not available on Android
        }

        // No-op on Android
        Function("stopObserving") {
            // HomeKit is not available on Android
        }
    }
}
