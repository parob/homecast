// HomeKit types matching the GraphQL schema and PROTOCOL.md

export interface Home {
  id: string;
  name: string;
  isPrimary: boolean;
  roomCount: number;
  accessoryCount: number;
}

export interface Room {
  id: string;
  name: string;
  accessoryCount: number;
}

export interface Zone {
  id: string;
  name: string;
  roomIds: string[];
}

export interface Characteristic {
  id: string;
  characteristicType: string;
  value: string | null; // JSON-encoded
  isReadable: boolean;
  isWritable: boolean;
  validValues?: number[];
  minValue?: number;
  maxValue?: number;
  stepValue?: number;
}

export interface Service {
  id: string;
  name: string;
  serviceType: string;
  characteristics: Characteristic[];
}

export interface Accessory {
  id: string;
  name: string;
  category: string;
  isReachable: boolean;
  homeId?: string;
  roomId?: string;
  roomName?: string;
  services: Service[];
}

export interface Scene {
  id: string;
  name: string;
  actionCount: number;
}

export interface ServiceGroup {
  id: string;
  name: string;
  serviceIds: string[];
  accessoryIds: string[];
}

// Parsed characteristic value helpers
export function parseCharacteristicValue<T>(value: string | null | undefined): T | null {
  if (value === null || value === undefined) return null;
  try {
    return JSON.parse(value) as T;
  } catch {
    return null;
  }
}

export function stringifyCharacteristicValue(value: unknown): string {
  return JSON.stringify(value);
}
