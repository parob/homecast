import React from 'react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { WidgetCard, getIconColor } from './WidgetCard';
import { WidgetProps, getCharacteristic, ServiceType } from './types';

interface SensorWidgetProps extends WidgetProps {
  sensorType?: ServiceType;
}

export function SensorWidget({
  accessory,
  displayName,
  sensorType,
  onCardPress,
}: SensorWidgetProps) {
  // Get sensor-specific characteristics
  const motionChar = getCharacteristic(accessory, 'motion_detected');
  const contactChar = getCharacteristic(accessory, 'contact_sensor_state');
  const tempChar = getCharacteristic(accessory, 'current_temperature');
  const humidityChar = getCharacteristic(accessory, 'relative_humidity');

  // Determine icon and state
  let icon: React.ComponentProps<typeof FontAwesome>['name'] = 'eye';
  let isActive = false;
  let subtitle = '';

  switch (sensorType) {
    case 'motion_sensor':
      icon = 'male';
      isActive = motionChar?.value === true || motionChar?.value === 1;
      subtitle = isActive ? 'Motion Detected' : 'No Motion';
      break;

    case 'contact_sensor':
      icon = 'magnet';
      // Contact sensor: 0 = contact (closed), 1 = no contact (open)
      isActive = contactChar?.value === 1;
      subtitle = isActive ? 'Open' : 'Closed';
      break;

    case 'temperature_sensor':
      icon = 'thermometer';
      if (tempChar?.value !== null && tempChar?.value !== undefined) {
        subtitle = `${Number(tempChar.value).toFixed(1)}°`;
        isActive = true;
      }
      break;

    case 'humidity_sensor':
      icon = 'tint';
      if (humidityChar?.value !== null && humidityChar?.value !== undefined) {
        subtitle = `${Math.round(Number(humidityChar.value))}%`;
        isActive = true;
      }
      break;

    default:
      // Generic sensor
      if (tempChar?.value !== null && tempChar?.value !== undefined) {
        subtitle = `${Number(tempChar.value).toFixed(1)}°`;
        isActive = true;
      } else if (motionChar) {
        isActive = motionChar.value === true || motionChar.value === 1;
        subtitle = isActive ? 'Motion' : 'Clear';
      }
  }

  const iconColors = getIconColor(sensorType || 'motion_sensor', isActive);

  return (
    <WidgetCard
      title={displayName}
      subtitle={subtitle || 'Unknown'}
      icon={<FontAwesome name={icon} size={16} color={iconColors.icon} />}
      isOn={isActive}
      isReachable={accessory.isReachable}
      serviceType={sensorType || 'motion_sensor'}
      onCardPress={onCardPress}
    />
  );
}
