import React from 'react';
import { StyleSheet, View, TouchableOpacity, Animated } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';
import { Text } from '@/components/Themed';

interface LockControlProps {
  isLocked: boolean;
  onToggle: () => void;
  batteryLevel?: number;
  isJammed?: boolean;
}

export function LockControl({
  isLocked,
  onToggle,
  batteryLevel,
  isJammed,
}: LockControlProps) {
  const handlePress = () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
    onToggle();
  };

  const getStatusColor = () => {
    if (isJammed) return '#FF3B30';
    return isLocked ? '#0A84FF' : '#FF9500';
  };

  const getBatteryIcon = (): React.ComponentProps<typeof FontAwesome>['name'] => {
    if (!batteryLevel) return 'battery-full';
    if (batteryLevel > 75) return 'battery-full';
    if (batteryLevel > 50) return 'battery-three-quarters';
    if (batteryLevel > 25) return 'battery-half';
    if (batteryLevel > 10) return 'battery-quarter';
    return 'battery-empty';
  };

  const getBatteryColor = () => {
    if (!batteryLevel) return 'rgba(255,255,255,0.4)';
    if (batteryLevel > 20) return 'rgba(255,255,255,0.4)';
    return '#FF3B30';
  };

  return (
    <View style={styles.container}>
      {/* Status indicator */}
      <View style={styles.statusSection}>
        {isJammed && (
          <View style={styles.jammedBadge}>
            <FontAwesome name="exclamation-triangle" size={12} color="#fff" />
            <Text style={styles.jammedText}>Jammed</Text>
          </View>
        )}
        <Text style={[styles.statusText, { color: getStatusColor() }]}>
          {isJammed ? 'Error' : isLocked ? 'Locked' : 'Unlocked'}
        </Text>
      </View>

      {/* Main lock button */}
      <TouchableOpacity
        style={[
          styles.lockButton,
          { backgroundColor: getStatusColor() },
        ]}
        onPress={handlePress}
        activeOpacity={0.8}
        disabled={isJammed}
      >
        <View style={styles.lockIconContainer}>
          <FontAwesome
            name={isLocked ? 'lock' : 'unlock'}
            size={48}
            color="#fff"
          />
        </View>
      </TouchableOpacity>

      {/* Action hint */}
      <Text style={styles.hintText}>
        {isJammed ? 'Check lock mechanism' : isLocked ? 'Tap to unlock' : 'Tap to lock'}
      </Text>

      {/* Battery indicator */}
      {batteryLevel !== undefined && (
        <View style={styles.batteryContainer}>
          <FontAwesome
            name={getBatteryIcon()}
            size={14}
            color={getBatteryColor()}
          />
          <Text style={[styles.batteryText, { color: getBatteryColor() }]}>
            {batteryLevel}%
          </Text>
        </View>
      )}

      {/* Quick actions */}
      <View style={styles.actionsContainer}>
        <TouchableOpacity style={styles.actionButton}>
          <FontAwesome name="history" size={16} color="rgba(255,255,255,0.6)" />
          <Text style={styles.actionText}>History</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.actionButton}>
          <FontAwesome name="users" size={16} color="rgba(255,255,255,0.6)" />
          <Text style={styles.actionText}>Access</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    gap: 20,
  },
  statusSection: {
    alignItems: 'center',
    gap: 8,
  },
  jammedBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: '#FF3B30',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 12,
  },
  jammedText: {
    fontSize: 12,
    fontWeight: '600',
    color: '#fff',
  },
  statusText: {
    fontSize: 28,
    fontWeight: '600',
  },
  lockButton: {
    width: 140,
    height: 140,
    borderRadius: 70,
    justifyContent: 'center',
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 8,
    elevation: 8,
  },
  lockIconContainer: {
    width: 100,
    height: 100,
    borderRadius: 50,
    backgroundColor: 'rgba(255,255,255,0.15)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  hintText: {
    fontSize: 14,
    color: 'rgba(255,255,255,0.5)',
  },
  batteryContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 12,
    paddingVertical: 6,
    backgroundColor: 'rgba(80, 80, 80, 0.4)',
    borderRadius: 12,
  },
  batteryText: {
    fontSize: 13,
    fontWeight: '500',
  },
  actionsContainer: {
    flexDirection: 'row',
    gap: 12,
    marginTop: 8,
  },
  actionButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 14,
    paddingVertical: 10,
    backgroundColor: 'rgba(80, 80, 80, 0.4)',
    borderRadius: 16,
  },
  actionText: {
    fontSize: 13,
    color: 'rgba(255,255,255,0.6)',
  },
});
