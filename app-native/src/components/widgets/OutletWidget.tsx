import React from 'react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { WidgetCard, getIconColor } from './WidgetCard';
import { WidgetProps, getCharacteristic } from './types';
import { useCharacteristicValue } from '@/hooks/useCharacteristicValue';

export function OutletWidget({
  accessory,
  displayName,
  onToggle,
  onCardPress,
}: WidgetProps) {
  const powerChar = getCharacteristic(accessory, 'power_state') || getCharacteristic(accessory, 'on');
  const inUseChar = getCharacteristic(accessory, 'outlet_in_use');

  // Subscribe to store value for optimistic updates
  const powerValue = useCharacteristicValue(accessory.id, powerChar?.type, powerChar?.value);
  const isOn = powerValue === true || powerValue === 1;
  const inUse = inUseChar?.value === true || inUseChar?.value === 1;
  const iconColors = getIconColor('outlet', isOn);

  const subtitle = isOn ? (inUse ? 'In Use' : 'On') : 'Off';

  return (
    <WidgetCard
      title={displayName}
      subtitle={subtitle}
      icon={<FontAwesome name="plug" size={16} color={iconColors.icon} />}
      isOn={isOn}
      isReachable={accessory.isReachable}
      serviceType="outlet"
      onIconPress={powerChar ? () => onToggle(accessory.id, powerChar.type, isOn) : undefined}
      onCardPress={onCardPress}
    />
  );
}
