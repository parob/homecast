import type { Accessory, Characteristic } from '@/types/homekit';

// Service types
export type ServiceType =
  | 'lightbulb'
  | 'switch'
  | 'outlet'
  | 'thermostat'
  | 'heater_cooler'
  | 'lock'
  | 'fan'
  | 'window_covering'
  | 'garage_door'
  | 'door'
  | 'window'
  | 'motion_sensor'
  | 'contact_sensor'
  | 'temperature_sensor'
  | 'humidity_sensor'
  | 'speaker'
  | 'security_system'
  | 'valve'
  | 'irrigation_system'
  | 'camera'
  | 'doorbell';

export interface CharacteristicData {
  type: string;
  value: any;
  isWritable: boolean;
  minValue?: number;
  maxValue?: number;
  stepValue?: number;
  validValues?: number[];
}

export interface WidgetProps {
  accessory: Accessory;
  displayName: string;  // Accessory name with room prefix stripped
  onToggle: (accessoryId: string, characteristicType: string, currentValue: boolean) => void;
  onSlider: (accessoryId: string, characteristicType: string, value: number) => void;
  getEffectiveValue: (accessoryId: string, characteristicType: string, serverValue: any) => any;
  onCardPress?: () => void;  // Opens the control modal
}

// Parse characteristic value from JSON string
export const parseCharacteristicValue = (value: any): any => {
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string') return value;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
};

// Get a characteristic from an accessory by type (case-insensitive with common variations)
export const getCharacteristic = (accessory: Accessory, type: string): CharacteristicData | null => {
  const normalizedType = type.toLowerCase().replace(/-/g, '_');

  for (const service of accessory.services || []) {
    for (const char of service.characteristics || []) {
      const charType = char.characteristicType.toLowerCase().replace(/-/g, '_');
      if (charType === normalizedType) {
        return {
          type: char.characteristicType,
          value: parseCharacteristicValue(char.value),
          isWritable: char.isWritable ?? false,
          minValue: char.minValue ?? undefined,
          maxValue: char.maxValue ?? undefined,
          stepValue: char.stepValue ?? undefined,
          validValues: char.validValues ?? undefined,
        };
      }
    }
  }
  return null;
};

// Check if accessory has a specific service type
export const hasServiceType = (accessory: Accessory, type: string): boolean => {
  for (const service of accessory.services || []) {
    const normalized = normalizeServiceType(service.serviceType);
    if (normalized === type || service.serviceType.toLowerCase() === type.toLowerCase()) {
      return true;
    }
  }
  return false;
};

// Normalize service type name
export const normalizeServiceType = (serviceType: string): ServiceType | null => {
  const lower = serviceType.toLowerCase().replace(/-/g, '_');

  const mapping: Record<string, ServiceType> = {
    'lightbulb': 'lightbulb',
    'switch': 'switch',
    'outlet': 'outlet',
    'thermostat': 'thermostat',
    'heater_cooler': 'heater_cooler',
    'lock': 'lock',
    'lock_mechanism': 'lock',
    'fan': 'fan',
    'fan_v2': 'fan',
    'window_covering': 'window_covering',
    'garage_door': 'garage_door',
    'garage_door_opener': 'garage_door',
    'door': 'door',
    'window': 'window',
    'motion_sensor': 'motion_sensor',
    'contact_sensor': 'contact_sensor',
    'temperature_sensor': 'temperature_sensor',
    'humidity_sensor': 'humidity_sensor',
    'speaker': 'speaker',
    'security_system': 'security_system',
    'valve': 'valve',
    'irrigation_system': 'irrigation_system',
    'camera': 'camera',
    'doorbell': 'doorbell',
  };

  return mapping[lower] || null;
};

// Get primary service type from accessory
export const getPrimaryServiceType = (accessory: Accessory): ServiceType | null => {
  const skipTypes = ['accessory_information', 'battery', 'protocol_information'];

  const priority: Record<string, number> = {
    'security_system': 100,
    'thermostat': 95,
    'heater_cooler': 95,
    'lock': 90,
    'garage_door': 90,
    'doorbell': 85,
    'camera': 85,
    'lightbulb': 50,
    'fan': 50,
    'window_covering': 50,
    'outlet': 40,
    'switch': 20,
    'motion_sensor': 35,
    'contact_sensor': 35,
    'temperature_sensor': 30,
    'humidity_sensor': 30,
  };

  let bestService: ServiceType | null = null;
  let bestPriority = -1;

  for (const service of accessory.services || []) {
    const lower = service.serviceType.toLowerCase();
    if (skipTypes.includes(lower)) continue;

    const normalized = normalizeServiceType(service.serviceType);
    if (normalized) {
      const p = priority[normalized] ?? 10;
      if (p > bestPriority) {
        bestPriority = p;
        bestService = normalized;
      }
    }
  }

  return bestService;
};

// Convert HSV to hex color string
export function hsvToHex(h: number, s: number, v: number): string {
  const c = v * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = v - c;
  let r = 0, g = 0, b = 0;

  if (h < 60) { r = c; g = x; b = 0; }
  else if (h < 120) { r = x; g = c; b = 0; }
  else if (h < 180) { r = 0; g = c; b = x; }
  else if (h < 240) { r = 0; g = x; b = c; }
  else if (h < 300) { r = x; g = 0; b = c; }
  else { r = c; g = 0; b = x; }

  const toHex = (n: number) => Math.round((n + m) * 255).toString(16).padStart(2, '0');
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

// Strip room name prefix from accessory name
export function getDisplayName(accessory: Accessory): string {
  const { name, roomName } = accessory;
  if (!roomName || !name) return name;

  // Check if name starts with room name (case insensitive)
  if (name.toLowerCase().startsWith(roomName.toLowerCase())) {
    const stripped = name.slice(roomName.length).trim();
    // Return stripped name if it's not empty, otherwise return original
    return stripped || name;
  }
  return name;
}

// Category to service type mapping
export const categoryToServiceType = (category: string): ServiceType | null => {
  const lower = category.toLowerCase();
  const mapping: Record<string, ServiceType> = {
    'lightbulb': 'lightbulb',
    'light': 'lightbulb',
    'switch': 'switch',
    'outlet': 'outlet',
    'thermostat': 'thermostat',
    'heater': 'heater_cooler',
    'cooler': 'heater_cooler',
    'lock': 'lock',
    'fan': 'fan',
    'window covering': 'window_covering',
    'windowcovering': 'window_covering',
    'garage door opener': 'garage_door',
    'garagedooropener': 'garage_door',
    'door': 'door',
    'window': 'window',
    'sensor': 'motion_sensor',
    'speaker': 'speaker',
    'security system': 'security_system',
    'valve': 'valve',
    'camera': 'camera',
    'doorbell': 'doorbell',
  };
  return mapping[lower] || null;
};
