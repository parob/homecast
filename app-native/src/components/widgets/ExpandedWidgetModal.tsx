import React from 'react';
import {
  StyleSheet,
  View,
  Modal,
  TouchableOpacity,
  TouchableWithoutFeedback,
  ScrollView,
  SafeAreaView,
} from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import Slider from '@react-native-community/slider';

import { Text } from '@/components/Themed';
import { COLORS, getServiceColor } from './WidgetCard';
import {
  getCharacteristic,
  getPrimaryServiceType,
  parseCharacteristicValue,
} from './types';
import type { Accessory } from '@/types/homekit';

interface ExpandedWidgetModalProps {
  accessory: Accessory | null;
  visible: boolean;
  onClose: () => void;
  onToggle: (accessoryId: string, characteristicType: string, currentValue: boolean) => void;
  onSlider: (accessoryId: string, characteristicType: string, value: number) => void;
  getEffectiveValue: (accessoryId: string, characteristicType: string, serverValue: any) => any;
}

export function ExpandedWidgetModal({
  accessory,
  visible,
  onClose,
  onToggle,
  onSlider,
  getEffectiveValue,
}: ExpandedWidgetModalProps) {
  if (!accessory) return null;

  const serviceType = getPrimaryServiceType(accessory);
  const colors = getServiceColor(serviceType, true);

  // Get all characteristics for this accessory
  const characteristics: Array<{
    type: string;
    value: any;
    isWritable: boolean;
    isReadable: boolean;
    minValue?: number;
    maxValue?: number;
    stepValue?: number;
    serviceName: string;
  }> = [];

  for (const service of accessory.services || []) {
    if (service.serviceType === 'accessory_information') continue;

    for (const char of service.characteristics || []) {
      characteristics.push({
        type: char.characteristicType,
        value: getEffectiveValue(accessory.id, char.characteristicType, parseCharacteristicValue(char.value)),
        isWritable: char.isWritable ?? false,
        isReadable: char.isReadable ?? true,
        minValue: char.minValue,
        maxValue: char.maxValue,
        stepValue: char.stepValue,
        serviceName: service.name || service.serviceType,
      });
    }
  }

  const formatCharacteristicName = (type: string) => {
    return type
      .replace(/_/g, ' ')
      .replace(/\b\w/g, (c) => c.toUpperCase());
  };

  const formatValue = (type: string, value: any) => {
    if (value === null || value === undefined) return '—';
    if (typeof value === 'boolean') return value ? 'Yes' : 'No';

    switch (type) {
      case 'current_temperature':
      case 'target_temperature':
      case 'heating_threshold':
      case 'cooling_threshold':
        return `${Number(value).toFixed(1)}°C`;
      case 'brightness':
      case 'relative_humidity':
      case 'battery_level':
      case 'rotation_speed':
      case 'current_position':
      case 'target_position':
        return `${Math.round(value)}%`;
      case 'lock_current_state':
        return ['Unlocked', 'Locked', 'Jammed', 'Unknown'][value] || 'Unknown';
      case 'power_state':
      case 'on':
      case 'active':
        return value ? 'On' : 'Off';
      default:
        return String(value);
    }
  };

  const isSliderType = (type: string) => {
    return ['brightness', 'rotation_speed', 'target_temperature', 'heating_threshold',
            'cooling_threshold', 'target_position', 'volume'].includes(type);
  };

  const isToggleType = (type: string) => {
    return ['power_state', 'on', 'active', 'lock_target_state'].includes(type);
  };

  return (
    <Modal
      visible={visible}
      animationType="slide"
      presentationStyle="pageSheet"
      onRequestClose={onClose}
    >
      <SafeAreaView style={styles.container}>
        {/* Header */}
        <View style={styles.header}>
          <View style={styles.headerLeft}>
            <View style={[styles.iconContainer, { backgroundColor: colors.iconBg }]}>
              <FontAwesome
                name={getIconForService(serviceType)}
                size={20}
                color="#fff"
              />
            </View>
            <View>
              <Text style={styles.title}>{accessory.name}</Text>
              {accessory.roomName && (
                <Text style={styles.subtitle}>{accessory.roomName}</Text>
              )}
            </View>
          </View>
          <TouchableOpacity onPress={onClose} style={styles.closeButton}>
            <FontAwesome name="times" size={24} color={COLORS.mutedForeground} />
          </TouchableOpacity>
        </View>

        {/* Status */}
        <View style={styles.statusSection}>
          <View style={[styles.statusBadge, {
            backgroundColor: accessory.isReachable ? '#34C759' : '#FF3B30'
          }]}>
            <Text style={styles.statusText}>
              {accessory.isReachable ? 'Reachable' : 'Unreachable'}
            </Text>
          </View>
          <Text style={styles.categoryText}>{accessory.category}</Text>
        </View>

        {/* Characteristics */}
        <ScrollView style={styles.content} contentContainerStyle={styles.contentInner}>
          <Text style={styles.sectionTitle}>Controls & Status</Text>

          {characteristics.map((char, index) => (
            <View key={`${char.type}-${index}`} style={styles.characteristicRow}>
              <View style={styles.characteristicHeader}>
                <Text style={styles.characteristicName}>
                  {formatCharacteristicName(char.type)}
                </Text>
                <Text style={styles.characteristicValue}>
                  {formatValue(char.type, char.value)}
                </Text>
              </View>

              {/* Slider control */}
              {char.isWritable && isSliderType(char.type) && accessory.isReachable && (
                <Slider
                  style={styles.slider}
                  minimumValue={char.minValue ?? 0}
                  maximumValue={char.maxValue ?? 100}
                  step={char.stepValue ?? 1}
                  value={Number(char.value) || 0}
                  onSlidingComplete={(value) => onSlider(accessory.id, char.type, value)}
                  minimumTrackTintColor={colors.iconBg}
                  maximumTrackTintColor={COLORS.muted}
                  thumbTintColor={colors.iconBg}
                />
              )}

              {/* Toggle button */}
              {char.isWritable && isToggleType(char.type) && accessory.isReachable && (
                <TouchableOpacity
                  style={[styles.toggleButton, {
                    backgroundColor: char.value ? colors.iconBg : COLORS.muted
                  }]}
                  onPress={() => onToggle(accessory.id, char.type, Boolean(char.value))}
                >
                  <Text style={[styles.toggleText, { color: char.value ? '#fff' : COLORS.foreground }]}>
                    {char.value ? 'Turn Off' : 'Turn On'}
                  </Text>
                </TouchableOpacity>
              )}
            </View>
          ))}

          {characteristics.length === 0 && (
            <Text style={styles.emptyText}>No characteristics available</Text>
          )}
        </ScrollView>
      </SafeAreaView>
    </Modal>
  );
}

function getIconForService(serviceType: string | null): React.ComponentProps<typeof FontAwesome>['name'] {
  switch (serviceType) {
    case 'lightbulb': return 'lightbulb-o';
    case 'switch': return 'power-off';
    case 'outlet': return 'plug';
    case 'lock': return 'lock';
    case 'fan': return 'snowflake-o';
    case 'thermostat':
    case 'heater_cooler': return 'thermometer';
    case 'motion_sensor': return 'male';
    case 'contact_sensor': return 'magnet';
    case 'temperature_sensor': return 'thermometer';
    case 'humidity_sensor': return 'tint';
    default: return 'cube';
  }
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.muted,
  },
  headerLeft: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  iconContainer: {
    width: 48,
    height: 48,
    borderRadius: 16,
    justifyContent: 'center',
    alignItems: 'center',
  },
  title: {
    fontSize: 18,
    fontWeight: '600',
    color: COLORS.foreground,
  },
  subtitle: {
    fontSize: 14,
    color: COLORS.mutedForeground,
    marginTop: 2,
  },
  closeButton: {
    padding: 8,
  },
  statusSection: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    padding: 16,
    backgroundColor: '#f8f9fa',
  },
  statusBadge: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 12,
  },
  statusText: {
    fontSize: 12,
    fontWeight: '600',
    color: '#fff',
  },
  categoryText: {
    fontSize: 14,
    color: COLORS.mutedForeground,
  },
  content: {
    flex: 1,
  },
  contentInner: {
    padding: 16,
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: COLORS.mutedForeground,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: 12,
  },
  characteristicRow: {
    backgroundColor: '#f8f9fa',
    borderRadius: 12,
    padding: 14,
    marginBottom: 8,
  },
  characteristicHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  characteristicName: {
    fontSize: 14,
    color: COLORS.foreground,
    fontWeight: '500',
  },
  characteristicValue: {
    fontSize: 14,
    color: COLORS.mutedForeground,
  },
  slider: {
    marginTop: 12,
    height: 40,
  },
  toggleButton: {
    marginTop: 12,
    paddingVertical: 10,
    borderRadius: 8,
    alignItems: 'center',
  },
  toggleText: {
    fontSize: 14,
    fontWeight: '600',
  },
  emptyText: {
    fontSize: 14,
    color: COLORS.mutedForeground,
    textAlign: 'center',
    marginTop: 24,
  },
});
