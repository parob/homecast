import { useState } from 'react';
import { StyleSheet, TouchableOpacity, ScrollView, Alert, Platform, View, Modal } from 'react-native';
import { useQuery } from '@apollo/client/react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { Text } from '@/components/Themed';
import { useAuth } from '@/providers/AuthProvider';
import { ME_QUERY, DEVICES_QUERY, HOMES_QUERY, ROOMS_QUERY, COLLECTIONS_QUERY, SERVICE_GROUPS_QUERY } from '@/api/graphql/queries';
import { usePreferencesStore, TabItem } from '@/stores/preferencesStore';
import type { UserInfo, DeviceInfo, Collection } from '@/types/api';
import type { Home, Room, ServiceGroup } from '@/types/homekit';

// Icon names for tab types
const tabTypeIcons: Record<TabItem['type'], string> = {
  home: 'home',
  room: 'cube',
  collection: 'folder',
  serviceGroup: 'th-large',
};

export default function SettingsScreen() {
  const { logout, email } = useAuth();
  const { data: meData } = useQuery<{ me: UserInfo }>(ME_QUERY);
  const { data: devicesData } = useQuery<{ devices: DeviceInfo[] }>(DEVICES_QUERY);
  const { data: homesData } = useQuery<{ homes: Home[] }>(HOMES_QUERY);
  const { data: collectionsData } = useQuery<{ collections: Collection[] }>(COLLECTIONS_QUERY);

  const { tabItems, addTabItem, removeTabItem, resetToDefault } = usePreferencesStore();
  const [showAddModal, setShowAddModal] = useState(false);

  const user = meData?.me;
  const devices = devicesData?.devices || [];
  const homes = homesData?.homes || [];
  const collections = collectionsData?.collections || [];
  const macDevices = devices.filter((d) => d.sessionType === 'device');

  const handleLogout = () => {
    Alert.alert('Log Out', 'Are you sure you want to log out?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Log Out', style: 'destructive', onPress: logout },
    ]);
  };

  const handleRemoveTab = (id: string, name: string) => {
    Alert.alert('Remove Tab', `Remove "${name}" from the tab bar?`, [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Remove', style: 'destructive', onPress: () => removeTabItem(id) },
    ]);
  };

  const handleResetToDefault = () => {
    Alert.alert('Reset Tab Bar', 'Reset to show all homes?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Reset', onPress: resetToDefault },
    ]);
  };

  const handleAddTab = (item: TabItem) => {
    // Check Android 5 tab limit
    if (Platform.OS === 'android' && tabItems && tabItems.length >= 5) {
      Alert.alert('Tab Limit', 'Android supports a maximum of 5 tabs.');
      return;
    }
    addTabItem(item);
    setShowAddModal(false);
  };

  // Check if an item is already added
  const isItemAdded = (type: TabItem['type'], id: string) => {
    return tabItems?.some((t) => t.type === type && t.id === id) ?? false;
  };

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      {/* Tab Bar Section */}
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>TAB BAR</Text>
        <View style={styles.card}>
          {tabItems && tabItems.length > 0 ? (
            <>
              {tabItems.map((item, index) => (
                <View
                  key={`${item.type}-${item.id}`}
                  style={[styles.row, index > 0 && styles.rowBorder]}
                >
                  <FontAwesome
                    name={tabTypeIcons[item.type] as any}
                    size={20}
                    color="#007AFF"
                  />
                  <View style={styles.rowContent}>
                    <Text style={styles.rowTitle}>{item.name}</Text>
                    <Text style={styles.rowSubtitle}>
                      {item.type.charAt(0).toUpperCase() + item.type.slice(1)}
                    </Text>
                  </View>
                  <TouchableOpacity
                    onPress={() => handleRemoveTab(item.id, item.name)}
                    hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
                  >
                    <FontAwesome name="times-circle" size={22} color="#FF3B30" />
                  </TouchableOpacity>
                </View>
              ))}
              <TouchableOpacity
                style={[styles.row, styles.rowBorder]}
                onPress={() => setShowAddModal(true)}
              >
                <FontAwesome name="plus-circle" size={20} color="#34C759" />
                <Text style={[styles.rowTitle, { color: '#34C759' }]}>Add Tab</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.row, styles.rowBorder]}
                onPress={handleResetToDefault}
              >
                <FontAwesome name="refresh" size={20} color="#666" />
                <Text style={[styles.rowTitle, { color: '#666' }]}>Reset to Default</Text>
              </TouchableOpacity>
            </>
          ) : (
            <>
              <View style={styles.row}>
                <FontAwesome name="home" size={20} color="#666" />
                <View style={styles.rowContent}>
                  <Text style={styles.rowTitle}>Default: All Homes</Text>
                  <Text style={styles.rowSubtitle}>
                    Showing {homes.length} home{homes.length !== 1 ? 's' : ''}
                  </Text>
                </View>
              </View>
              <TouchableOpacity
                style={[styles.row, styles.rowBorder]}
                onPress={() => setShowAddModal(true)}
              >
                <FontAwesome name="plus-circle" size={20} color="#34C759" />
                <Text style={[styles.rowTitle, { color: '#34C759' }]}>Customize Tabs</Text>
              </TouchableOpacity>
            </>
          )}
        </View>
      </View>

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

      {/* Add Tab Modal */}
      <AddTabModal
        visible={showAddModal}
        onClose={() => setShowAddModal(false)}
        onSelect={handleAddTab}
        homes={homes}
        collections={collections}
        isItemAdded={isItemAdded}
      />
    </ScrollView>
  );
}

// Modal component for adding tabs
function AddTabModal({
  visible,
  onClose,
  onSelect,
  homes,
  collections,
  isItemAdded,
}: {
  visible: boolean;
  onClose: () => void;
  onSelect: (item: TabItem) => void;
  homes: Home[];
  collections: Collection[];
  isItemAdded: (type: TabItem['type'], id: string) => boolean;
}) {
  const [selectedHome, setSelectedHome] = useState<Home | null>(null);

  // Fetch rooms and service groups for selected home
  const { data: roomsData } = useQuery<{ rooms: Room[] }>(ROOMS_QUERY, {
    variables: { homeId: selectedHome?.id },
    skip: !selectedHome,
  });
  const { data: serviceGroupsData } = useQuery<{ serviceGroups: ServiceGroup[] }>(
    SERVICE_GROUPS_QUERY,
    {
      variables: { homeId: selectedHome?.id },
      skip: !selectedHome,
    }
  );

  const rooms = roomsData?.rooms || [];
  const serviceGroups = serviceGroupsData?.serviceGroups || [];

  const handleBack = () => {
    setSelectedHome(null);
  };

  const handleClose = () => {
    setSelectedHome(null);
    onClose();
  };

  return (
    <Modal visible={visible} animationType="slide" presentationStyle="pageSheet">
      <View style={modalStyles.container}>
        <View style={modalStyles.header}>
          {selectedHome ? (
            <TouchableOpacity onPress={handleBack} style={modalStyles.backButton}>
              <FontAwesome name="chevron-left" size={16} color="#007AFF" />
              <Text style={modalStyles.backText}>Back</Text>
            </TouchableOpacity>
          ) : (
            <View style={modalStyles.backButton} />
          )}
          <Text style={modalStyles.title}>
            {selectedHome ? selectedHome.name : 'Add Tab'}
          </Text>
          <TouchableOpacity onPress={handleClose} style={modalStyles.closeButton}>
            <Text style={modalStyles.closeText}>Done</Text>
          </TouchableOpacity>
        </View>

        <ScrollView style={modalStyles.content}>
          {selectedHome ? (
            // Show rooms and service groups for selected home
            <>
              <Text style={modalStyles.sectionTitle}>ROOMS</Text>
              <View style={modalStyles.card}>
                {rooms.length === 0 ? (
                  <Text style={modalStyles.emptyText}>No rooms in this home</Text>
                ) : (
                  rooms.map((room, index) => {
                    const added = isItemAdded('room', room.id);
                    return (
                      <TouchableOpacity
                        key={room.id}
                        style={[modalStyles.row, index > 0 && modalStyles.rowBorder]}
                        onPress={() =>
                          !added &&
                          onSelect({
                            type: 'room',
                            id: room.id,
                            name: room.name,
                            homeId: selectedHome.id,
                          })
                        }
                        disabled={added}
                      >
                        <FontAwesome
                          name="cube"
                          size={20}
                          color={added ? '#ccc' : '#007AFF'}
                        />
                        <Text
                          style={[
                            modalStyles.rowTitle,
                            added && modalStyles.disabledText,
                          ]}
                        >
                          {room.name}
                        </Text>
                        {added && (
                          <FontAwesome name="check" size={16} color="#34C759" />
                        )}
                      </TouchableOpacity>
                    );
                  })
                )}
              </View>

              {serviceGroups.length > 0 && (
                <>
                  <Text style={modalStyles.sectionTitle}>SERVICE GROUPS</Text>
                  <View style={modalStyles.card}>
                    {serviceGroups.map((group, index) => {
                      const added = isItemAdded('serviceGroup', group.id);
                      return (
                        <TouchableOpacity
                          key={group.id}
                          style={[modalStyles.row, index > 0 && modalStyles.rowBorder]}
                          onPress={() =>
                            !added &&
                            onSelect({
                              type: 'serviceGroup',
                              id: group.id,
                              name: group.name,
                              homeId: selectedHome.id,
                            })
                          }
                          disabled={added}
                        >
                          <FontAwesome
                            name="th-large"
                            size={20}
                            color={added ? '#ccc' : '#007AFF'}
                          />
                          <Text
                            style={[
                              modalStyles.rowTitle,
                              added && modalStyles.disabledText,
                            ]}
                          >
                            {group.name}
                          </Text>
                          {added && (
                            <FontAwesome name="check" size={16} color="#34C759" />
                          )}
                        </TouchableOpacity>
                      );
                    })}
                  </View>
                </>
              )}
            </>
          ) : (
            // Show homes and collections
            <>
              <Text style={modalStyles.sectionTitle}>HOMES</Text>
              <View style={modalStyles.card}>
                {homes.map((home, index) => {
                  const added = isItemAdded('home', home.id);
                  return (
                    <View
                      key={home.id}
                      style={[modalStyles.row, index > 0 && modalStyles.rowBorder]}
                    >
                      <TouchableOpacity
                        style={modalStyles.rowMain}
                        onPress={() =>
                          !added &&
                          onSelect({ type: 'home', id: home.id, name: home.name })
                        }
                        disabled={added}
                      >
                        <FontAwesome
                          name="home"
                          size={20}
                          color={added ? '#ccc' : '#007AFF'}
                        />
                        <Text
                          style={[
                            modalStyles.rowTitle,
                            added && modalStyles.disabledText,
                          ]}
                        >
                          {home.name}
                        </Text>
                        {added && (
                          <FontAwesome name="check" size={16} color="#34C759" />
                        )}
                      </TouchableOpacity>
                      <TouchableOpacity
                        onPress={() => setSelectedHome(home)}
                        style={modalStyles.chevronButton}
                      >
                        <FontAwesome name="chevron-right" size={14} color="#999" />
                      </TouchableOpacity>
                    </View>
                  );
                })}
              </View>

              {collections.length > 0 && (
                <>
                  <Text style={modalStyles.sectionTitle}>COLLECTIONS</Text>
                  <View style={modalStyles.card}>
                    {collections.map((collection, index) => {
                      const added = isItemAdded('collection', collection.id);
                      return (
                        <TouchableOpacity
                          key={collection.id}
                          style={[modalStyles.row, index > 0 && modalStyles.rowBorder]}
                          onPress={() =>
                            !added &&
                            onSelect({
                              type: 'collection',
                              id: collection.id,
                              name: collection.name,
                            })
                          }
                          disabled={added}
                        >
                          <FontAwesome
                            name="folder"
                            size={20}
                            color={added ? '#ccc' : '#007AFF'}
                          />
                          <Text
                            style={[
                              modalStyles.rowTitle,
                              added && modalStyles.disabledText,
                            ]}
                          >
                            {collection.name}
                          </Text>
                          {added && (
                            <FontAwesome name="check" size={16} color="#34C759" />
                          )}
                        </TouchableOpacity>
                      );
                    })}
                  </View>
                </>
              )}
            </>
          )}
        </ScrollView>
      </View>
    </Modal>
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

const modalStyles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f2f2f7',
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    padding: 16,
    paddingTop: 20,
    backgroundColor: '#fff',
    borderBottomWidth: 1,
    borderBottomColor: '#e5e5ea',
  },
  backButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    width: 70,
  },
  backText: {
    color: '#007AFF',
    fontSize: 16,
  },
  title: {
    fontSize: 17,
    fontWeight: '600',
    color: '#000',
  },
  closeButton: {
    width: 70,
    alignItems: 'flex-end',
  },
  closeText: {
    color: '#007AFF',
    fontSize: 16,
    fontWeight: '600',
  },
  content: {
    flex: 1,
    padding: 16,
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: '#888',
    marginBottom: 8,
    marginLeft: 4,
    marginTop: 16,
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
  },
  rowMain: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  rowBorder: {
    borderTopWidth: 1,
    borderTopColor: '#e5e5ea',
  },
  rowTitle: {
    fontSize: 16,
    fontWeight: '500',
    color: '#000',
    flex: 1,
  },
  disabledText: {
    color: '#999',
  },
  chevronButton: {
    padding: 8,
  },
  emptyText: {
    padding: 16,
    color: '#666',
    textAlign: 'center',
  },
});
