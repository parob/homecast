import { NativeModule, requireNativeModule } from 'expo-modules-core';
import type {
  HomeKitHome,
  HomeKitRoom,
  HomeKitAccessory,
  HomeKitScene,
  HomeKitZone,
  HomeKitServiceGroup,
  SetCharacteristicResult,
  ExecuteSceneResult,
  AuthorizationStatus,
  CharacteristicChangeEvent,
  ReachabilityChangeEvent,
  HomesUpdatedEvent,
} from './types';

// Define the events the module can emit
interface ExpoHomeKitModuleEvents {
  onHomesUpdated: (event: HomesUpdatedEvent) => void;
  onCharacteristicChanged: (event: CharacteristicChangeEvent) => void;
  onReachabilityChanged: (event: ReachabilityChangeEvent) => void;
  // Index signature required by expo-modules-core EventsMap
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  [key: string]: (event: any) => void;
}

// Define the module interface
declare class ExpoHomeKitModuleType extends NativeModule<ExpoHomeKitModuleEvents> {
  // Availability and authorization
  isAvailable(): boolean;
  getAuthorizationStatus(): Promise<AuthorizationStatus>;
  requestAuthorization(): Promise<AuthorizationStatus>;

  // Homes
  listHomes(): Promise<HomeKitHome[]>;

  // Rooms
  listRooms(homeId: string): Promise<HomeKitRoom[]>;

  // Accessories
  listAccessories(homeId?: string, roomId?: string): Promise<HomeKitAccessory[]>;
  getAccessory(accessoryId: string): Promise<HomeKitAccessory | null>;

  // Characteristics
  readCharacteristic(accessoryId: string, characteristicType: string): Promise<unknown>;
  setCharacteristic(
    accessoryId: string,
    characteristicType: string,
    value: unknown
  ): Promise<SetCharacteristicResult>;

  // Scenes
  listScenes(homeId: string): Promise<HomeKitScene[]>;
  executeScene(sceneId: string): Promise<ExecuteSceneResult>;

  // Zones and Service Groups
  listZones(homeId: string): Promise<HomeKitZone[]>;
  listServiceGroups(homeId: string): Promise<HomeKitServiceGroup[]>;

  // Observation
  startObserving(): void;
  stopObserving(): void;
}

// Export the native module
export default requireNativeModule<ExpoHomeKitModuleType>('ExpoHomeKit');
