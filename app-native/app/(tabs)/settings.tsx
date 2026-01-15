import { StyleSheet, TouchableOpacity, ScrollView, Alert, Platform, View } from 'react-native';
import { useQuery } from '@apollo/client/react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { Text } from '@/components/Themed';
import { useAuth } from '@/providers/AuthProvider';
import { ME_QUERY, DEVICES_QUERY } from '@/api/graphql/queries';
import type { UserInfo, DeviceInfo } from '@/types/api';

export default function SettingsScreen() {
  const { logout, email } = useAuth();
  const { data: meData } = useQuery<{ me: UserInfo }>(ME_QUERY);
  const { data: devicesData } = useQuery<{ devices: DeviceInfo[] }>(DEVICES_QUERY);

  const user = meData?.me;
  const devices = devicesData?.devices || [];
  const macDevices = devices.filter((d) => d.sessionType === 'device');

  const handleLogout = () => {
    Alert.alert('Log Out', 'Are you sure you want to log out?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Log Out', style: 'destructive', onPress: logout },
    ]);
  };

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      {/* Account Section */}
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>ACCOUNT</Text>
        <View style={styles.card}>
          <View style={styles.row}>
            <View style={styles.avatar}>
              <FontAwesome name="user" size={24} color="#fff" />
            </View>
            <View style={styles.rowContent}>
              <Text style={styles.rowTitle}>{user?.name || 'User'}</Text>
              <Text style={styles.rowSubtitle}>{email}</Text>
            </View>
          </View>
        </View>
      </View>

      {/* Devices Section */}
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>CONNECTED DEVICES</Text>
        <View style={styles.card}>
          {macDevices.length === 0 ? (
            <View style={styles.row}>
              <FontAwesome name="laptop" size={20} color="#666" />
              <Text style={styles.emptyText}>No Mac apps connected</Text>
            </View>
          ) : (
            macDevices.map((device, index) => (
              <View
                key={device.id}
                style={[styles.row, index > 0 && styles.rowBorder]}
              >
                <FontAwesome name="laptop" size={20} color="#007AFF" />
                <View style={styles.rowContent}>
                  <Text style={styles.rowTitle}>{device.name || 'Mac'}</Text>
                  <Text style={styles.rowSubtitle}>
                    Last seen: {device.lastSeenAt ? new Date(device.lastSeenAt).toLocaleString() : 'Unknown'}
                  </Text>
                </View>
              </View>
            ))
          )}
        </View>
      </View>

      {/* HomeKit Section (iOS only) */}
      {Platform.OS === 'ios' && (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>LOCAL HOMEKIT</Text>
          <View style={styles.card}>
            <View style={styles.row}>
              <FontAwesome name="home" size={20} color="#FF9500" />
              <View style={styles.rowContent}>
                <Text style={styles.rowTitle}>Direct Control</Text>
                <Text style={styles.rowSubtitle}>
                  Control devices directly via HomeKit (coming soon)
                </Text>
              </View>
            </View>
          </View>
        </View>
      )}

      {/* App Info Section */}
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>APP</Text>
        <View style={styles.card}>
          <View style={styles.row}>
            <FontAwesome name="info-circle" size={20} color="#666" />
            <View style={styles.rowContent}>
              <Text style={styles.rowTitle}>Version</Text>
              <Text style={styles.rowSubtitle}>1.0.0</Text>
            </View>
          </View>
        </View>
      </View>

      {/* Logout Button */}
      <TouchableOpacity style={styles.logoutButton} onPress={handleLogout}>
        <FontAwesome name="sign-out" size={18} color="#FF3B30" />
        <Text style={styles.logoutText}>Log Out</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f2f2f7',
  },
  content: {
    padding: 16,
  },
  section: {
    marginBottom: 24,
    backgroundColor: 'transparent',
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: '#888',
    marginBottom: 8,
    marginLeft: 4,
  },
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    overflow: 'hidden',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 16,
    gap: 12,
    backgroundColor: 'transparent',
  },
  rowBorder: {
    borderTopWidth: 1,
    borderTopColor: '#e5e5ea',
  },
  rowContent: {
    flex: 1,
    backgroundColor: 'transparent',
  },
  rowTitle: {
    fontSize: 16,
    fontWeight: '500',
    color: '#000',
  },
  rowSubtitle: {
    fontSize: 13,
    color: '#888',
    marginTop: 2,
  },
  avatar: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: '#007AFF',
    justifyContent: 'center',
    alignItems: 'center',
  },
  emptyText: {
    color: '#666',
    flex: 1,
  },
  logoutButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#fff',
    padding: 16,
    borderRadius: 12,
    gap: 8,
    marginTop: 8,
  },
  logoutText: {
    color: '#FF3B30',
    fontSize: 16,
    fontWeight: '600',
  },
});
