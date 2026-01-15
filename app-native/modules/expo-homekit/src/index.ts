import { Platform } from 'react-native';
import ExpoHomeKitModule from './ExpoHomeKitModule';
import type { HomeKitHome } from './types';

// Re-export types
export * from './types';

// Check if HomeKit is available (iOS only)
export function isAvailable(): boolean {
  if (Platform.OS !== 'ios') {
    return false;
  }
  try {
    return ExpoHomeKitModule.isAvailable();
  } catch {
    return false;
  }
}

// Get authorization status
export async function getAuthorizationStatus() {
  if (!isAvailable()) {
    return 'unavailable' as const;
  }
  return ExpoHomeKitModule.getAuthorizationStatus();
}

// Request authorization
export async function requestAuthorization() {
  if (!isAvailable()) {
    return 'unavailable' as const;
  }
  return ExpoHomeKitModule.requestAuthorization();
}

// List all homes
export async function listHomes() {
  if (!isAvailable()) {
    return [];
  }
  return ExpoHomeKitModule.listHomes();
}

// List rooms in a home
export async function listRooms(homeId: string) {
  if (!isAvailable()) {
    return [];
  }
  return ExpoHomeKitModule.listRooms(homeId);
}

// List accessories
export async function listAccessories(homeId?: string, roomId?: string) {
  if (!isAvailable()) {
    return [];
  }
  return ExpoHomeKitModule.listAccessories(homeId, roomId);
}

// Get single accessory
export async function getAccessory(accessoryId: string) {
  if (!isAvailable()) {
    return null;
  }
  return ExpoHomeKitModule.getAccessory(accessoryId);
}

// Read characteristic
export async function readCharacteristic(accessoryId: string, characteristicType: string) {
  if (!isAvailable()) {
    throw new Error('HomeKit is not available');
  }
  return ExpoHomeKitModule.readCharacteristic(accessoryId, characteristicType);
}

// Set characteristic
export async function setCharacteristic(
  accessoryId: string,
  characteristicType: string,
  value: unknown
) {
  if (!isAvailable()) {
    return { success: false, accessoryId, characteristicType };
  }
  return ExpoHomeKitModule.setCharacteristic(accessoryId, characteristicType, value);
}

// List scenes
export async function listScenes(homeId: string) {
  if (!isAvailable()) {
    return [];
  }
  return ExpoHomeKitModule.listScenes(homeId);
}

// Execute scene
export async function executeScene(sceneId: string) {
  if (!isAvailable()) {
    return { success: false, sceneId };
  }
  return ExpoHomeKitModule.executeScene(sceneId);
}

// List zones
export async function listZones(homeId: string) {
  if (!isAvailable()) {
    return [];
  }
  return ExpoHomeKitModule.listZones(homeId);
}

// List service groups
export async function listServiceGroups(homeId: string) {
  if (!isAvailable()) {
    return [];
  }
  return ExpoHomeKitModule.listServiceGroups(homeId);
}

// Start observing HomeKit changes
export function startObserving() {
  if (!isAvailable()) {
    return;
  }
  ExpoHomeKitModule.startObserving();
}

// Stop observing HomeKit changes
export function stopObserving() {
  if (!isAvailable()) {
    return;
  }
  ExpoHomeKitModule.stopObserving();
}

// Event listeners
export function addCharacteristicChangeListener(
  callback: (event: { accessoryId: string; characteristicType: string; value: unknown }) => void
) {
  if (!isAvailable()) {
    return { remove: () => {} };
  }
  return ExpoHomeKitModule.addListener('onCharacteristicChanged', callback);
}

export function addReachabilityChangeListener(
  callback: (event: { accessoryId: string; isReachable: boolean }) => void
) {
  if (!isAvailable()) {
    return { remove: () => {} };
  }
  return ExpoHomeKitModule.addListener('onReachabilityChanged', callback);
}

export function addHomesUpdatedListener(
  callback: (event: { homes: HomeKitHome[] }) => void
) {
  if (!isAvailable()) {
    return { remove: () => {} };
  }
  return ExpoHomeKitModule.addListener('onHomesUpdated', callback);
}
