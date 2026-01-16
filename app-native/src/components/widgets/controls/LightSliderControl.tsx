import React, { useRef, useEffect, useState } from 'react';
import { StyleSheet, View, TouchableOpacity } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';
import { Text } from '@/components/Themed';

const SLIDER_HEIGHT = 280;
const SLIDER_WIDTH = 100;
const BORDER_RADIUS = 50;

// Color temperature presets (in Mireds - higher = warmer)
// Typical Hue range: 153 (6500K daylight) to 500 (2000K warm)
const COLOR_TEMPS = [
  { color: '#FF9500', temp: 454, label: 'Warm' },      // ~2200K
  { color: '#FFD700', temp: 370, label: 'Neutral' },   // ~2700K
  { color: '#FFFAF0', temp: 285, label: 'Cool' },      // ~3500K
  { color: '#F0F8FF', temp: 200, label: 'Daylight' },  // ~5000K
];

// Hue color presets (full saturation)
const HUE_COLORS = [
  { color: '#FF0000', hue: 0 },
  { color: '#FF7F00', hue: 30 },
  { color: '#FFFF00', hue: 60 },
  { color: '#00FF00', hue: 120 },
  { color: '#00FFFF', hue: 180 },
  { color: '#0000FF', hue: 240 },
  { color: '#8B00FF', hue: 270 },
  { color: '#FF00FF', hue: 300 },
];

interface LightSliderControlProps {
  brightness: number;
  isOn: boolean;
  colorTemperature?: number;
  hue?: number;
  saturation?: number;
  onBrightnessChange: (value: number) => void;
  onBrightnessChangeLive?: (value: number) => void;
  onToggle: () => void;
  onColorTemperatureChange?: (value: number) => void;
  onHueChange?: (hue: number) => void;
  onSaturationChange?: (saturation: number) => void;
}

const THROTTLE_INTERVAL = 250; // Store sync interval during drag

// Convert HSV to RGB hex
function hsvToHex(h: number, s: number, v: number): string {
  const c = v * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = v - c;
  let r = 0, g = 0, b = 0;

  if (h < 60) { r = c; g = x; b = 0; }
  else if (h < 120) { r = x; g = c; b = 0; }
  else if (h < 180) { r = 0; g = c; b = x; }
  else if (h < 240) { r = 0; g = x; b = c; }
  else if (h < 300) { r = x; g = 0; b = c; }
  else { r = c; g = 0; b = x; }

  const toHex = (n: number) => Math.round((n + m) * 255).toString(16).padStart(2, '0');
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

export function LightSliderControl({
  brightness,
  isOn,
  colorTemperature,
  hue,
  saturation = 100,
  onBrightnessChange,
  onBrightnessChangeLive,
  onToggle,
  onColorTemperatureChange,
  onHueChange,
  onSaturationChange,
}: LightSliderControlProps) {
  const [displayBrightness, setDisplayBrightness] = useState(brightness);
  const [selectedTempIndex, setSelectedTempIndex] = useState(0);
  const [selectedHue, setSelectedHue] = useState(hue ?? 0);
  const [colorMode, setColorMode] = useState<'temp' | 'color'>(hue !== undefined ? 'color' : 'temp');

  const isDragging = useRef(false);
  const lastHapticRef = useRef(brightness);
  const lastThrottledUpdate = useRef(0);
  const lastSentBrightness = useRef(brightness);
  const layoutRef = useRef({ y: 0 });

  // Sync from props when not dragging
  useEffect(() => {
    if (!isDragging.current) {
      setDisplayBrightness(brightness);
      lastSentBrightness.current = brightness;
      lastThrottledUpdate.current = 0;
    }
  }, [brightness]);

  // Sync color temp
  useEffect(() => {
    if (colorTemperature) {
      const closest = COLOR_TEMPS.reduce((prev, curr, index) => {
        return Math.abs(curr.temp - colorTemperature) < Math.abs(COLOR_TEMPS[prev].temp - colorTemperature)
          ? index : prev;
      }, 0);
      setSelectedTempIndex(closest);
    }
  }, [colorTemperature]);

  // Sync hue
  useEffect(() => {
    if (hue !== undefined) {
      setSelectedHue(hue);
      setColorMode('color');
    }
  }, [hue]);

  const calculateBrightness = (pageY: number, layoutY: number) => {
    const relativeY = pageY - layoutY;
    const touchY = Math.max(0, Math.min(SLIDER_HEIGHT, SLIDER_HEIGHT - relativeY + 30));
    return Math.round((touchY / SLIDER_HEIGHT) * 100);
  };

  const handleTouchStart = (e: any) => {
    isDragging.current = true;
    const pageY = e.nativeEvent.pageY;
    const newBrightness = calculateBrightness(pageY, layoutRef.current.y);
    setDisplayBrightness(newBrightness);
    lastHapticRef.current = newBrightness;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  };

  const handleTouchMove = (e: any) => {
    if (!isDragging.current) return;
    const pageY = e.nativeEvent.pageY;
    const newBrightness = calculateBrightness(pageY, layoutRef.current.y);

    // Update local state immediately for responsive UI
    setDisplayBrightness(newBrightness);

    // Haptic feedback every 10%
    const currentTen = Math.floor(newBrightness / 10);
    const lastTen = Math.floor(lastHapticRef.current / 10);
    if (currentTen !== lastTen) {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      lastHapticRef.current = newBrightness;
    }

    // Throttled store sync (doesn't affect local UI - isDragging prevents prop sync)
    if (onBrightnessChangeLive) {
      const now = Date.now();
      if (now - lastThrottledUpdate.current >= THROTTLE_INTERVAL && newBrightness !== lastSentBrightness.current) {
        lastThrottledUpdate.current = now;
        lastSentBrightness.current = newBrightness;
        onBrightnessChangeLive(newBrightness);
      }
    }
  };

  const handleTouchEnd = () => {
    if (!isDragging.current) return;
    isDragging.current = false;
    const finalBrightness = displayBrightness;
    if (finalBrightness !== lastSentBrightness.current) {
      onBrightnessChange(finalBrightness);
    }
    lastSentBrightness.current = finalBrightness;
    if (!isOn && finalBrightness > 0) {
      onToggle();
    }
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
  };

  // Get fill color based on mode
  const getFillColor = () => {
    if (!isOn) return 'rgba(255,255,255,0.15)';
    if (colorMode === 'color') {
      return hsvToHex(selectedHue, saturation / 100, 1);
    }
    return COLOR_TEMPS[selectedTempIndex].color;
  };

  const fillColor = getFillColor();
  const fillHeight = isOn ? (displayBrightness / 100) * SLIDER_HEIGHT : 0;

  const handleTempSelect = (index: number) => {
    setSelectedTempIndex(index);
    setColorMode('temp');
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    onColorTemperatureChange?.(COLOR_TEMPS[index].temp);
  };

  const handleHueSelect = (hueValue: number) => {
    setSelectedHue(hueValue);
    setColorMode('color');
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    onHueChange?.(hueValue);
    // Set full saturation when selecting a color
    if (saturation < 50) {
      onSaturationChange?.(100);
    }
  };

  const hasColorControls = onColorTemperatureChange || onHueChange;

  return (
    <View style={styles.container}>
      {/* Brightness percentage */}
      <Text style={styles.brightnessText}>
        {isOn ? `${displayBrightness}%` : 'Off'}
      </Text>

      {/* Slider */}
      <View
        style={styles.sliderTrack}
        onLayout={(e) => {
          e.target.measure?.((x, y, width, height, pageX, pageY) => {
            layoutRef.current.y = pageY;
          });
        }}
        onStartShouldSetResponder={() => true}
        onMoveShouldSetResponder={() => true}
        onResponderGrant={handleTouchStart}
        onResponderMove={handleTouchMove}
        onResponderRelease={handleTouchEnd}
        onResponderTerminate={handleTouchEnd}
      >
        <View
          style={[
            styles.sliderFill,
            {
              height: fillHeight,
              backgroundColor: fillColor,
            },
          ]}
        />
        <TouchableOpacity
          style={[styles.iconButton, { backgroundColor: isOn ? fillColor : 'rgba(100,100,100,0.5)' }]}
          onPress={onToggle}
          activeOpacity={0.8}
        >
          <FontAwesome name="lightbulb-o" size={24} color={isOn ? '#333' : '#fff'} />
        </TouchableOpacity>
      </View>

      {/* Color controls */}
      {hasColorControls && (
        <View style={styles.colorControls}>
          {/* Color temperature row */}
          {onColorTemperatureChange && (
            <View style={styles.colorSection}>
              <Text style={styles.colorLabel}>Temperature</Text>
              <View style={styles.colorRow}>
                {COLOR_TEMPS.map((item, index) => (
                  <TouchableOpacity
                    key={`temp-${index}`}
                    onPress={() => handleTempSelect(index)}
                    style={[
                      styles.colorCircle,
                      { backgroundColor: item.color },
                      colorMode === 'temp' && selectedTempIndex === index && styles.colorCircleSelected,
                    ]}
                  />
                ))}
              </View>
            </View>
          )}

          {/* Hue color row */}
          {onHueChange && (
            <View style={styles.colorSection}>
              <Text style={styles.colorLabel}>Color</Text>
              <View style={styles.colorRow}>
                {HUE_COLORS.map((item, index) => (
                  <TouchableOpacity
                    key={`hue-${index}`}
                    onPress={() => handleHueSelect(item.hue)}
                    style={[
                      styles.colorCircleSmall,
                      { backgroundColor: item.color },
                      colorMode === 'color' && Math.abs(selectedHue - item.hue) < 15 && styles.colorCircleSelected,
                    ]}
                  />
                ))}
              </View>
            </View>
          )}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    gap: 16,
  },
  brightnessText: {
    fontSize: 18,
    fontWeight: '500',
    color: 'rgba(255,255,255,0.7)',
  },
  sliderTrack: {
    width: SLIDER_WIDTH,
    height: SLIDER_HEIGHT,
    backgroundColor: 'rgba(80, 80, 80, 0.7)',
    borderRadius: BORDER_RADIUS,
    justifyContent: 'flex-end',
    alignItems: 'center',
    overflow: 'hidden',
  },
  sliderFill: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
  },
  iconButton: {
    width: 60,
    height: 60,
    borderRadius: 30,
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 10,
  },
  colorControls: {
    gap: 16,
    alignItems: 'center',
  },
  colorSection: {
    alignItems: 'center',
    gap: 8,
  },
  colorLabel: {
    fontSize: 12,
    color: 'rgba(255,255,255,0.5)',
    textTransform: 'uppercase',
    letterSpacing: 1,
  },
  colorRow: {
    flexDirection: 'row',
    gap: 10,
  },
  colorCircle: {
    width: 36,
    height: 36,
    borderRadius: 18,
    borderWidth: 2,
    borderColor: 'transparent',
  },
  colorCircleSmall: {
    width: 28,
    height: 28,
    borderRadius: 14,
    borderWidth: 2,
    borderColor: 'transparent',
  },
  colorCircleSelected: {
    borderColor: '#fff',
    transform: [{ scale: 1.15 }],
  },
});
