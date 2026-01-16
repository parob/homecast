import React, { useMemo } from 'react';
import { MenuView, MenuAction } from '@react-native-menu/menu';
import { Pressable, StyleSheet, Platform } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import type { Home, Room } from '@/types/homekit';
import type { Collection } from '@/types/api';

interface CollectionGroup {
  id: string;
  name: string;
}

interface NativeHomeMenuProps {
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

export function NativeHomeMenu({
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
}: NativeHomeMenuProps) {
  // Get groups for the selected collection
  const selectedCollection = collections.find(c => c.id === selectedCollectionId);
  const selectedCollectionGroups = selectedCollection
    ? parseCollectionPayload(selectedCollection.payload).groups
    : [];

  const menuActions = useMemo(() => {
    const actions: MenuAction[] = [];

    // Settings section
    actions.push({
      id: 'settings',
      title: 'Home Settings',
      image: Platform.select({ ios: 'gearshape', android: 'ic_menu_preferences' }),
    });
    actions.push({
      id: 'edit-view',
      title: 'Edit Home View',
      image: Platform.select({ ios: 'square.grid.2x2', android: 'ic_menu_gallery' }),
    });
    actions.push({
      id: 'reorder',
      title: 'Reorder Sections',
      image: Platform.select({ ios: 'list.bullet', android: 'ic_menu_sort_by_size' }),
    });

    // Each Home with its rooms displayed inline
    homes.forEach((home) => {
      const homeRooms = rooms.filter(r => r.homeId === home.id);
      const isHomeSelected = home.id === selectedHomeId && !selectedCollectionId;

      // Home header item
      actions.push({
        id: `home::${home.id}`,
        title: home.name,
        image: Platform.select({ ios: 'house', android: 'ic_menu_myplaces' }),
        state: isHomeSelected && !selectedRoomId ? 'on' : 'off',
      });

      // Rooms indented under the home (using displayInline)
      if (homeRooms.length > 0) {
        actions.push({
          id: `rooms-group::${home.id}`,
          title: '',
          displayInline: true,
          subactions: homeRooms.map((room) => ({
            id: `room::${home.id}::${room.id}`,
            title: `    ${room.name}`,
            state: isHomeSelected && room.id === selectedRoomId ? 'on' : 'off',
          })),
        });
      }
    });

    // Each Collection with its groups displayed inline
    if (collections.length > 0) {
      collections.forEach((collection) => {
        const collectionGroups = parseCollectionPayload(collection.payload).groups;
        const isCollectionSelected = selectedCollectionId === collection.id;

        // Collection header item
        actions.push({
          id: `collection::${collection.id}`,
          title: collection.name,
          image: Platform.select({ ios: 'folder', android: 'ic_menu_archive' }),
          state: isCollectionSelected && !selectedGroupId ? 'on' : 'off',
        });

        // Groups indented under the collection (using displayInline)
        if (collectionGroups.length > 0) {
          actions.push({
            id: `groups-group::${collection.id}`,
            title: '',
            displayInline: true,
            subactions: collectionGroups.map((group) => ({
              id: `group::${collection.id}::${group.id}`,
              title: `    ${group.name}`,
              state: isCollectionSelected && selectedGroupId === group.id ? 'on' : 'off',
            })),
          });
        }
      });
    }

    return actions;
  }, [homes, rooms, collections, selectedHomeId, selectedRoomId, selectedCollectionId, selectedGroupId]);

  const handlePressAction = (actionId: string) => {
    const parts = actionId.split('::');
    const type = parts[0];

    if (type === 'room') {
      // room::homeId::roomId
      const homeId = parts[1];
      const roomId = parts[2];
      onSelectHome(homeId);
      onSelectRoom(roomId);
      onSelectCollection(null);
      onSelectGroup(null);
    } else if (type === 'home') {
      // home::homeId or home::homeId::all
      const homeId = parts[1];
      onSelectHome(homeId);
      onSelectRoom(null);
      onSelectCollection(null);
      onSelectGroup(null);
    } else if (type === 'group') {
      // group::collectionId::groupId
      const collectionId = parts[1];
      const groupId = parts[2];
      onSelectCollection(collectionId);
      onSelectGroup(groupId);
      onSelectRoom(null);
    } else if (type === 'collection') {
      // collection::collectionId or collection::collectionId::all
      const collectionId = parts[1];
      onSelectCollection(collectionId);
      onSelectGroup(null);
      onSelectRoom(null);
    }
    // Settings actions (settings, edit-view, reorder) can be handled here later
  };

  return (
    <MenuView
      onPressAction={({ nativeEvent }) => handlePressAction(nativeEvent.event)}
      actions={menuActions}
      shouldOpenOnLongPress={false}
    >
      <Pressable style={styles.menuButton}>
        <FontAwesome name="ellipsis-h" size={18} color="#000000" />
      </Pressable>
    </MenuView>
  );
}

const styles = StyleSheet.create({
  menuButton: {
    padding: 8,
  },
});
