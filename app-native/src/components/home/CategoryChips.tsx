import React from 'react';
import { StyleSheet, View, ScrollView, TouchableOpacity } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import { Text } from '@/components/Themed';
import type { Accessory } from '@/types/homekit';
import { parseCharacteristicValue } from '@/types/homekit';

// Apple Home category colors
const CATEGORY_COLORS = {
  climate: '#64D2FF',
  lights: '#FFD60A',
  security: '#0A84FF',
};

interface CategoryChipsProps {
  accessories: Accessory[];
  onSelectCategory?: (category: string | null) => void;
  selectedCategory?: string | null;
}

function isLight(accessory: Accessory): boolean {
  return accessory.services?.some(s =>
    s.serviceType === 'lightbulb' ||
    s.characteristics?.some(c => c.characteristicType === 'brightness')
  ) ?? accessory.category === 'Lightbulb';
}

function isLightOn(accessory: Accessory): boolean {
  const powerChar = accessory.services?.flatMap(s => s.characteristics || [])
    .find(c => c.characteristicType === 'power_state' || c.characteristicType === 'on');
  if (!powerChar) return false;
  const value = parseCharacteristicValue<boolean | number>(powerChar.value);
  return value === true || value === 1;
}

function isClimate(accessory: Accessory): boolean {
  return accessory.services?.some(s =>
    s.serviceType === 'thermostat' ||
    s.serviceType === 'heater_cooler' ||
    s.serviceType === 'temperature_sensor'
  ) ?? false;
}

function isSecurity(accessory: Accessory): boolean {
  return accessory.services?.some(s =>
    s.serviceType === 'lock' ||
    s.serviceType === 'security_system' ||
    s.serviceType === 'motion_sensor' ||
    s.serviceType === 'contact_sensor'
  ) ?? accessory.category === 'Door Lock';
}

function getTemperatureRange(accessories: Accessory[]): string | null {
  const temps: number[] = [];
  accessories.filter(isClimate).forEach(acc => {
    acc.services?.forEach(s => {
      s.characteristics?.forEach(c => {
        if (c.characteristicType === 'current_temperature' && c.value !== null) {
          const temp = parseCharacteristicValue<number>(c.value);
          if (temp !== null) temps.push(temp);
        }
      });
    });
  });
  if (temps.length === 0) return null;
  const min = Math.min(...temps);
  const max = Math.max(...temps);
  return min === max ? `${min.toFixed(1)}°` : `${min.toFixed(1)}-${max.toFixed(1)}°`;
}

function getSecurityStatus(accessories: Accessory[]): string {
  const locks = accessories.filter(acc =>
    acc.services?.some(s => s.serviceType === 'lock')
  );
  const allLocked = locks.every(acc => {
    const lockChar = acc.services?.flatMap(s => s.characteristics || [])
      .find(c => c.characteristicType === 'lock_current_state');
    if (!lockChar) return true;
    const value = parseCharacteristicValue<number>(lockChar.value);
    return value === 1;
  });
  if (locks.length === 0) return 'No Alerts';
  return allLocked ? 'Locked' : 'Unlocked';
}

interface ChipProps {
  icon: React.ComponentProps<typeof FontAwesome>['name'];
  label: string;
  value: string;
  color: string;
  onPress?: () => void;
}

function Chip({ icon, label, value, color, onPress }: ChipProps) {
  return (
    <TouchableOpacity onPress={onPress} activeOpacity={0.7}>
      <View style={styles.chip}>
        <FontAwesome name={icon} size={13} color={color} />
        <View style={styles.chipTextContainer}>
          <Text style={styles.chipLabel}>{label}</Text>
          <Text style={styles.chipValue} numberOfLines={1}>{value}</Text>
        </View>
      </View>
    </TouchableOpacity>
  );
}

export function CategoryChips({ accessories, onSelectCategory, selectedCategory }: CategoryChipsProps) {
  const lights = accessories.filter(isLight);
  const lightsOn = lights.filter(isLightOn).length;
  const tempRange = getTemperatureRange(accessories);
  const securityStatus = getSecurityStatus(accessories);

  const hasClimate = accessories.some(isClimate);
  const hasLights = lights.length > 0;
  const hasSecurity = accessories.some(isSecurity);

  if (!hasClimate && !hasLights && !hasSecurity) {
    return null;
  }

  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      style={styles.container}
      contentContainerStyle={styles.content}
    >
      {hasClimate && tempRange && (
        <Chip
          icon="snowflake-o"
          label="Climate"
          value={tempRange}
          color={CATEGORY_COLORS.climate}
          onPress={() => onSelectCategory?.(selectedCategory === 'climate' ? null : 'climate')}
        />
      )}
      {hasLights && (
        <Chip
          icon="lightbulb-o"
          label="Lights"
          value={`${lightsOn} On`}
          color={CATEGORY_COLORS.lights}
          onPress={() => onSelectCategory?.(selectedCategory === 'lights' ? null : 'lights')}
        />
      )}
      {hasSecurity && (
        <Chip
          icon="lock"
          label="Security"
          value={securityStatus}
          color={CATEGORY_COLORS.security}
          onPress={() => onSelectCategory?.(selectedCategory === 'security' ? null : 'security')}
        />
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    marginTop: 12,
  },
  content: {
    paddingHorizontal: 16,
    gap: 8,
  },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 8,
    paddingHorizontal: 10,
    gap: 6,
    backgroundColor: 'rgba(0, 0, 0, 0.05)',
    borderRadius: 14,
  },
  chipTextContainer: {
    flexDirection: 'column',
  },
  chipLabel: {
    fontSize: 11,
    fontWeight: '600',
    color: '#000000',
  },
  chipValue: {
    fontSize: 10,
    color: 'rgba(0,0,0,0.5)',
  },
});
