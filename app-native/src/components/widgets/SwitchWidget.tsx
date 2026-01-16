import React from 'react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { WidgetCard, getIconColor } from './WidgetCard';
import { WidgetProps, getCharacteristic } from './types';
import { useCharacteristicValue, useAccessoryPending } from '@/hooks/useCharacteristicValue';

export function SwitchWidget({
  accessory,
  displayName,
  onToggle,
  onCardPress,
}: WidgetProps) {
  const powerChar = getCharacteristic(accessory, 'power_state') || getCharacteristic(accessory, 'on');

  // Subscribe to store value for optimistic updates
  const powerValue = useCharacteristicValue(accessory.id, powerChar?.type, powerChar?.value);
  const isPending = useAccessoryPending(accessory.id);
  const isOn = powerValue === true || powerValue === 1;
  const iconColors = getIconColor('switch', isOn);

  return (
    <WidgetCard
      title={displayName}
      subtitle={isOn ? 'On' : 'Off'}
      icon={<FontAwesome name="power-off" size={16} color={iconColors.icon} />}
      isOn={isOn}
      isReachable={accessory.isReachable}
      serviceType="switch"
      isPending={isPending}
      onIconPress={powerChar ? () => onToggle(accessory.id, powerChar.type, isOn) : undefined}
      onCardPress={onCardPress}
    />
  );
}
