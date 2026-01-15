import React from 'react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { WidgetCard, getIconColor } from './WidgetCard';
import { WidgetProps, getCharacteristic, hsvToHex } from './types';
import { useCharacteristicValue } from '@/hooks/useCharacteristicValue';

export function LightbulbWidget({
  accessory,
  displayName,
  onToggle,
  onCardPress,
}: WidgetProps) {
  const powerChar = getCharacteristic(accessory, 'power_state') || getCharacteristic(accessory, 'on');
  const brightnessChar = getCharacteristic(accessory, 'brightness');
  const hueChar = getCharacteristic(accessory, 'hue');
  const saturationChar = getCharacteristic(accessory, 'saturation');

  // Subscribe to store values for optimistic updates
  const powerValue = useCharacteristicValue(accessory.id, powerChar?.type, powerChar?.value);
  const brightness = useCharacteristicValue(accessory.id, brightnessChar?.type, brightnessChar?.value);
  const hue = useCharacteristicValue(accessory.id, hueChar?.type, hueChar?.value);
  const saturation = useCharacteristicValue(accessory.id, saturationChar?.type, saturationChar?.value);

  const isOn = powerValue === true || powerValue === 1;
  const iconColors = getIconColor('lightbulb', isOn);

  // Compute custom icon color based on hue if available
  let iconBgColor: string | undefined;
  if (isOn && hue !== null && hue !== undefined && saturation !== null && saturation !== undefined) {
    const sat = Number(saturation) / 100; // Convert 0-100 to 0-1
    if (sat > 0.1) { // Only use hue color if saturation is significant
      iconBgColor = hsvToHex(Number(hue), sat, 1);
    }
  }

  const subtitle = isOn && brightness !== null && brightness !== undefined
    ? `${Math.round(brightness as number)}%`
    : isOn ? 'On' : 'Off';

  return (
    <WidgetCard
      title={displayName}
      subtitle={subtitle}
      icon={<FontAwesome name="lightbulb-o" size={16} color={iconColors.icon} />}
      isOn={isOn}
      isReachable={accessory.isReachable}
      serviceType="lightbulb"
      iconBgColor={iconBgColor}
      onIconPress={powerChar ? () => onToggle(accessory.id, powerChar.type, isOn) : undefined}
      onCardPress={onCardPress}
    />
  );
}
