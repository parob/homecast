import React, { useState, useRef, useEffect } from 'react';
import { StyleSheet, View, TouchableOpacity } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';
import { Text } from '@/components/Themed';

const SLIDER_HEIGHT = 260;
const SLIDER_WIDTH = 90;

interface BlindsControlProps {
  position: number; // 0 = closed, 100 = open
  tiltAngle?: number; // -90 to 90
  onPositionChange: (value: number) => void;
  onPositionChangeLive?: (value: number) => void;
  onTiltChange?: (value: number) => void;
}

export function BlindsControl({
  position,
  tiltAngle = 0,
  onPositionChange,
  onPositionChangeLive,
  onTiltChange,
}: BlindsControlProps) {
  const [displayPosition, setDisplayPosition] = useState(position);
  const [localTilt, setLocalTilt] = useState(tiltAngle);
  const isDragging = useRef(false);
  const lastHapticRef = useRef(position);
  const layoutRef = useRef({ y: 0 });

  useEffect(() => {
    if (!isDragging.current) {
      setDisplayPosition(position);
    }
  }, [position]);

  useEffect(() => {
    setLocalTilt(tiltAngle);
  }, [tiltAngle]);

  const calculatePosition = (pageY: number, layoutY: number) => {
    const relativeY = pageY - layoutY;
    const touchY = Math.max(0, Math.min(SLIDER_HEIGHT, SLIDER_HEIGHT - relativeY + 30));
    return Math.round((touchY / SLIDER_HEIGHT) * 100);
  };

  const handleTouchStart = (e: any) => {
    isDragging.current = true;
    const pageY = e.nativeEvent.pageY;
    const newPosition = calculatePosition(pageY, layoutRef.current.y);
    setDisplayPosition(newPosition);
    lastHapticRef.current = newPosition;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  };

  const handleTouchMove = (e: any) => {
    if (!isDragging.current) return;
    const pageY = e.nativeEvent.pageY;
    const newPosition = calculatePosition(pageY, layoutRef.current.y);
    setDisplayPosition(newPosition);

    const currentTen = Math.floor(newPosition / 10);
    const lastTen = Math.floor(lastHapticRef.current / 10);
    if (currentTen !== lastTen) {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      lastHapticRef.current = newPosition;
    }

    if (onPositionChangeLive) {
      onPositionChangeLive(newPosition);
    }
  };

  const handleTouchEnd = () => {
    if (!isDragging.current) return;
    isDragging.current = false;
    onPositionChange(displayPosition);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
  };

  const handlePreset = (value: number) => {
    setDisplayPosition(value);
    onPositionChange(value);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
  };

  const handleTiltPreset = (value: number) => {
    setLocalTilt(value);
    onTiltChange?.(value);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  };

  const getPositionLabel = () => {
    if (displayPosition === 0) return 'Closed';
    if (displayPosition === 100) return 'Open';
    return `${displayPosition}%`;
  };

  const fillHeight = (displayPosition / 100) * SLIDER_HEIGHT;

  return (
    <View style={styles.container}>
      {/* Position label */}
      <Text style={styles.positionText}>{getPositionLabel()}</Text>

      {/* Main slider */}
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
        {/* Blinds visualization */}
        <View style={styles.blindsContainer}>
          {[...Array(10)].map((_, i) => (
            <View
              key={i}
              style={[
                styles.blindSlat,
                {
                  opacity: i < Math.floor((100 - displayPosition) / 10) ? 1 : 0.2,
                  transform: [{ rotateX: `${localTilt}deg` }],
                },
              ]}
            />
          ))}
        </View>

        {/* Fill indicator */}
        <View
          style={[
            styles.sliderFill,
            { height: fillHeight },
          ]}
        />

        {/* Icon button */}
        <TouchableOpacity
          style={styles.iconButton}
          activeOpacity={0.8}
        >
          <FontAwesome name="arrows-v" size={20} color="#fff" />
        </TouchableOpacity>
      </View>

      {/* Position presets */}
      <View style={styles.presetsContainer}>
        <TouchableOpacity
          style={[styles.presetButton, displayPosition === 0 && styles.presetButtonActive]}
          onPress={() => handlePreset(0)}
        >
          <FontAwesome name="compress" size={14} color={displayPosition === 0 ? '#fff' : 'rgba(255,255,255,0.6)'} />
          <Text style={[styles.presetText, displayPosition === 0 && styles.presetTextActive]}>Close</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.presetButton, displayPosition === 50 && styles.presetButtonActive]}
          onPress={() => handlePreset(50)}
        >
          <FontAwesome name="minus" size={14} color={displayPosition === 50 ? '#fff' : 'rgba(255,255,255,0.6)'} />
          <Text style={[styles.presetText, displayPosition === 50 && styles.presetTextActive]}>Half</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.presetButton, displayPosition === 100 && styles.presetButtonActive]}
          onPress={() => handlePreset(100)}
        >
          <FontAwesome name="expand" size={14} color={displayPosition === 100 ? '#fff' : 'rgba(255,255,255,0.6)'} />
          <Text style={[styles.presetText, displayPosition === 100 && styles.presetTextActive]}>Open</Text>
        </TouchableOpacity>
      </View>

      {/* Tilt controls */}
      {onTiltChange && (
        <View style={styles.tiltSection}>
          <Text style={styles.sectionLabel}>TILT</Text>
          <View style={styles.tiltContainer}>
            <TouchableOpacity
              style={[styles.tiltButton, localTilt === -45 && styles.tiltButtonActive]}
              onPress={() => handleTiltPreset(-45)}
            >
              <FontAwesome name="angle-double-left" size={16} color={localTilt === -45 ? '#fff' : 'rgba(255,255,255,0.6)'} />
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.tiltButton, localTilt === 0 && styles.tiltButtonActive]}
              onPress={() => handleTiltPreset(0)}
            >
              <FontAwesome name="minus" size={16} color={localTilt === 0 ? '#fff' : 'rgba(255,255,255,0.6)'} />
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.tiltButton, localTilt === 45 && styles.tiltButtonActive]}
              onPress={() => handleTiltPreset(45)}
            >
              <FontAwesome name="angle-double-right" size={16} color={localTilt === 45 ? '#fff' : 'rgba(255,255,255,0.6)'} />
            </TouchableOpacity>
          </View>
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
  positionText: {
    fontSize: 18,
    fontWeight: '500',
    color: 'rgba(255,255,255,0.7)',
  },
  sliderTrack: {
    width: SLIDER_WIDTH,
    height: SLIDER_HEIGHT,
    backgroundColor: 'rgba(80, 80, 80, 0.7)',
    borderRadius: 45,
    justifyContent: 'flex-end',
    alignItems: 'center',
    overflow: 'hidden',
  },
  blindsContainer: {
    position: 'absolute',
    top: 20,
    left: 15,
    right: 15,
    bottom: 70,
    justifyContent: 'space-evenly',
  },
  blindSlat: {
    height: 12,
    backgroundColor: 'rgba(255,255,255,0.3)',
    borderRadius: 2,
  },
  sliderFill: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    backgroundColor: 'rgba(255,204,0,0.4)',
  },
  iconButton: {
    width: 50,
    height: 50,
    borderRadius: 25,
    backgroundColor: 'rgba(100,100,100,0.6)',
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 10,
  },
  presetsContainer: {
    flexDirection: 'row',
    gap: 8,
  },
  presetButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: 16,
    backgroundColor: 'rgba(80, 80, 80, 0.5)',
  },
  presetButtonActive: {
    backgroundColor: '#FFCC00',
  },
  presetText: {
    fontSize: 13,
    color: 'rgba(255,255,255,0.6)',
  },
  presetTextActive: {
    color: '#333',
    fontWeight: '500',
  },
  tiltSection: {
    alignItems: 'center',
    gap: 8,
  },
  sectionLabel: {
    fontSize: 11,
    fontWeight: '600',
    color: 'rgba(255,255,255,0.4)',
    letterSpacing: 1,
  },
  tiltContainer: {
    flexDirection: 'row',
    gap: 8,
  },
  tiltButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: 'rgba(80, 80, 80, 0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  tiltButtonActive: {
    backgroundColor: '#FFCC00',
  },
});
