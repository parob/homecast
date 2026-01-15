import React from 'react';
import {
  StyleSheet,
  View,
  TouchableOpacity,
  Modal,
  ScrollView,
  Dimensions,
} from 'react-native';
import { CrossPlatformBlur } from '@/components/CrossPlatformBlur';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import { Text } from '@/components/Themed';
import { AppleHomeColors } from '@/constants/Colors';
import type { Home, Room } from '@/types/homekit';
import type { Collection } from '@/types/api';

const SCREEN_WIDTH = Dimensions.get('window').width;

interface CollectionGroup {
  id: string;
  name: string;
}

interface HomeMenuProps {
  visible: boolean;
  onClose: () => void;
  homes: Home[];
  rooms: Room[];
  collections: Collection[];
  selectedHomeId: string | null;
  selectedRoomId: string | null;
  selectedCollectionId: string | null;
  selectedGroupId: string | null;
  onSelectHome: (homeId: string) => void;
  onSelectRoom: (roomId: string) => void;
  onSelectCollection: (collectionId: string | null) => void;
  onSelectGroup: (groupId: string | null) => void;
}

interface MenuItemProps {
  icon?: React.ComponentProps<typeof FontAwesome>['name'];
  label: string;
  onPress?: () => void;
  isSelected?: boolean;
  subtitle?: string;
}

function MenuItem({ icon, label, onPress, isSelected, subtitle }: MenuItemProps) {
  return (
    <TouchableOpacity
      style={styles.menuItem}
      onPress={onPress}
      activeOpacity={0.6}
    >
      {isSelected !== undefined && (
        <View style={styles.checkContainer}>
          {isSelected && <FontAwesome name="check" size={14} color={AppleHomeColors.textPrimary} />}
        </View>
      )}
      {icon && (
        <View style={styles.iconContainer}>
          <FontAwesome name={icon} size={16} color={AppleHomeColors.textSecondary} />
        </View>
      )}
      <View style={styles.labelContainer}>
        <Text style={styles.menuLabel}>{label}</Text>
        {subtitle && <Text style={styles.menuSubtitle}>{subtitle}</Text>}
      </View>
    </TouchableOpacity>
  );
}

function Divider() {
  return <View style={styles.divider} />;
}

function parseCollectionPayload(payloadStr: string): { groups: CollectionGroup[] } {
  try {
    const parsed = JSON.parse(payloadStr || '{"items":[],"groups":[]}');
    if (Array.isArray(parsed)) {
      return { groups: [] };
    }
    return { groups: parsed.groups || [] };
  } catch {
    return { groups: [] };
  }
}

export function HomeMenu({
  visible,
  onClose,
  homes,
  rooms,
  collections,
  selectedHomeId,
  selectedRoomId,
  selectedCollectionId,
  selectedGroupId,
  onSelectHome,
  onSelectRoom,
  onSelectCollection,
  onSelectGroup,
}: HomeMenuProps) {
  // Get groups for the selected collection
  const selectedCollection = collections.find(c => c.id === selectedCollectionId);
  const selectedCollectionGroups = selectedCollection
    ? parseCollectionPayload(selectedCollection.payload).groups
    : [];

  return (
    <Modal
      visible={visible}
      transparent
      animationType="fade"
      onRequestClose={onClose}
    >
      <TouchableOpacity
        style={styles.overlay}
        activeOpacity={1}
        onPress={onClose}
      >
        <View style={styles.menuContainer}>
          <CrossPlatformBlur intensity={90} tint="dark" style={styles.menuBlur}>
            <ScrollView style={styles.menuScroll} showsVerticalScrollIndicator={false}>
              {/* Settings section */}
              <MenuItem icon="cog" label="Home Settings" />
              <MenuItem icon="th-large" label="Edit Home View" />
              <MenuItem icon="list" label="Reorder Sections" />

              <Divider />

              {/* Homes section */}
              {homes.map((home) => (
                <MenuItem
                  key={home.id}
                  label={home.name}
                  isSelected={home.id === selectedHomeId && !selectedCollectionId}
                  subtitle={home.isPrimary ? 'Current Location' : undefined}
                  onPress={() => {
                    onSelectHome(home.id);
                    onSelectCollection(null);
                    onSelectGroup(null);
                    onClose();
                  }}
                />
              ))}

              {/* Rooms section - only show when NOT viewing a collection */}
              {!selectedCollectionId && rooms.length > 0 && (
                <>
                  <Divider />
                  {rooms.map((room) => (
                    <MenuItem
                      key={room.id}
                      label={room.name}
                      isSelected={room.id === selectedRoomId}
                      onPress={() => {
                        onSelectRoom(room.id);
                        onClose();
                      }}
                    />
                  ))}
                </>
              )}

              {/* Collections section */}
              {collections.length > 0 && (
                <>
                  <Divider />
                  {collections.map((collection) => (
                    <MenuItem
                      key={collection.id}
                      label={collection.name}
                      isSelected={selectedCollectionId === collection.id && !selectedGroupId}
                      onPress={() => {
                        onSelectCollection(collection.id);
                        onSelectGroup(null);
                        onClose();
                      }}
                    />
                  ))}
                </>
              )}

              {/* Groups section - only show when a collection is selected */}
              {selectedCollectionId && selectedCollectionGroups.length > 0 && (
                <>
                  <Divider />
                  {selectedCollectionGroups.map((group) => (
                    <MenuItem
                      key={group.id}
                      label={group.name}
                      isSelected={selectedGroupId === group.id}
                      onPress={() => {
                        onSelectGroup(group.id);
                        onClose();
                      }}
                    />
                  ))}
                </>
              )}
            </ScrollView>
          </CrossPlatformBlur>
        </View>
      </TouchableOpacity>
    </Modal>
  );
}

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.3)',
  },
  menuContainer: {
    position: 'absolute',
    top: 100,
    right: 16,
    width: Math.min(280, SCREEN_WIDTH - 32),
    maxHeight: 500,
    borderRadius: 14,
    overflow: 'hidden',
  },
  menuBlur: {
    borderRadius: 14,
    overflow: 'hidden',
  },
  menuScroll: {
    borderRadius: 14,
  },
  menuItem: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 12,
    paddingHorizontal: 16,
  },
  checkContainer: {
    width: 24,
    alignItems: 'center',
  },
  iconContainer: {
    width: 28,
    alignItems: 'center',
  },
  labelContainer: {
    flex: 1,
  },
  menuLabel: {
    fontSize: 16,
    color: AppleHomeColors.textPrimary,
  },
  menuSubtitle: {
    fontSize: 12,
    color: AppleHomeColors.textSecondary,
    marginTop: 2,
  },
  divider: {
    height: 1,
    backgroundColor: 'rgba(255,255,255,0.15)',
    marginVertical: 4,
    marginHorizontal: 16,
  },
});
