import { StyleSheet, TouchableOpacity, View, Dimensions, Switch } from 'react-native';
import { useMutation } from '@apollo/client/react';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';

import { Text } from '@/components/Themed';
import { SET_CHARACTERISTIC_MUTATION } from '@/api/graphql/mutations';
import { useAccessoryStore } from '@/stores/accessoryStore';
import { CharacteristicTypes } from '@/constants/characteristics';
import { parseCharacteristicValue, stringifyCharacteristicValue } from '@/types/homekit';
import type { Accessory } from '@/types/homekit';
import type { SetCharacteristicResult } from '@/types/api';

interface Props {
  accessory: Accessory;
}

const SCREEN_WIDTH = Dimensions.get('window').width;
const CARD_WIDTH = (SCREEN_WIDTH - 32) / 2 - 8; // 16px padding on each side, 8px gap

// Colors matching homecast-web
const COLORS = {
  primary: '#3b82f6', // HSL 217 91% 60%
  primaryLight: 'rgba(59, 130, 246, 0.15)', // bg-primary/15
  muted: '#e5e7eb', // HSL 214 32% 91%
  mutedLight: 'rgba(229, 231, 235, 0.3)', // bg-muted/30
  mutedForeground: '#6b7280', // HSL 215 16% 47%
  foreground: '#030712', // HSL 222 84% 5%
};

export function AccessoryCard({ accessory }: Props) {
  const [setCharacteristic] = useMutation<{ setCharacteristic: SetCharacteristicResult }>(SET_CHARACTERISTIC_MUTATION);
  const { updateCharacteristic, getCharacteristicValue, revertOptimistic } = useAccessoryStore();

  // Find primary characteristic (power state for most devices)
  const primaryService = accessory.services.find(
    (s) => s.serviceType !== 'accessory-information'
  );
  const powerCharacteristic = primaryService?.characteristics.find(
    (c) => c.characteristicType === CharacteristicTypes.POWER_STATE
  );
  const brightnessCharacteristic = primaryService?.characteristics.find(
    (c) => c.characteristicType === CharacteristicTypes.BRIGHTNESS
  );

  // Get current power state (from store or characteristic)
  const storeValue = getCharacteristicValue(accessory.id, CharacteristicTypes.POWER_STATE);
  const isPoweredOn = storeValue !== null
    ? Boolean(storeValue)
    : parseCharacteristicValue<boolean>(powerCharacteristic?.value) ?? false;

  const brightness = brightnessCharacteristic
    ? parseCharacteristicValue<number>(brightnessCharacteristic.value)
    : null;

  const handleToggle = async () => {
    if (!powerCharacteristic?.isWritable) return;

    const newValue = !isPoweredOn;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);

    // Optimistic update
    updateCharacteristic(accessory.id, CharacteristicTypes.POWER_STATE, newValue, true);

    try {
      const { data } = await setCharacteristic({
        variables: {
          accessoryId: accessory.id,
          characteristicType: CharacteristicTypes.POWER_STATE,
          value: stringifyCharacteristicValue(newValue),
        },
      });

      if (data?.setCharacteristic?.success) {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      } else {
        revertOptimistic(accessory.id, CharacteristicTypes.POWER_STATE);
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      }
    } catch (error) {
      revertOptimistic(accessory.id, CharacteristicTypes.POWER_STATE);
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
    }
  };

  const getCategoryIcon = (category: string): React.ComponentProps<typeof FontAwesome>['name'] => {
    switch (category.toLowerCase()) {
      case 'lightbulb':
        return 'lightbulb-o';
      case 'switch':
      case 'outlet':
        return 'power-off';
      case 'thermostat':
        return 'thermometer';
      case 'lock':
        return 'lock';
      case 'door':
        return 'bars';
      case 'fan':
        return 'snowflake-o';
      case 'sensor':
        return 'eye';
      default:
        return 'cube';
    }
  };

  // Subtitle text
  const getSubtitle = () => {
    if (!accessory.isReachable) return 'Unreachable';
    if (isPoweredOn && brightness !== null) return `${Math.round(brightness)}% brightness`;
    return null;
  };

  const subtitle = getSubtitle();

  return (
    <View
      style={[
        styles.container,
        { backgroundColor: isPoweredOn ? COLORS.primaryLight : COLORS.mutedLight },
        !accessory.isReachable && styles.containerUnreachable,
      ]}
    >
      {/* Header row with icon, title, and switch */}
      <View style={styles.header}>
        {/* Icon and title */}
        <TouchableOpacity
          style={styles.headerLeft}
          onPress={handleToggle}
          disabled={!powerCharacteristic?.isWritable || !accessory.isReachable}
          activeOpacity={0.7}
        >
          <View
            style={[
              styles.iconContainer,
              {
                backgroundColor: isPoweredOn ? COLORS.primary : COLORS.muted,
              },
            ]}
          >
            <FontAwesome
              name={getCategoryIcon(accessory.category)}
              size={16}
              color={isPoweredOn ? '#fff' : COLORS.mutedForeground}
            />
          </View>
          <View style={styles.titleContainer}>
            <Text style={styles.title} numberOfLines={1}>
              {accessory.name}
            </Text>
            {subtitle && (
              <Text style={styles.subtitle} numberOfLines={1}>
                {subtitle}
              </Text>
            )}
          </View>
        </TouchableOpacity>

        {/* Switch */}
        {powerCharacteristic && (
          <Switch
            value={isPoweredOn}
            onValueChange={handleToggle}
            disabled={!accessory.isReachable}
            trackColor={{ false: COLORS.muted, true: COLORS.primary }}
            thumbColor="#fff"
            style={styles.switch}
          />
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    width: CARD_WIDTH,
    borderRadius: 16,
    padding: 16,
    margin: 4,
    minHeight: 72,
  },
  containerUnreachable: {
    opacity: 0.5,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  headerLeft: {
    flexDirection: 'row',
    alignItems: 'center',
    flex: 1,
    gap: 10,
  },
  iconContainer: {
    width: 36,
    height: 36,
    borderRadius: 12,
    justifyContent: 'center',
    alignItems: 'center',
  },
  titleContainer: {
    flex: 1,
  },
  title: {
    fontSize: 14,
    fontWeight: '500',
    color: COLORS.foreground,
    lineHeight: 18,
  },
  subtitle: {
    fontSize: 12,
    color: COLORS.mutedForeground,
    marginTop: 2,
  },
  switch: {
    transform: [{ scaleX: 0.85 }, { scaleY: 0.85 }],
  },
});
