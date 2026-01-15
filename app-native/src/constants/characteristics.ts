// Characteristic type mappings from PROTOCOL.md

export const CharacteristicTypes = {
  POWER_STATE: 'power-state',
  BRIGHTNESS: 'brightness',
  HUE: 'hue',
  SATURATION: 'saturation',
  COLOR_TEMPERATURE: 'color-temperature',
  CURRENT_TEMPERATURE: 'current-temperature',
  TARGET_TEMPERATURE: 'target-temperature',
  CURRENT_HEATING_COOLING: 'current-heating-cooling',
  TARGET_HEATING_COOLING: 'target-heating-cooling',
  LOCK_CURRENT_STATE: 'lock-current-state',
  LOCK_TARGET_STATE: 'lock-target-state',
  MOTION_DETECTED: 'motion-detected',
  CONTACT_STATE: 'contact-state',
  CURRENT_POSITION: 'current-position',
  TARGET_POSITION: 'target-position',
  ACTIVE: 'active',
} as const;

export type CharacteristicType = typeof CharacteristicTypes[keyof typeof CharacteristicTypes];

// HVAC modes
export const HVACModes = {
  OFF: 0,
  HEAT: 1,
  COOL: 2,
  AUTO: 3,
} as const;

// Lock states
export const LockStates = {
  UNSECURED: 0,
  SECURED: 1,
  JAMMED: 2,
  UNKNOWN: 3,
} as const;

// Contact sensor states
export const ContactStates = {
  DETECTED: 0,
  NOT_DETECTED: 1,
} as const;

// Category icons mapping
export const CategoryIcons: Record<string, string> = {
  Lightbulb: 'lightbulb-outline',
  Switch: 'power',
  Outlet: 'power-plug',
  Thermostat: 'thermometer',
  Lock: 'lock-outline',
  Sensor: 'motion-sensor',
  Door: 'door',
  Window: 'window-open',
  Fan: 'fan',
  GarageDoorOpener: 'garage',
  SecuritySystem: 'shield-home',
  Camera: 'camera',
  AirConditioner: 'air-conditioner',
  Humidifier: 'air-humidifier',
  Dehumidifier: 'water-off',
  WindowCovering: 'blinds',
  Other: 'devices',
};
