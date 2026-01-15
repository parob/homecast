import React, { forwardRef } from 'react';
import * as DropdownMenu from 'zeego/dropdown-menu';
import { Pressable, StyleSheet, View } from 'react-native';
import type { PressableProps } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import type { Home, Room } from '@/types/homekit';
import type { Collection } from '@/types/api';

const MenuTriggerButton = forwardRef<View, PressableProps>((props, ref) => (
  <Pressable ref={ref} {...props} style={{ padding: 8 }}>
    <FontAwesome name="ellipsis-h" size={18} color="#000000" />
  </Pressable>
));

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

  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <MenuTriggerButton />
      </DropdownMenu.Trigger>

      <DropdownMenu.Content>
        {/* Settings Group */}
        <DropdownMenu.Group>
          <DropdownMenu.Item key="settings">
            <DropdownMenu.ItemIcon ios={{ name: 'gearshape' }} />
            <DropdownMenu.ItemTitle>Home Settings</DropdownMenu.ItemTitle>
          </DropdownMenu.Item>

          <DropdownMenu.Item key="edit-view">
            <DropdownMenu.ItemIcon ios={{ name: 'square.grid.2x2' }} />
            <DropdownMenu.ItemTitle>Edit Home View</DropdownMenu.ItemTitle>
          </DropdownMenu.Item>

          <DropdownMenu.Item key="reorder">
            <DropdownMenu.ItemIcon ios={{ name: 'list.bullet' }} />
            <DropdownMenu.ItemTitle>Reorder Sections</DropdownMenu.ItemTitle>
          </DropdownMenu.Item>
        </DropdownMenu.Group>

        <DropdownMenu.Separator />

        {/* Homes Submenu */}
        {homes.length > 0 && (
          <DropdownMenu.Sub>
            <DropdownMenu.SubTrigger key="homes-trigger">
              <DropdownMenu.ItemIcon ios={{ name: 'house' }} />
              <DropdownMenu.ItemTitle>Homes</DropdownMenu.ItemTitle>
            </DropdownMenu.SubTrigger>

            <DropdownMenu.SubContent>
              {homes.map((home) => (
                <DropdownMenu.CheckboxItem
                  key={`home-${home.id}`}
                  value={home.id === selectedHomeId && !selectedCollectionId ? 'on' : 'off'}
                  onValueChange={() => {
                    onSelectHome(home.id);
                    onSelectCollection(null);
                    onSelectGroup(null);
                    onSelectRoom(null);
                  }}
                >
                  <DropdownMenu.ItemIndicator />
                  <DropdownMenu.ItemTitle>{home.name}</DropdownMenu.ItemTitle>
                </DropdownMenu.CheckboxItem>
              ))}
            </DropdownMenu.SubContent>
          </DropdownMenu.Sub>
        )}

        {/* Rooms Submenu - only show when NOT viewing a collection */}
        {!selectedCollectionId && rooms.length > 0 && (
          <DropdownMenu.Sub>
            <DropdownMenu.SubTrigger key="rooms-trigger">
              <DropdownMenu.ItemIcon ios={{ name: 'door.left.hand.closed' }} />
              <DropdownMenu.ItemTitle>Rooms</DropdownMenu.ItemTitle>
            </DropdownMenu.SubTrigger>

            <DropdownMenu.SubContent>
              <DropdownMenu.CheckboxItem
                key="room-all"
                value={!selectedRoomId ? 'on' : 'off'}
                onValueChange={() => onSelectRoom(null)}
              >
                <DropdownMenu.ItemIndicator />
                <DropdownMenu.ItemTitle>All Rooms</DropdownMenu.ItemTitle>
              </DropdownMenu.CheckboxItem>

              <DropdownMenu.Separator />

              {rooms.map((room) => (
                <DropdownMenu.CheckboxItem
                  key={`room-${room.id}`}
                  value={room.id === selectedRoomId ? 'on' : 'off'}
                  onValueChange={() => {
                    onSelectRoom(room.id);
                    onSelectCollection(null);
                    onSelectGroup(null);
                  }}
                >
                  <DropdownMenu.ItemIndicator />
                  <DropdownMenu.ItemTitle>{room.name}</DropdownMenu.ItemTitle>
                </DropdownMenu.CheckboxItem>
              ))}
            </DropdownMenu.SubContent>
          </DropdownMenu.Sub>
        )}

        {/* Collections Submenu */}
        {collections.length > 0 && (
          <>
            <DropdownMenu.Separator />

            <DropdownMenu.Sub>
              <DropdownMenu.SubTrigger key="collections-trigger">
                <DropdownMenu.ItemIcon ios={{ name: 'folder' }} />
                <DropdownMenu.ItemTitle>Collections</DropdownMenu.ItemTitle>
              </DropdownMenu.SubTrigger>

              <DropdownMenu.SubContent>
                {collections.map((collection) => (
                  <DropdownMenu.CheckboxItem
                    key={`collection-${collection.id}`}
                    value={selectedCollectionId === collection.id && !selectedGroupId ? 'on' : 'off'}
                    onValueChange={() => {
                      onSelectCollection(collection.id);
                      onSelectRoom(null);
                      onSelectGroup(null);
                    }}
                  >
                    <DropdownMenu.ItemIndicator />
                    <DropdownMenu.ItemTitle>{collection.name}</DropdownMenu.ItemTitle>
                  </DropdownMenu.CheckboxItem>
                ))}
              </DropdownMenu.SubContent>
            </DropdownMenu.Sub>
          </>
        )}

        {/* Collection Groups Submenu - only show when a collection with groups is selected */}
        {selectedCollectionId && selectedCollectionGroups.length > 0 && (
          <DropdownMenu.Sub>
            <DropdownMenu.SubTrigger key="groups-trigger">
              <DropdownMenu.ItemIcon ios={{ name: 'square.stack.3d.up' }} />
              <DropdownMenu.ItemTitle>Groups</DropdownMenu.ItemTitle>
            </DropdownMenu.SubTrigger>

            <DropdownMenu.SubContent>
              <DropdownMenu.CheckboxItem
                key="group-all"
                value={!selectedGroupId ? 'on' : 'off'}
                onValueChange={() => onSelectGroup(null)}
              >
                <DropdownMenu.ItemIndicator />
                <DropdownMenu.ItemTitle>All Groups</DropdownMenu.ItemTitle>
              </DropdownMenu.CheckboxItem>

              <DropdownMenu.Separator />

              {selectedCollectionGroups.map((group) => (
                <DropdownMenu.CheckboxItem
                  key={`group-${group.id}`}
                  value={selectedGroupId === group.id ? 'on' : 'off'}
                  onValueChange={() => onSelectGroup(group.id)}
                >
                  <DropdownMenu.ItemIndicator />
                  <DropdownMenu.ItemTitle>{group.name}</DropdownMenu.ItemTitle>
                </DropdownMenu.CheckboxItem>
              ))}
            </DropdownMenu.SubContent>
          </DropdownMenu.Sub>
        )}
      </DropdownMenu.Content>
    </DropdownMenu.Root>
  );
}

const styles = StyleSheet.create({
  menuButton: {
    padding: 8,
  },
});
