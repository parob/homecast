import React from 'react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { WidgetCard, getIconColor } from './WidgetCard';
import { useAccessoryStore } from '@/stores/accessoryStore';
import type { Accessory } from '@/types/homekit';
import type { ServiceType } from './types';
import { getCharacteristic, getPrimaryServiceType, hsvToHex } from './types';

interface ServiceGroupWidgetProps {
  groupId: string;
  groupName: string;
  accessories: Accessory[];
  onToggle: (groupId: string, characteristicType: string, currentValue: boolean) => void;
  onCardPress?: () => void;
}

// Determine the primary type of the group based on its accessories
function getGroupServiceType(accessories: Accessory[]): ServiceType | null {
  const typeCounts: Record<string, number> = {};

  for (const acc of accessories) {
    const type = getPrimaryServiceType(acc);
    if (type) {
      typeCounts[type] = (typeCounts[type] || 0) + 1;
    }
  }

  // Return the most common type
  let maxCount = 0;
  let primaryType: ServiceType | null = null;
  for (const [type, count] of Object.entries(typeCounts)) {
    if (count > maxCount) {
      maxCount = count;
      primaryType = type as ServiceType;
    }
  }

  return primaryType;
}

// Get aggregate on/off state for the group (using store values)
type GetEffectiveValueFn = (accessoryId: string, charType: string, serverValue: unknown) => unknown;

function getGroupStateWithStore(
  accessories: Accessory[],
  getEffectiveValue: GetEffectiveValueFn
): { onCount: number; totalCount: number; isOn: boolean } {
  let onCount = 0;
  const totalCount = accessories.length;

  for (const acc of accessories) {
    const powerChar = getCharacteristic(acc, 'power_state') ||
                      getCharacteristic(acc, 'on') ||
                      getCharacteristic(acc, 'active');
    if (powerChar) {
      const value = getEffectiveValue(acc.id, powerChar.type, powerChar.value);
      if (value === true || value === 1) {
        onCount++;
      }
    }
  }

  return {
    onCount,
    totalCount,
    isOn: onCount > 0,
  };
}

// Get aggregate brightness for light groups (using store values)
function getGroupBrightnessWithStore(
  accessories: Accessory[],
  getEffectiveValue: GetEffectiveValueFn
): number | null {
  const brightnesses: number[] = [];

  for (const acc of accessories) {
    const brightnessChar = getCharacteristic(acc, 'brightness');
    const powerChar = getCharacteristic(acc, 'power_state') || getCharacteristic(acc, 'on');

    const powerValue = powerChar ? getEffectiveValue(acc.id, powerChar.type, powerChar.value) : null;
    const isOn = powerValue === true || powerValue === 1;

    if (isOn && brightnessChar) {
      const brightness = getEffectiveValue(acc.id, 'brightness', brightnessChar.value);
      if (brightness !== null && brightness !== undefined) {
        brightnesses.push(Number(brightness));
      }
    }
  }

  if (brightnesses.length === 0) return null;

  // Return average brightness
  return Math.round(brightnesses.reduce((a, b) => a + b, 0) / brightnesses.length);
}

// Get aggregate hue/saturation for light groups (using store values)
function getGroupHueSaturationWithStore(
  accessories: Accessory[],
  getEffectiveValue: GetEffectiveValueFn
): { hue: number | null; saturation: number | null } {
  // Get from first on light that has hue/saturation
  for (const acc of accessories) {
    const powerChar = getCharacteristic(acc, 'power_state') || getCharacteristic(acc, 'on');
    const hueChar = getCharacteristic(acc, 'hue');
    const satChar = getCharacteristic(acc, 'saturation');

    const powerValue = powerChar ? getEffectiveValue(acc.id, powerChar.type, powerChar.value) : null;
    const isOn = powerValue === true || powerValue === 1;

    if (isOn && hueChar && satChar) {
      const hue = getEffectiveValue(acc.id, 'hue', hueChar.value);
      const saturation = getEffectiveValue(acc.id, 'saturation', satChar.value);
      if (hue !== null && hue !== undefined && saturation !== null && saturation !== undefined) {
        return { hue: Number(hue), saturation: Number(saturation) };
      }
    }
  }

  return { hue: null, saturation: null };
}

// Strip room name prefix from group name
function getGroupDisplayName(groupName: string, accessories: Accessory[]): string {
  // Get room name from first accessory that has one
  const roomName = accessories.find(acc => acc.roomName)?.roomName;
  if (!roomName || !groupName) return groupName;

  // Check if name starts with room name (case insensitive)
  if (groupName.toLowerCase().startsWith(roomName.toLowerCase())) {
    const stripped = groupName.slice(roomName.length).trim();
    return stripped || groupName;
  }
  return groupName;
}

// Get icon for service type
function getGroupIcon(serviceType: ServiceType | null): React.ComponentProps<typeof FontAwesome>['name'] {
  switch (serviceType) {
    case 'lightbulb': return 'lightbulb-o';
    case 'switch': return 'power-off';
    case 'outlet': return 'plug';
    case 'lock': return 'lock';
    case 'fan': return 'snowflake-o';
    case 'thermostat':
    case 'heater_cooler': return 'thermometer';
    default: return 'object-group';
  }
}

export function ServiceGroupWidget({
  groupId,
  groupName,
  accessories,
  onToggle,
  onCardPress,
}: ServiceGroupWidgetProps) {
  // Subscribe to store changes for all accessories in this group
  // This ensures re-render when any accessory's state changes optimistically
  const characteristics = useAccessoryStore((state) => state.characteristics);

  // Helper to get effective value (store value if exists, otherwise server value)
  const getEffectiveValue = (accessoryId: string, charType: string, serverValue: unknown) => {
    const key = `${accessoryId}:${charType}`;
    const storeValue = characteristics[key]?.value;
    return storeValue !== undefined ? storeValue : serverValue;
  };

  const serviceType = getGroupServiceType(accessories);
  const { onCount, totalCount, isOn } = getGroupStateWithStore(accessories, getEffectiveValue);
  const brightness = serviceType === 'lightbulb' ? getGroupBrightnessWithStore(accessories, getEffectiveValue) : null;
  const { hue, saturation } = serviceType === 'lightbulb' ? getGroupHueSaturationWithStore(accessories, getEffectiveValue) : { hue: null, saturation: null };
  const iconColors = getIconColor(serviceType, isOn);

  // Compute custom icon color based on hue if available
  let iconBgColor: string | undefined;
  if (isOn && hue !== null && saturation !== null) {
    const sat = saturation / 100; // Convert 0-100 to 0-1
    if (sat > 0.1) { // Only use hue color if saturation is significant
      iconBgColor = hsvToHex(hue, sat, 1);
    }
  }

  // Check if all accessories are reachable
  const isReachable = accessories.some(acc => acc.isReachable);

  // Build subtitle
  const getSubtitle = () => {
    if (!isReachable) return 'Unreachable';

    if (serviceType === 'lightbulb') {
      if (onCount === 0) return 'Off';
      if (brightness !== null) return `${brightness}%`;
      return `${onCount} On`;
    }

    if (onCount === totalCount) return 'All On';
    if (onCount === 0) return 'All Off';
    return `${onCount} On`;
  };

  // Determine characteristic type for toggle
  const getToggleCharacteristic = (): string => {
    switch (serviceType) {
      case 'lightbulb':
      case 'switch':
      case 'outlet':
        return 'power_state';
      case 'lock':
        return 'lock_target_state';
      case 'fan':
        return 'active';
      default:
        return 'power_state';
    }
  };

  const displayName = getGroupDisplayName(groupName, accessories);

  return (
    <WidgetCard
      title={displayName}
      subtitle={getSubtitle()}
      icon={<FontAwesome name={getGroupIcon(serviceType)} size={16} color={iconColors.icon} />}
      isOn={isOn}
      isReachable={isReachable}
      serviceType={serviceType}
      iconBgColor={iconBgColor}
      onIconPress={() => onToggle(groupId, getToggleCharacteristic(), isOn)}
      onCardPress={onCardPress}
    />
  );
}
