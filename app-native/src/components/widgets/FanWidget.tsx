import React from 'react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { WidgetCard, getIconColor } from './WidgetCard';
import { WidgetProps, getCharacteristic } from './types';
import { useCharacteristicValue } from '@/hooks/useCharacteristicValue';

export function FanWidget({
  accessory,
  displayName,
  onToggle,
  onCardPress,
}: WidgetProps) {
  const powerChar = getCharacteristic(accessory, 'power_state') ||
                    getCharacteristic(accessory, 'on') ||
                    getCharacteristic(accessory, 'active');
  const speedChar = getCharacteristic(accessory, 'rotation_speed');

  // Subscribe to store values for optimistic updates
  const powerValue = useCharacteristicValue(accessory.id, powerChar?.type, powerChar?.value);
  const speed = useCharacteristicValue(accessory.id, speedChar?.type, speedChar?.value);

  const isOn = powerValue === true || powerValue === 1;
  const iconColors = getIconColor('fan', isOn);

  const subtitle = isOn && speed !== null && speed !== undefined
    ? `${Math.round(speed as number)}%`
    : isOn ? 'On' : 'Off';

  return (
    <WidgetCard
      title={displayName}
      subtitle={subtitle}
      icon={<FontAwesome name="snowflake-o" size={16} color={iconColors.icon} />}
      isOn={isOn}
      isReachable={accessory.isReachable}
      serviceType="fan"
      onIconPress={powerChar ? () => onToggle(accessory.id, powerChar.type, isOn) : undefined}
      onCardPress={onCardPress}
    />
  );
}
