import React from 'react';
import {
  StyleSheet,
  View,
  TouchableOpacity,
  Modal,
  TouchableWithoutFeedback,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { CrossPlatformBlur } from '@/components/CrossPlatformBlur';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import { Text } from '@/components/Themed';
import { LightSliderControl, ThermostatDialControl, SimpleToggleControl, FanSliderControl, LockControl, BlindsControl } from './controls';
import type { Accessory } from '@/types/homekit';
import type { ServiceType } from './types';
import { getDisplayName } from './types';

interface DeviceControlModalProps {
  visible: boolean;
  accessory: Accessory | null;
  serviceType: ServiceType | null;
  isOn: boolean;
  // Light props
  brightness?: number;
  colorTemperature?: number;
  hue?: number;
  saturation?: number;
  onBrightnessChange?: (value: number) => void;
  onBrightnessChangeLive?: (value: number) => void;
  onColorTemperatureChange?: (value: number) => void;
  onHueChange?: (value: number) => void;
  onSaturationChange?: (value: number) => void;
  // Thermostat props
  currentTemperature?: number;
  targetTemperature?: number;
  thermostatMode?: 'heat' | 'cool' | 'auto' | 'off';
  onTargetTemperatureChange?: (value: number) => void;
  onModeChange?: (mode: string) => void;
  thermostatFanMode?: 'auto' | 'low' | 'medium' | 'high' | 'off';
  onThermostatFanModeChange?: (mode: string) => void;
  isOscillating?: boolean;
  onOscillatingChange?: (oscillating: boolean) => void;
  // Fan props
  fanSpeed?: number;
  onFanSpeedChange?: (value: number) => void;
  onFanSpeedChangeLive?: (value: number) => void;
  // Lock props
  batteryLevel?: number;
  isJammed?: boolean;
  // Blinds props
  blindsPosition?: number;
  blindsTilt?: number;
  onBlindsPositionChange?: (value: number) => void;
  onBlindsPositionChangeLive?: (value: number) => void;
  onBlindsTiltChange?: (value: number) => void;
  // Common
  onClose: () => void;
  onToggle: () => void;
}

export function DeviceControlModal({
  visible,
  accessory,
  serviceType,
  isOn,
  brightness,
  colorTemperature,
  hue,
  saturation,
  onBrightnessChange,
  onBrightnessChangeLive,
  onColorTemperatureChange,
  onHueChange,
  onSaturationChange,
  currentTemperature,
  targetTemperature,
  thermostatMode,
  onTargetTemperatureChange,
  onModeChange,
  thermostatFanMode,
  onThermostatFanModeChange,
  isOscillating,
  onOscillatingChange,
  fanSpeed,
  onFanSpeedChange,
  onFanSpeedChangeLive,
  batteryLevel,
  isJammed,
  blindsPosition,
  blindsTilt,
  onBlindsPositionChange,
  onBlindsPositionChangeLive,
  onBlindsTiltChange,
  onClose,
  onToggle,
}: DeviceControlModalProps) {
  const insets = useSafeAreaInsets();

  if (!accessory) return null;

  const getSubtitle = () => {
    if (!accessory.isReachable) return 'Unreachable';
    switch (serviceType) {
      case 'lightbulb':
        if (!isOn) return 'Off';
        return brightness !== undefined ? `${brightness}%` : 'On';
      case 'thermostat':
      case 'heater_cooler':
        if (currentTemperature !== undefined) {
          return `Current ${currentTemperature.toFixed(1)}°`;
        }
        return isOn ? 'On' : 'Off';
      case 'fan':
        if (!isOn) return 'Off';
        return fanSpeed !== undefined ? `${fanSpeed}%` : 'On';
      case 'lock':
        if (isJammed) return 'Jammed';
        return isOn ? 'Locked' : 'Unlocked';
      case 'window_covering':
        if (blindsPosition === 0) return 'Closed';
        if (blindsPosition === 100) return 'Open';
        return blindsPosition !== undefined ? `${blindsPosition}%` : 'Unknown';
      default:
        return isOn ? 'On' : 'Off';
    }
  };

  const renderControl = () => {
    switch (serviceType) {
      case 'lightbulb':
        return (
          <LightSliderControl
            key={accessory?.id}
            brightness={brightness ?? 100}
            isOn={isOn}
            colorTemperature={colorTemperature}
            hue={hue}
            saturation={saturation}
            onBrightnessChange={onBrightnessChange ?? (() => {})}
            onBrightnessChangeLive={onBrightnessChangeLive}
            onToggle={onToggle}
            onColorTemperatureChange={onColorTemperatureChange}
            onHueChange={onHueChange}
            onSaturationChange={onSaturationChange}
          />
        );
      case 'thermostat':
      case 'heater_cooler':
        return (
          <ThermostatDialControl
            currentTemperature={currentTemperature ?? 20}
            targetTemperature={targetTemperature ?? 21}
            mode={thermostatMode ?? 'heat'}
            onTargetChange={onTargetTemperatureChange ?? (() => {})}
            onModeChange={onModeChange}
            fanMode={thermostatFanMode}
            onFanModeChange={onThermostatFanModeChange}
            isOscillating={isOscillating}
            onOscillatingChange={onOscillatingChange}
          />
        );
      case 'fan':
        return (
          <FanSliderControl
            speed={fanSpeed ?? 50}
            isOn={isOn}
            onSpeedChange={onFanSpeedChange ?? (() => {})}
            onSpeedChangeLive={onFanSpeedChangeLive}
            onToggle={onToggle}
          />
        );
      case 'lock':
        return (
          <LockControl
            isLocked={isOn}
            onToggle={onToggle}
            batteryLevel={batteryLevel}
            isJammed={isJammed}
          />
        );
      case 'window_covering':
        return (
          <BlindsControl
            position={blindsPosition ?? 0}
            tiltAngle={blindsTilt}
            onPositionChange={onBlindsPositionChange ?? (() => {})}
            onPositionChangeLive={onBlindsPositionChangeLive}
            onTiltChange={onBlindsTiltChange}
          />
        );
      case 'switch':
      case 'outlet':
      default:
        return (
          <SimpleToggleControl
            isOn={isOn}
            serviceType={serviceType}
            onToggle={onToggle}
          />
        );
    }
  };

  return (
    <Modal
      visible={visible}
      transparent
      animationType="fade"
      onRequestClose={onClose}
    >
      <CrossPlatformBlur intensity={60} tint="dark" overlayColor="rgba(0,0,0,0.4)" style={styles.container}>
        {/* Full screen backdrop - tapping closes modal */}
        <TouchableWithoutFeedback onPress={onClose}>
          <View style={StyleSheet.absoluteFill} />
        </TouchableWithoutFeedback>

        {/* Content layer - positioned above backdrop */}
        <View style={[styles.contentLayer, { paddingTop: insets.top + 60 }]} pointerEvents="box-none">
          {/* Header - passes through to backdrop */}
          <View style={styles.header} pointerEvents="none">
            <Text style={styles.deviceName}>{getDisplayName(accessory)}</Text>
            <Text style={styles.deviceStatus}>{getSubtitle()}</Text>
          </View>

          {/* Control wrapper - blocks backdrop touches */}
          <View style={styles.controlWrapper}>
            {visible && renderControl()}
          </View>

          {/* Settings button */}
          <View style={[styles.footer, { paddingBottom: insets.bottom + 20 }]}>
            <TouchableOpacity
              style={styles.settingsButton}
              activeOpacity={0.7}
            >
              <FontAwesome name="cog" size={22} color="rgba(255,255,255,0.9)" />
            </TouchableOpacity>
          </View>
        </View>
      </CrossPlatformBlur>
    </Modal>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  contentLayer: {
    ...StyleSheet.absoluteFillObject,
  },
  header: {
    alignItems: 'center',
    paddingHorizontal: 20,
    marginBottom: 20,
  },
  deviceName: {
    fontSize: 28,
    fontWeight: '600',
    color: '#FFFFFF',
    textAlign: 'center',
  },
  deviceStatus: {
    fontSize: 18,
    color: 'rgba(255,255,255,0.6)',
    marginTop: 4,
  },
  controlWrapper: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  footer: {
    alignItems: 'flex-end',
    paddingHorizontal: 20,
  },
  settingsButton: {
    width: 50,
    height: 50,
    borderRadius: 25,
    backgroundColor: 'rgba(120, 120, 120, 0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
});
