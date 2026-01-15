import React from 'react';
import { StyleSheet, View, TouchableOpacity, Dimensions } from 'react-native';
import { Text } from '@/components/Themed';
import { AppleHomeColors } from '@/constants/Colors';
import type { ServiceType } from './types';

const SCREEN_WIDTH = Dimensions.get('window').width;
const CARD_WIDTH = (SCREEN_WIDTH - 48) / 2;

// Colors for white background
const TILE_COLORS = {
  offBg: 'rgba(0, 0, 0, 0.05)',
  onLightBg: 'rgba(255, 214, 10, 0.25)',
  onGreenBg: 'rgba(48, 209, 88, 0.25)',
  onBlueBg: 'rgba(10, 132, 255, 0.15)',
  iconOffBg: 'rgba(0, 0, 0, 0.08)',
  iconOffColor: 'rgba(0, 0, 0, 0.4)',
};

export const getTileBackground = (serviceType: ServiceType | null, isOn: boolean) => {
  if (!isOn) {
    return TILE_COLORS.offBg;
  }
  switch (serviceType) {
    case 'lightbulb': return TILE_COLORS.onLightBg;
    case 'lock': return TILE_COLORS.onBlueBg;
    case 'outlet':
    case 'switch': return TILE_COLORS.onGreenBg;
    default: return TILE_COLORS.onLightBg;
  }
};

export const getIconColor = (serviceType: ServiceType | null, isOn: boolean) => {
  if (!isOn) {
    return { bg: TILE_COLORS.iconOffBg, icon: TILE_COLORS.iconOffColor };
  }
  switch (serviceType) {
    case 'lightbulb': return { bg: '#FFD60A', icon: '#fff' };
    case 'lock': return { bg: '#0A84FF', icon: '#fff' };
    case 'thermostat':
    case 'heater_cooler': return { bg: '#FF9F0A', icon: '#fff' };
    case 'fan': return { bg: '#64D2FF', icon: '#fff' };
    case 'switch': return { bg: '#BF5AF2', icon: '#fff' };
    case 'outlet': return { bg: '#30D158', icon: '#fff' };
    case 'motion_sensor':
    case 'contact_sensor':
    case 'temperature_sensor':
    case 'humidity_sensor': return { bg: '#5E5CE6', icon: '#fff' };
    default: return { bg: '#FFD60A', icon: '#fff' };
  }
};

export const COLORS = {
  primary: AppleHomeColors.tabActive,
  primaryLight: 'rgba(48, 209, 88, 0.15)',
  muted: 'rgba(0,0,0,0.1)',
  mutedLight: 'rgba(0,0,0,0.05)',
  mutedForeground: 'rgba(0,0,0,0.5)',
  foreground: '#000000',
  lightbulb: { bg: '#FFD60A', bgLight: TILE_COLORS.onLightBg },
  lock: { bg: '#0A84FF', bgLight: TILE_COLORS.onBlueBg },
  thermostat: { bg: '#FF9F0A', bgLight: 'rgba(255,159,10,0.2)' },
  fan: { bg: '#64D2FF', bgLight: 'rgba(100,210,255,0.2)' },
  switch: { bg: '#BF5AF2', bgLight: 'rgba(191,90,242,0.2)' },
  outlet: { bg: '#30D158', bgLight: TILE_COLORS.onGreenBg },
  sensor: { bg: '#5E5CE6', bgLight: 'rgba(94,92,230,0.2)' },
};

export const getServiceColor = (serviceType: ServiceType | null, isOn: boolean) => {
  const iconColors = getIconColor(serviceType, isOn);
  const cardBg = getTileBackground(serviceType, isOn);
  return { iconBg: iconColors.bg, iconColor: iconColors.icon, cardBg };
};

interface WidgetCardProps {
  title: string;
  subtitle?: string | null;
  icon: React.ReactNode;
  isOn: boolean;
  isReachable: boolean;
  serviceType: ServiceType | null;
  iconBgColor?: string;      // Custom icon background color (e.g., from hue)
  tileBgColor?: string;      // Custom tile background color
  onIconPress?: () => void;  // Tap on icon = toggle
  onCardPress?: () => void;  // Tap on card = open controls
  onPress?: () => void;      // Legacy - same as onIconPress
  headerAction?: React.ReactNode;
  children?: React.ReactNode;
}

export function WidgetCard({
  title,
  subtitle,
  icon,
  isOn,
  isReachable,
  serviceType,
  iconBgColor,
  tileBgColor,
  onIconPress,
  onCardPress,
  onPress,
  children,
}: WidgetCardProps) {
  const defaultTileBg = getTileBackground(serviceType, isOn && isReachable);
  const defaultIconColors = getIconColor(serviceType, isOn && isReachable);

  // Use custom colors if provided, otherwise defaults
  const tileBackground = tileBgColor || defaultTileBg;
  const iconColors = {
    bg: iconBgColor || defaultIconColors.bg,
    icon: defaultIconColors.icon,
  };

  // Use legacy onPress for icon if new handlers not provided
  const handleIconPress = onIconPress || onPress;
  const handleCardPress = onCardPress;

  return (
    <View style={[styles.container, !isReachable && styles.containerUnreachable]}>
      <TouchableOpacity
        onPress={handleCardPress}
        disabled={!handleCardPress || !isReachable}
        activeOpacity={0.7}
        style={[styles.content, { backgroundColor: tileBackground }]}
      >
        {/* Icon - separate tap zone */}
        <TouchableOpacity
          onPress={handleIconPress}
          disabled={!handleIconPress || !isReachable}
          activeOpacity={0.6}
          style={[styles.iconContainer, { backgroundColor: iconColors.bg }]}
        >
          {icon}
        </TouchableOpacity>

        {/* Text */}
        <View style={styles.textContainer}>
          <Text style={styles.title} numberOfLines={1}>
            {title}
          </Text>
          <Text style={styles.subtitle} numberOfLines={1}>
            {!isReachable ? 'Unreachable' : subtitle || (isOn ? 'On' : 'Off')}
          </Text>
        </View>
      </TouchableOpacity>
    </View>
  );
}

interface WidgetSwitchProps {
  value: boolean;
  onValueChange: () => void;
  disabled?: boolean;
  serviceType?: ServiceType | null;
}

export function WidgetSwitch(_props: WidgetSwitchProps) {
  return null;
}

const styles = StyleSheet.create({
  container: {
    width: CARD_WIDTH,
    margin: 4,
    borderRadius: 16,
    overflow: 'hidden',
  },
  containerUnreachable: {
    opacity: 0.5,
  },
  content: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 12,
    paddingHorizontal: 12,
    gap: 10,
    minHeight: 64,
    borderRadius: 16,
  },
  iconContainer: {
    width: 34,
    height: 34,
    borderRadius: 10,
    justifyContent: 'center',
    alignItems: 'center',
  },
  textContainer: {
    flex: 1,
    gap: 2,
  },
  title: {
    fontSize: 14,
    fontWeight: '500',
    color: '#000000',
    lineHeight: 18,
  },
  subtitle: {
    fontSize: 12,
    color: 'rgba(0,0,0,0.5)',
    lineHeight: 16,
  },
});
