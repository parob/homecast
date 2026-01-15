// HomeKit types for the native module

export interface HomeKitHome {
  id: string;
  name: string;
  isPrimary: boolean;
  roomCount: number;
  accessoryCount: number;
}

export interface HomeKitRoom {
  id: string;
  name: string;
  accessoryCount: number;
}

export interface HomeKitCharacteristic {
  id: string;
  characteristicType: string;
  value: unknown;
  isReadable: boolean;
  isWritable: boolean;
  validValues?: number[];
  minValue?: number;
  maxValue?: number;
  stepValue?: number;
}

export interface HomeKitService {
  id: string;
  name: string;
  serviceType: string;
  characteristics: HomeKitCharacteristic[];
}

export interface HomeKitAccessory {
  id: string;
  name: string;
  category: string;
  isReachable: boolean;
  homeId?: string;
  roomId?: string;
  roomName?: string;
  services: HomeKitService[];
}

export interface HomeKitScene {
  id: string;
  name: string;
  actionCount: number;
}

export interface HomeKitZone {
  id: string;
  name: string;
  roomIds: string[];
}

export interface HomeKitServiceGroup {
  id: string;
  name: string;
  serviceIds: string[];
  accessoryIds: string[];
}

export interface SetCharacteristicResult {
  success: boolean;
  accessoryId: string;
  characteristicType: string;
  value?: unknown;
}

export interface ExecuteSceneResult {
  success: boolean;
  sceneId: string;
}

export type AuthorizationStatus =
  | 'authorized'
  | 'denied'
  | 'notDetermined'
  | 'restricted'
  | 'unavailable';

export interface CharacteristicChangeEvent {
  accessoryId: string;
  characteristicType: string;
  value: unknown;
}

export interface ReachabilityChangeEvent {
  accessoryId: string;
  isReachable: boolean;
}

export interface HomesUpdatedEvent {
  homes: HomeKitHome[];
}

// Re-export for backwards compatibility with the simpler event type
export interface HomesUpdatedEventSimple {
  homes: Array<{ id: string; name: string }>;
}
