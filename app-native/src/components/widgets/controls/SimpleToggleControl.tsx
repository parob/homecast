import React from 'react';
import { StyleSheet, View, TouchableOpacity } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';
import { Text } from '@/components/Themed';
import type { ServiceType } from '../types';

interface SimpleToggleControlProps {
  isOn: boolean;
  serviceType: ServiceType | null;
  onToggle: () => void;
}

export function SimpleToggleControl({
  isOn,
  serviceType,
  onToggle,
}: SimpleToggleControlProps) {
  // Get icon based on service type
  const getIcon = (): React.ComponentProps<typeof FontAwesome>['name'] => {
    switch (serviceType) {
      case 'outlet': return 'plug';
      case 'switch': return 'power-off';
      case 'lock': return isOn ? 'lock' : 'unlock';
      case 'fan': return 'snowflake-o';
      default: return 'power-off';
    }
  };

  // Get colors based on service type and state
  const getColors = () => {
    if (!isOn) {
      return { bg: 'rgba(100,100,100,0.5)', icon: '#fff' };
    }
    switch (serviceType) {
      case 'outlet': return { bg: '#30D158', icon: '#fff' };
      case 'switch': return { bg: '#BF5AF2', icon: '#fff' };
      case 'lock': return { bg: '#0A84FF', icon: '#fff' };
      default: return { bg: '#30D158', icon: '#fff' };
    }
  };

  // Get status text
  const getStatusText = () => {
    switch (serviceType) {
      case 'lock': return isOn ? 'Locked' : 'Unlocked';
      default: return isOn ? 'On' : 'Off';
    }
  };

  const handlePress = () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    onToggle();
  };

  const colors = getColors();

  return (
    <View style={styles.container}>
      <Text style={styles.statusText}>{getStatusText()}</Text>

      <TouchableOpacity
        style={[styles.button, { backgroundColor: colors.bg }]}
        onPress={handlePress}
        activeOpacity={0.8}
      >
        <FontAwesome name={getIcon()} size={32} color={colors.icon} />
      </TouchableOpacity>

      <Text style={styles.hintText}>Tap to toggle</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    gap: 16,
  },
  statusText: {
    fontSize: 24,
    fontWeight: '600',
    color: '#fff',
  },
  button: {
    width: 100,
    height: 100,
    borderRadius: 50,
    justifyContent: 'center',
    alignItems: 'center',
  },
  hintText: {
    fontSize: 13,
    color: 'rgba(255,255,255,0.4)',
  },
});
