import React from 'react';
import { useMutation } from '@apollo/client/react';
import * as Haptics from 'expo-haptics';

import { SET_CHARACTERISTIC_MUTATION } from '@/api/graphql/mutations';
import { useAccessoryStore } from '@/stores/accessoryStore';
import { markLocalChange } from '@/providers/WebSocketProvider';
import { stringifyCharacteristicValue } from '@/types/homekit';
import type { Accessory } from '@/types/homekit';
import type { SetCharacteristicResult } from '@/types/api';

import { LightbulbWidget } from './LightbulbWidget';
import { SwitchWidget } from './SwitchWidget';
import { OutletWidget } from './OutletWidget';
import { LockWidget } from './LockWidget';
import { FanWidget } from './FanWidget';
import { ThermostatWidget } from './ThermostatWidget';
import { SensorWidget } from './SensorWidget';
import { getPrimaryServiceType, categoryToServiceType, ServiceType } from './types';

// Re-export types and components (including getDisplayName)
export * from './types';
export { WidgetCard, WidgetSwitch, COLORS } from './WidgetCard';
export { DeviceControlModal } from './DeviceControlModal';
export { ServiceGroupWidget } from './ServiceGroupWidget';
export { LightbulbWidget } from './LightbulbWidget';
export { SwitchWidget } from './SwitchWidget';
export { OutletWidget } from './OutletWidget';
export { LockWidget } from './LockWidget';
export { FanWidget } from './FanWidget';
export { ThermostatWidget } from './ThermostatWidget';
export { SensorWidget } from './SensorWidget';

// Sensor types
const SENSOR_TYPES: ServiceType[] = [
  'motion_sensor',
  'contact_sensor',
  'temperature_sensor',
  'humidity_sensor',
];

// Import getDisplayName from types
import { getDisplayName } from './types';

interface AccessoryWidgetProps {
  accessory: Accessory;
  onCardPress?: () => void;  // Opens the control modal
}

/**
 * Smart widget selector - picks the right widget based on accessory type
 */
export function AccessoryWidget({ accessory, onCardPress }: AccessoryWidgetProps) {
  const [setCharacteristic] = useMutation<{ setCharacteristic: SetCharacteristicResult }>(SET_CHARACTERISTIC_MUTATION);
  const { updateCharacteristic, getCharacteristicValue, revertOptimistic } = useAccessoryStore();

  // Get effective value (from store if optimistic, otherwise from server)
  const getEffectiveValue = (accessoryId: string, characteristicType: string, serverValue: any) => {
    const storeValue = getCharacteristicValue(accessoryId, characteristicType);
    return storeValue !== null ? storeValue : serverValue;
  };

  // Handle toggle (for boolean characteristics like power_state)
  const handleToggle = async (accessoryId: string, characteristicType: string, currentValue: boolean) => {
    const newValue = !currentValue;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);

    // Mark as local change to prevent WebSocket echo
    markLocalChange(accessoryId, characteristicType);

    // Optimistic update
    updateCharacteristic(accessoryId, characteristicType, newValue, true);

    try {
      const { data } = await setCharacteristic({
        variables: {
          accessoryId,
          characteristicType,
          value: stringifyCharacteristicValue(newValue),
        },
      });

      if (data?.setCharacteristic?.success) {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      } else {
        revertOptimistic(accessoryId, characteristicType);
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      }
    } catch (error) {
      revertOptimistic(accessoryId, characteristicType);
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
    }
  };

  // Handle slider (for numeric characteristics like brightness)
  const handleSlider = async (accessoryId: string, characteristicType: string, value: number) => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

    // Mark as local change to prevent WebSocket echo
    markLocalChange(accessoryId, characteristicType);

    // Optimistic update
    updateCharacteristic(accessoryId, characteristicType, value, true);

    try {
      const { data } = await setCharacteristic({
        variables: {
          accessoryId,
          characteristicType,
          value: stringifyCharacteristicValue(value),
        },
      });

      if (!data?.setCharacteristic?.success) {
        revertOptimistic(accessoryId, characteristicType);
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      }
    } catch (error) {
      revertOptimistic(accessoryId, characteristicType);
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
    }
  };

  // Common props for all widgets
  const displayName = getDisplayName(accessory);
  const widgetProps = {
    accessory,
    displayName,
    onToggle: handleToggle,
    onSlider: handleSlider,
    getEffectiveValue,
    onCardPress,
  };

  // Determine service type
  let serviceType = getPrimaryServiceType(accessory);

  // Fall back to category mapping if no service type
  if (!serviceType && accessory.category) {
    serviceType = categoryToServiceType(accessory.category);
  }

  // Check for sensor types
  if (serviceType && SENSOR_TYPES.includes(serviceType)) {
    return <SensorWidget {...widgetProps} sensorType={serviceType} />;
  }

  // Map to specific widget
  switch (serviceType) {
    case 'lightbulb':
      return <LightbulbWidget {...widgetProps} />;

    case 'switch':
      return <SwitchWidget {...widgetProps} />;

    case 'outlet':
      return <OutletWidget {...widgetProps} />;

    case 'lock':
      return <LockWidget {...widgetProps} />;

    case 'fan':
      return <FanWidget {...widgetProps} />;

    case 'thermostat':
    case 'heater_cooler':
      return <ThermostatWidget {...widgetProps} />;

    // Default to switch widget for unknown types
    default:
      return <SwitchWidget {...widgetProps} />;
  }
}
