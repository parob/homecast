import React from 'react';
import { StyleSheet } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { WidgetCard, getIconColor } from './WidgetCard';
import { WidgetProps, getCharacteristic, hasServiceType } from './types';
import { useCharacteristicValue, useAccessoryPending } from '@/hooks/useCharacteristicValue';
import { Text } from '@/components/Themed';
import { AppleHomeColors } from '@/constants/Colors';

export function ThermostatWidget({
  accessory,
  displayName,
  onToggle,
  onCardPress,
}: WidgetProps) {
  const isHeaterCooler = hasServiceType(accessory, 'heater_cooler');

  // Common characteristics
  const activeChar = getCharacteristic(accessory, 'active');
  const currentTempChar = getCharacteristic(accessory, 'current_temperature');

  // Subscribe to store values for optimistic updates
  const activeValue = useCharacteristicValue(accessory.id, activeChar?.type, activeChar?.value);
  const currentTemp = useCharacteristicValue(accessory.id, currentTempChar?.type, currentTempChar?.value);
  const isPending = useAccessoryPending(accessory.id);

  // Active state
  const isActive = activeValue === true || activeValue === 1 || activeChar === null;
  const iconColors = getIconColor('thermostat', isActive);

  // Build subtitle - show temperature prominently like Apple Home
  const getSubtitle = () => {
    if (!isActive) return 'Off';
    if (currentTemp !== null && currentTemp !== undefined) {
      return `${Number(currentTemp).toFixed(1)}°`;
    }
    return 'On';
  };

  // For Apple Home style, show large temp in the icon area
  const showLargeTemp = isActive && currentTemp !== null && currentTemp !== undefined;

  return (
    <WidgetCard
      title={displayName}
      subtitle={showLargeTemp ? '' : getSubtitle()}
      icon={
        showLargeTemp ? (
          <Text style={styles.largeTemp}>{Number(currentTemp).toFixed(1)}°</Text>
        ) : (
          <FontAwesome name="thermometer" size={16} color={iconColors.icon} />
        )
      }
      isOn={isActive}
      isReachable={accessory.isReachable}
      serviceType="thermostat"
      isPending={isPending}
      onIconPress={activeChar?.isWritable ? () => onToggle(accessory.id, 'active', isActive) : undefined}
      onCardPress={onCardPress}
    />
  );
}

const styles = StyleSheet.create({
  largeTemp: {
    fontSize: 13,
    fontWeight: '600',
    color: AppleHomeColors.textPrimary,
  },
});
