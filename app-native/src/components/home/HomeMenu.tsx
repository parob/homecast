import React, { useState } from 'react';
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
  onSelectRoom: (roomId: string | null) => void;
  onSelectCollection: (collectionId: string | null) => void;
  onSelectGroup: (groupId: string | null) => void;
}

interface MenuItemProps {
  icon?: React.ComponentProps<typeof FontAwesome>['name'];
  label: string;
  onPress?: () => void;
  isSelected?: boolean;
  isExpanded?: boolean;
  hasChildren?: boolean;
  indented?: boolean;
}

function MenuItem({ icon, label, onPress, isSelected, isExpanded, hasChildren, indented }: MenuItemProps) {
  return (
    <TouchableOpacity
      style={[styles.menuItem, indented && styles.menuItemIndented]}
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
      </View>
      {hasChildren && (
        <View style={styles.chevronContainer}>
          <FontAwesome
            name={isExpanded ? 'chevron-down' : 'chevron-right'}
            size={12}
            color={AppleHomeColors.textSecondary}
          />
        </View>
      )}
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
  // Track expanded homes and collections
  const [expandedHomeId, setExpandedHomeId] = useState<string | null>(selectedHomeId);
  const [expandedCollectionId, setExpandedCollectionId] = useState<string | null>(selectedCollectionId);

  // Reset expanded state when menu opens
  React.useEffect(() => {
    if (visible) {
      setExpandedHomeId(selectedHomeId);
      setExpandedCollectionId(selectedCollectionId);
    }
  }, [visible, selectedHomeId, selectedCollectionId]);

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

              {/* Homes section - each home expandable with rooms */}
              {homes.map((home) => {
                const homeRooms = rooms.filter(r => r.homeId === home.id);
                const isExpanded = expandedHomeId === home.id;
                const isHomeSelected = home.id === selectedHomeId && !selectedCollectionId;

                return (
                  <View key={home.id}>
                    <MenuItem
                      icon="home"
                      label={home.name}
                      isSelected={isHomeSelected && !selectedRoomId}
                      hasChildren={homeRooms.length > 0}
                      isExpanded={isExpanded}
                      onPress={() => {
                        if (homeRooms.length > 0) {
                          // Toggle expansion
                          setExpandedHomeId(isExpanded ? null : home.id);
                          setExpandedCollectionId(null);
                        }
                        // Select home and show all rooms
                        onSelectHome(home.id);
                        onSelectRoom(null);
                        onSelectCollection(null);
                        onSelectGroup(null);
                        if (homeRooms.length === 0) {
                          onClose();
                        }
                      }}
                    />
                    {/* Expanded rooms */}
                    {isExpanded && homeRooms.map((room) => (
                      <MenuItem
                        key={room.id}
                        label={room.name}
                        indented
                        isSelected={isHomeSelected && room.id === selectedRoomId}
                        onPress={() => {
                          onSelectHome(home.id);
                          onSelectRoom(room.id);
                          onSelectCollection(null);
                          onSelectGroup(null);
                          onClose();
                        }}
                      />
                    ))}
                  </View>
                );
              })}

              {/* Collections section */}
              {collections.length > 0 && (
                <>
                  <Divider />
                  {collections.map((collection) => {
                    const collectionGroups = parseCollectionPayload(collection.payload).groups;
                    const isExpanded = expandedCollectionId === collection.id;
                    const isCollectionSelected = selectedCollectionId === collection.id;

                    return (
                      <View key={collection.id}>
                        <MenuItem
                          icon="folder"
                          label={collection.name}
                          isSelected={isCollectionSelected && !selectedGroupId}
                          hasChildren={collectionGroups.length > 0}
                          isExpanded={isExpanded}
                          onPress={() => {
                            if (collectionGroups.length > 0) {
                              // Toggle expansion
                              setExpandedCollectionId(isExpanded ? null : collection.id);
                              setExpandedHomeId(null);
                            }
                            // Select collection
                            onSelectCollection(collection.id);
                            onSelectGroup(null);
                            onSelectRoom(null);
                            if (collectionGroups.length === 0) {
                              onClose();
                            }
                          }}
                        />
                        {/* Expanded groups */}
                        {isExpanded && collectionGroups.map((group) => (
                          <MenuItem
                            key={group.id}
                            label={group.name}
                            indented
                            isSelected={isCollectionSelected && selectedGroupId === group.id}
                            onPress={() => {
                              onSelectCollection(collection.id);
                              onSelectGroup(group.id);
                              onSelectRoom(null);
                              onClose();
                            }}
                          />
                        ))}
                      </View>
                    );
                  })}
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
  menuItemIndented: {
    paddingLeft: 44,
    backgroundColor: 'rgba(0,0,0,0.1)',
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
  chevronContainer: {
    width: 20,
    alignItems: 'center',
  },
  menuLabel: {
    fontSize: 16,
    color: AppleHomeColors.textPrimary,
  },
  divider: {
    height: 1,
    backgroundColor: 'rgba(255,255,255,0.15)',
    marginVertical: 4,
    marginHorizontal: 16,
  },
});
