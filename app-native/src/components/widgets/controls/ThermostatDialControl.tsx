import React, { useState, useEffect } from 'react';
import { StyleSheet, View, TouchableOpacity } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';
import { Text } from '@/components/Themed';

interface ThermostatDialControlProps {
  currentTemperature: number;
  targetTemperature: number;
  minTemp?: number;
  maxTemp?: number;
  mode: 'heat' | 'cool' | 'auto' | 'off';
  onTargetChange: (value: number) => void;
  onModeChange?: (mode: string) => void;
  // Optional fan controls
  fanSpeed?: number; // 0-100
  onFanSpeedChange?: (speed: number) => void;
  fanMode?: 'auto' | 'low' | 'medium' | 'high' | 'off';
  onFanModeChange?: (mode: string) => void;
  // Oscillating/swing
  isOscillating?: boolean;
  onOscillatingChange?: (oscillating: boolean) => void;
}

export function ThermostatDialControl({
  currentTemperature,
  targetTemperature,
  minTemp = 10,
  maxTemp = 30,
  mode,
  onTargetChange,
  onModeChange,
  fanSpeed,
  onFanSpeedChange,
  fanMode,
  onFanModeChange,
  isOscillating,
  onOscillatingChange,
}: ThermostatDialControlProps) {
  const [localTarget, setLocalTarget] = useState(targetTemperature);

  useEffect(() => {
    setLocalTarget(targetTemperature);
  }, [targetTemperature]);

  const handleIncrement = () => {
    const newTemp = Math.min(maxTemp, localTarget + 0.5);
    setLocalTarget(newTemp);
    onTargetChange(newTemp);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  };

  const handleDecrement = () => {
    const newTemp = Math.max(minTemp, localTarget - 0.5);
    setLocalTarget(newTemp);
    onTargetChange(newTemp);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  };

  // Get colors based on mode
  const getModeColor = () => {
    switch (mode) {
      case 'heat': return '#FF9500';
      case 'cool': return '#00B4D8';
      case 'auto': return '#BF5AF2';
      default: return 'rgba(100,100,100,0.8)';
    }
  };

  const getModeLabel = () => {
    switch (mode) {
      case 'heat': return 'Heating';
      case 'cool': return 'Cooling';
      case 'auto': return 'Auto';
      default: return 'Off';
    }
  };

  const getTargetLabel = () => {
    switch (mode) {
      case 'heat': return 'HEAT TO';
      case 'cool': return 'COOL TO';
      case 'auto': return 'SET TO';
      default: return 'TARGET';
    }
  };

  const modeColor = getModeColor();

  return (
    <View style={styles.container}>
      {/* Current temperature */}
      <View style={styles.currentTempContainer}>
        <Text style={styles.currentLabel}>CURRENT</Text>
        <Text style={styles.currentTemp}>{currentTemperature.toFixed(1)}°</Text>
      </View>

      {/* Target temperature control */}
      <View style={[styles.targetContainer, { borderColor: modeColor }]}>
        <Text style={styles.targetLabel}>{getTargetLabel()}</Text>

        <View style={styles.tempControl}>
          <TouchableOpacity
            style={styles.controlButton}
            onPress={handleDecrement}
            disabled={localTarget <= minTemp}
          >
            <FontAwesome
              name="minus"
              size={20}
              color={localTarget <= minTemp ? 'rgba(255,255,255,0.3)' : '#fff'}
            />
          </TouchableOpacity>

          <Text style={[styles.targetTemp, { color: mode === 'off' ? 'rgba(255,255,255,0.5)' : '#fff' }]}>
            {localTarget.toFixed(1)}°
          </Text>

          <TouchableOpacity
            style={styles.controlButton}
            onPress={handleIncrement}
            disabled={localTarget >= maxTemp}
          >
            <FontAwesome
              name="plus"
              size={20}
              color={localTarget >= maxTemp ? 'rgba(255,255,255,0.3)' : '#fff'}
            />
          </TouchableOpacity>
        </View>
      </View>

      {/* Mode selector */}
      {onModeChange && (
        <View style={styles.modeContainer}>
          {(['heat', 'cool', 'auto', 'off'] as const).map((m) => (
            <TouchableOpacity
              key={m}
              style={[
                styles.modeButton,
                mode === m && { backgroundColor: getModeColorForButton(m) },
              ]}
              onPress={() => {
                onModeChange(m);
                Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
              }}
            >
              <FontAwesome
                name={getModeIcon(m)}
                size={16}
                color={mode === m ? '#fff' : 'rgba(255,255,255,0.6)'}
              />
              <Text style={[
                styles.modeButtonText,
                mode === m && styles.modeButtonTextActive,
              ]}>
                {m.charAt(0).toUpperCase() + m.slice(1)}
              </Text>
            </TouchableOpacity>
          ))}
        </View>
      )}

      {/* Fan mode selector */}
      {onFanModeChange && (
        <View style={styles.fanSection}>
          <Text style={styles.sectionLabel}>FAN</Text>
          <View style={styles.fanModeContainer}>
            {(['auto', 'low', 'medium', 'high'] as const).map((fm) => (
              <TouchableOpacity
                key={fm}
                style={[
                  styles.fanModeButton,
                  fanMode === fm && styles.fanModeButtonActive,
                ]}
                onPress={() => {
                  onFanModeChange(fm);
                  Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
                }}
              >
                <FontAwesome
                  name={fm === 'auto' ? 'magic' : 'asterisk'}
                  size={12}
                  color={fanMode === fm ? '#fff' : 'rgba(255,255,255,0.5)'}
                />
                <Text style={[
                  styles.fanModeText,
                  fanMode === fm && styles.fanModeTextActive,
                ]}>
                  {fm.charAt(0).toUpperCase() + fm.slice(1)}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
        </View>
      )}

      {/* Oscillating toggle */}
      {onOscillatingChange && (
        <TouchableOpacity
          style={[
            styles.oscillatingButton,
            isOscillating && styles.oscillatingButtonActive,
          ]}
          onPress={() => {
            onOscillatingChange(!isOscillating);
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
          }}
        >
          <FontAwesome
            name="exchange"
            size={16}
            color={isOscillating ? '#fff' : 'rgba(255,255,255,0.5)'}
          />
          <Text style={[
            styles.oscillatingText,
            isOscillating && styles.oscillatingTextActive,
          ]}>
            Oscillate
          </Text>
        </TouchableOpacity>
      )}
    </View>
  );
}

function getModeIcon(mode: string): React.ComponentProps<typeof FontAwesome>['name'] {
  switch (mode) {
    case 'heat': return 'fire';
    case 'cool': return 'snowflake-o';
    case 'auto': return 'refresh';
    default: return 'power-off';
  }
}

function getModeColorForButton(mode: string): string {
  switch (mode) {
    case 'heat': return '#FF9500';
    case 'cool': return '#00B4D8';
    case 'auto': return '#BF5AF2';
    default: return 'rgba(100,100,100,0.8)';
  }
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    gap: 24,
  },
  currentTempContainer: {
    alignItems: 'center',
  },
  currentLabel: {
    fontSize: 12,
    fontWeight: '600',
    color: 'rgba(255,255,255,0.5)',
    letterSpacing: 1,
  },
  currentTemp: {
    fontSize: 32,
    fontWeight: '300',
    color: 'rgba(255,255,255,0.7)',
  },
  targetContainer: {
    alignItems: 'center',
    backgroundColor: 'rgba(80, 80, 80, 0.5)',
    borderRadius: 24,
    paddingVertical: 24,
    paddingHorizontal: 32,
    borderWidth: 2,
  },
  targetLabel: {
    fontSize: 13,
    fontWeight: '600',
    color: 'rgba(255,255,255,0.6)',
    letterSpacing: 1,
    marginBottom: 8,
  },
  tempControl: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 24,
  },
  controlButton: {
    width: 50,
    height: 50,
    borderRadius: 25,
    backgroundColor: 'rgba(100,100,100,0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  targetTemp: {
    fontSize: 48,
    fontWeight: '300',
    minWidth: 120,
    textAlign: 'center',
  },
  modeContainer: {
    flexDirection: 'row',
    gap: 8,
  },
  modeButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 16,
    backgroundColor: 'rgba(80, 80, 80, 0.5)',
  },
  modeButtonText: {
    fontSize: 13,
    color: 'rgba(255,255,255,0.6)',
  },
  modeButtonTextActive: {
    color: '#fff',
    fontWeight: '500',
  },
  fanSection: {
    alignItems: 'center',
    gap: 8,
  },
  sectionLabel: {
    fontSize: 11,
    fontWeight: '600',
    color: 'rgba(255,255,255,0.4)',
    letterSpacing: 1,
  },
  fanModeContainer: {
    flexDirection: 'row',
    gap: 6,
  },
  fanModeButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderRadius: 12,
    backgroundColor: 'rgba(80, 80, 80, 0.4)',
  },
  fanModeButtonActive: {
    backgroundColor: '#00B4D8',
  },
  fanModeText: {
    fontSize: 12,
    color: 'rgba(255,255,255,0.5)',
  },
  fanModeTextActive: {
    color: '#fff',
    fontWeight: '500',
  },
  oscillatingButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderRadius: 16,
    backgroundColor: 'rgba(80, 80, 80, 0.4)',
  },
  oscillatingButtonActive: {
    backgroundColor: '#BF5AF2',
  },
  oscillatingText: {
    fontSize: 14,
    color: 'rgba(255,255,255,0.5)',
  },
  oscillatingTextActive: {
    color: '#fff',
    fontWeight: '500',
  },
});
