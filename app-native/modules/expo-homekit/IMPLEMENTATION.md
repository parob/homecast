# HomeKit Native Module Implementation Plan

## Overview

This document outlines the implementation plan for integrating native iOS HomeKit functionality into the Homecast React Native app using Expo Modules API.

## Architecture

```
modules/expo-homekit/
├── expo-module.config.json    # Module configuration
├── package.json               # Package metadata
├── src/
│   ├── index.ts              # TypeScript API exports
│   ├── types.ts              # Type definitions
│   └── ExpoHomeKitModule.ts  # Native module interface
├── ios/
│   ├── ExpoHomeKitModule.swift    # Main Expo module definition
│   ├── HomeKitManager.swift       # HomeKit wrapper (adapted from existing)
│   └── HomeKitModels.swift        # Data models
└── android/
    └── src/main/java/expo/modules/homekit/
        └── ExpoHomeKitModule.kt   # Android stub (returns unavailable)
```

## iOS Implementation

### 1. ExpoHomeKitModule.swift
Main module that exposes HomeKit functionality to JavaScript:

**Functions to expose:**
- `isAvailable()` → `Bool` - Check if HomeKit is available
- `getAuthorizationStatus()` → `Promise<String>` - Get current auth status
- `requestAuthorization()` → `Promise<String>` - Request HomeKit access
- `listHomes()` → `Promise<[[String: Any]]>` - List all homes
- `listRooms(homeId)` → `Promise<[[String: Any]]>` - List rooms in a home
- `listAccessories(homeId?, roomId?)` → `Promise<[[String: Any]]>` - List accessories
- `getAccessory(accessoryId)` → `Promise<[String: Any]?>` - Get single accessory
- `readCharacteristic(accessoryId, type)` → `Promise<Any>` - Read value
- `setCharacteristic(accessoryId, type, value)` → `Promise<[String: Any]>` - Set value
- `listScenes(homeId)` → `Promise<[[String: Any]]>` - List scenes
- `executeScene(sceneId)` → `Promise<[String: Any]>` - Execute scene
- `listZones(homeId)` → `Promise<[[String: Any]]>` - List zones
- `listServiceGroups(homeId)` → `Promise<[[String: Any]]>` - List service groups
- `startObserving()` → `Void` - Start change observation
- `stopObserving()` → `Void` - Stop change observation

**Events to emit:**
- `onHomesUpdated` - When home configuration changes
- `onCharacteristicChanged` - When a device value changes
- `onReachabilityChanged` - When device comes online/offline

### 2. HomeKitManager.swift
Adapted from the existing Mac app's HomeKitManager with modifications for Expo:

**Key Components:**
- `HMHomeManager` instance management
- Home/room/accessory enumeration
- Characteristic read/write operations
- Scene execution
- Delegate callbacks for real-time updates

**Mapping from existing code:**
| Existing (Mac App) | Expo Module |
|-------------------|-------------|
| `HomeKitManager.swift` | `HomeKitManager.swift` (adapted) |
| `Models.swift` | `HomeKitModels.swift` |
| Delegate pattern | Expo Events |

### 3. HomeKitModels.swift
Data models with `toDictionary()` methods for JS bridging:

```swift
struct HomeModel {
    let id: String
    let name: String
    let isPrimary: Bool
    let roomCount: Int
    let accessoryCount: Int

    func toDictionary() -> [String: Any]
}

struct AccessoryModel {
    let id: String
    let name: String
    let category: String
    let isReachable: Bool
    // ... services, characteristics

    func toDictionary() -> [String: Any]
}
```

## Android Implementation

### ExpoHomeKitModule.kt
Stub implementation that returns "unavailable" for all operations:

```kotlin
class ExpoHomeKitModule : Module() {
    override fun definition() = ModuleDefinition {
        Name("ExpoHomeKit")

        Function("isAvailable") { false }

        AsyncFunction("getAuthorizationStatus") { "unavailable" }

        // All other functions return empty arrays or throw unavailable error
    }
}
```

## Config Plugin

### plugins/homekit-entitlements.js
Expo config plugin to add required iOS entitlements:

```javascript
const { withEntitlementsPlist, withInfoPlist } = require('@expo/config-plugins');

module.exports = function withHomeKit(config) {
  // Add HomeKit entitlement
  config = withEntitlementsPlist(config, (config) => {
    config.modResults['com.apple.developer.homekit'] = true;
    return config;
  });

  // Add usage description
  config = withInfoPlist(config, (config) => {
    config.modResults.NSHomeKitUsageDescription =
      'Homecast needs access to your HomeKit devices.';
    return config;
  });

  return config;
};
```

## React Native Integration

### HomeKitProvider.tsx
Context provider that manages HomeKit state:

```typescript
interface HomeKitContextType {
  isAvailable: boolean;
  isAuthorized: boolean;
  authorizationStatus: AuthorizationStatus;
  isLocalModeEnabled: boolean;

  // Methods
  enableLocalMode: () => Promise<boolean>;
  disableLocalMode: () => void;

  // Local HomeKit operations
  localListHomes: () => Promise<HomeKitHome[]>;
  localSetCharacteristic: (...) => Promise<SetCharacteristicResult>;
  // ...
}
```

### useAccessoryControl Hook
Unified hook that chooses between local and remote:

```typescript
function useAccessoryControl() {
  const { isLocalModeEnabled, localSetCharacteristic } = useHomeKit();
  const [remoteSetCharacteristic] = useMutation(SET_CHARACTERISTIC_MUTATION);

  const setCharacteristic = async (accessoryId, type, value) => {
    if (isLocalModeEnabled) {
      return localSetCharacteristic(accessoryId, type, value);
    }
    return remoteSetCharacteristic({ variables: { accessoryId, type, value } });
  };

  return { setCharacteristic };
}
```

## Implementation Steps

### Step 1: iOS Native Module (Current)
1. ✅ Create module structure and TypeScript API
2. Create `ExpoHomeKitModule.swift` with Expo Modules API
3. Create `HomeKitManager.swift` (adapt from Mac app)
4. Create `HomeKitModels.swift` with serialization
5. Test basic functionality

### Step 2: Android Stub
1. Create `ExpoHomeKitModule.kt` stub
2. Return unavailable for all operations

### Step 3: Config Plugin
1. Create `plugins/homekit-entitlements.js`
2. Register in `app.json`

### Step 4: React Native Integration
1. Create `HomeKitProvider.tsx`
2. Update `useAccessoryControl` hook
3. Add Local Mode toggle in Settings
4. Update AccessoryCard to use unified control

### Step 5: Testing
1. Build iOS dev client: `npx expo prebuild && npx expo run:ios`
2. Test authorization flow
3. Test device listing
4. Test characteristic control
5. Test real-time updates

## Characteristic Type Mapping

| HomeKit Type | Protocol Type |
|--------------|---------------|
| `HMCharacteristicTypePowerState` | `power-state` |
| `HMCharacteristicTypeBrightness` | `brightness` |
| `HMCharacteristicTypeHue` | `hue` |
| `HMCharacteristicTypeSaturation` | `saturation` |
| `HMCharacteristicTypeColorTemperature` | `color-temperature` |
| `HMCharacteristicTypeCurrentTemperature` | `current-temperature` |
| `HMCharacteristicTypeTargetTemperature` | `target-temperature` |
| `HMCharacteristicTypeLockCurrentState` | `lock-current-state` |
| `HMCharacteristicTypeLockTargetState` | `lock-target-state` |
| `HMCharacteristicTypeMotionDetected` | `motion-detected` |

## Error Handling

All native methods should handle errors gracefully:

1. **Authorization denied** → Return appropriate status, don't throw
2. **Accessory not found** → Return null or empty result
3. **Accessory unreachable** → Include in response, let JS handle
4. **Network/HomeKit errors** → Catch and return error result

## Build Requirements

- **iOS Deployment Target**: 15.0+
- **Xcode**: 15.0+
- **HomeKit Entitlement**: Required in provisioning profile
- **EAS Build**: Required (no Expo Go support for native modules)

## Testing Checklist

- [ ] Module loads without crash
- [ ] `isAvailable()` returns true on iOS, false on Android
- [ ] Authorization request shows system dialog
- [ ] Homes list returns configured homes
- [ ] Accessories list shows devices with correct data
- [ ] Set characteristic changes device state
- [ ] Real-time updates fire when device changes externally
- [ ] Android gracefully shows "unavailable" state
