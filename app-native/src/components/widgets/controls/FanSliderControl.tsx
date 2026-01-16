import React, { useRef, useEffect, useState } from 'react';
import { StyleSheet, View, TouchableOpacity } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';
import { Text } from '@/components/Themed';

const SLIDER_HEIGHT = 280;
const SLIDER_WIDTH = 100;

interface FanSliderControlProps {
  speed: number;
  isOn: boolean;
  onSpeedChange: (value: number) => void;
  onSpeedChangeLive?: (value: number) => void;
  onToggle: () => void;
}

const THROTTLE_INTERVAL = 250; // Store sync interval during drag

export function FanSliderControl({
  speed,
  isOn,
  onSpeedChange,
  onSpeedChangeLive,
  onToggle,
}: FanSliderControlProps) {
  // Use state for display - React controls the value
  const [displaySpeed, setDisplaySpeed] = useState(speed);

  // Refs for tracking during drag
  const isDragging = useRef(false);
  const lastHapticRef = useRef(speed);
  const lastThrottledUpdate = useRef(0);
  const lastSentSpeed = useRef(speed);
  const layoutRef = useRef({ y: 0 });

  // Sync from props when not dragging
  useEffect(() => {
    if (!isDragging.current) {
      setDisplaySpeed(speed);
      lastSentSpeed.current = speed;
      lastThrottledUpdate.current = 0;
    }
  }, [speed]);

  const calculateSpeed = (pageY: number, layoutY: number) => {
    const relativeY = pageY - layoutY;
    const touchY = Math.max(0, Math.min(SLIDER_HEIGHT, SLIDER_HEIGHT - relativeY + 30));
    return Math.round((touchY / SLIDER_HEIGHT) * 100);
  };

  const handleTouchStart = (e: any) => {
    isDragging.current = true;
    const pageY = e.nativeEvent.pageY;
    const newSpeed = calculateSpeed(pageY, layoutRef.current.y);
    setDisplaySpeed(newSpeed);
    lastHapticRef.current = newSpeed;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  };

  const handleTouchMove = (e: any) => {
    if (!isDragging.current) return;
    const pageY = e.nativeEvent.pageY;
    const newSpeed = calculateSpeed(pageY, layoutRef.current.y);

    // Update local state immediately for responsive UI
    setDisplaySpeed(newSpeed);

    // Haptic at 10% intervals
    const currentTen = Math.floor(newSpeed / 10);
    const lastTen = Math.floor(lastHapticRef.current / 10);
    if (currentTen !== lastTen) {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      lastHapticRef.current = newSpeed;
    }

    // Throttled store sync (doesn't affect local UI - isDragging prevents prop sync)
    if (onSpeedChangeLive) {
      const now = Date.now();
      if (now - lastThrottledUpdate.current >= THROTTLE_INTERVAL && newSpeed !== lastSentSpeed.current) {
        lastThrottledUpdate.current = now;
        lastSentSpeed.current = newSpeed;
        onSpeedChangeLive(newSpeed);
      }
    }
  };

  const handleTouchEnd = () => {
    if (!isDragging.current) return;
    isDragging.current = false;
    const finalSpeed = displaySpeed;
    if (finalSpeed !== lastSentSpeed.current) {
      onSpeedChange(finalSpeed);
    }
    lastSentSpeed.current = finalSpeed;
    if (!isOn && finalSpeed > 0) {
      onToggle();
    }
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
  };

  const getSpeedLevel = () => {
    if (!isOn || displaySpeed === 0) return 'Off';
    if (displaySpeed <= 33) return 'Low';
    if (displaySpeed <= 66) return 'Medium';
    return 'High';
  };

  const fillHeight = isOn ? (displaySpeed / 100) * SLIDER_HEIGHT : 0;

  return (
    <View style={styles.container}>
      <Text style={styles.speedLevel}>{getSpeedLevel()}</Text>

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
          style={[styles.sliderFill, { height: fillHeight }]}
        />
        <TouchableOpacity
          style={[styles.iconButton, isOn && styles.iconButtonOn]}
          onPress={onToggle}
          activeOpacity={0.8}
        >
          <FontAwesome name="snowflake-o" size={24} color={isOn ? '#333' : '#fff'} />
        </TouchableOpacity>
      </View>

      <Text style={styles.speedPercent}>{isOn ? `${displaySpeed}%` : 'Off'}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    gap: 16,
  },
  speedLevel: {
    fontSize: 16,
    fontWeight: '500',
    color: 'rgba(255,255,255,0.7)',
  },
  sliderTrack: {
    width: SLIDER_WIDTH,
    height: SLIDER_HEIGHT,
    backgroundColor: 'rgba(80, 80, 80, 0.7)',
    borderRadius: 50,
    justifyContent: 'flex-end',
    alignItems: 'center',
    overflow: 'hidden',
  },
  sliderFill: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    backgroundColor: '#64D2FF',
    borderTopLeftRadius: 40,
    borderTopRightRadius: 40,
  },
  iconButton: {
    width: 60,
    height: 60,
    borderRadius: 30,
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 10,
    backgroundColor: 'rgba(100,100,100,0.5)',
  },
  iconButtonOn: {
    backgroundColor: '#64D2FF',
  },
  speedPercent: {
    fontSize: 14,
    color: 'rgba(255,255,255,0.5)',
  },
});
