import { useState, useCallback } from 'react';
import {
  StyleSheet,
  TouchableOpacity,
  ScrollView,
  Alert,
  View,
  Modal,
} from 'react-native';
import { useQuery } from '@apollo/client/react';
import Ionicons from '@expo/vector-icons/Ionicons';
import { Stack } from 'expo-router';
import DraggableFlatList, {
  ScaleDecorator,
  RenderItemParams,
} from 'react-native-draggable-flatlist';
import { GestureHandlerRootView } from 'react-native-gesture-handler';

import { Text } from '@/components/Themed';
import { HOMES_QUERY, ROOMS_QUERY, COLLECTIONS_QUERY, SERVICE_GROUPS_QUERY } from '@/api/graphql/queries';
import { usePreferencesStore, TabItem } from '@/stores/preferencesStore';
import type { Collection } from '@/types/api';
import type { Home, Room, ServiceGroup } from '@/types/homekit';

const tabTypeIcons: Record<TabItem['type'], keyof typeof Ionicons.glyphMap> = {
  home: 'home',
  room: 'enter-outline',
  collection: 'folder',
  serviceGroup: 'grid',
};

function SortableTabItem({
  item,
  drag,
  isActive,
  onRemove,
}: RenderItemParams<TabItem> & { onRemove: (id: string) => void }) {
  return (
    <ScaleDecorator>
      <TouchableOpacity
        onLongPress={drag}
        disabled={isActive}
        style={[styles.sortableRow, isActive && styles.sortableRowActive]}
        activeOpacity={0.7}
      >
        <Ionicons name="menu" size={20} color="#C7C7CC" style={styles.dragHandle} />
        <Ionicons name={tabTypeIcons[item.type]} size={20} color="#007AFF" />
        <Text style={styles.sortableLabel} numberOfLines={1}>
          {item.name}
        </Text>
        <TouchableOpacity
          onPress={() => onRemove(item.id)}
          hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
        >
          <Ionicons name="close-circle" size={22} color="#C7C7CC" />
        </TouchableOpacity>
      </TouchableOpacity>
    </ScaleDecorator>
  );
}

function TabBarConfig({
  items,
  homes,
  onRemove,
  onReorder,
  onAddTab,
  onReset,
}: {
  items: TabItem[] | null;
  homes: Home[];
  onRemove: (id: string) => void;
  onReorder: (data: TabItem[]) => void;
  onAddTab: () => void;
  onReset: () => void;
}) {
  const hasCustomTabs = items && items.length > 0;

  const renderItem = useCallback(
    (params: RenderItemParams<TabItem>) => (
      <SortableTabItem {...params} onRemove={onRemove} />
    ),
    [onRemove]
  );

  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>TAB BAR</Text>
      <View style={styles.card}>
        {hasCustomTabs ? (
          <DraggableFlatList
            data={items}
            keyExtractor={(item) => `${item.type}-${item.id}`}
            renderItem={renderItem}
            onDragEnd={({ data }) => onReorder(data)}
            scrollEnabled={false}
          />
        ) : (
          <View style={styles.emptyState}>
            <Text style={styles.emptyText}>
              Showing all homes by default
            </Text>
          </View>
        )}
      </View>

      <View style={styles.buttonRow}>
        <TouchableOpacity style={styles.addButton} onPress={onAddTab}>
          <Ionicons name="add" size={18} color="#007AFF" />
          <Text style={styles.addButtonText}>Add Tab</Text>
        </TouchableOpacity>
        {hasCustomTabs && (
          <TouchableOpacity style={styles.resetButton} onPress={onReset}>
            <Text style={styles.resetButtonText}>Reset to Default</Text>
          </TouchableOpacity>
        )}
      </View>

      <Text style={styles.footerHint}>
        {hasCustomTabs
          ? 'Drag to reorder. Maximum 5 tabs.'
          : 'Add tabs to customize your navigation.'}
      </Text>
    </View>
  );
}

export default function AppearanceScreen() {
  const { data: homesData } = useQuery<{ homes: Home[] }>(HOMES_QUERY);
  const { data: collectionsData } = useQuery<{ collections: Collection[] }>(COLLECTIONS_QUERY);

  const { tabItems, addTabItem, removeTabItem, setTabItems, resetToDefault } = usePreferencesStore();
  const [showAddModal, setShowAddModal] = useState(false);

  const homes = homesData?.homes || [];
  const collections = collectionsData?.collections || [];

  const handleRemove = useCallback((id: string) => {
    const item = tabItems?.find((t) => t.id === id);
    if (item) {
      Alert.alert('Remove Tab', `Remove "${item.name}" from the tab bar?`, [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Remove', style: 'destructive', onPress: () => removeTabItem(id) },
      ]);
    }
  }, [tabItems, removeTabItem]);

  const handleReorder = useCallback((data: TabItem[]) => {
    setTabItems(data);
  }, [setTabItems]);

  const handleResetToDefault = () => {
    Alert.alert('Reset Tab Bar', 'Reset to show all homes?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Reset', onPress: resetToDefault },
    ]);
  };

  const handleAddTab = (item: TabItem) => {
    if (tabItems && tabItems.length >= 5) {
      Alert.alert('Tab Limit', 'Maximum of 5 tabs allowed.');
      return;
    }
    addTabItem(item);
    setShowAddModal(false);
  };

  const isItemAdded = (type: TabItem['type'], id: string) => {
    return tabItems?.some((t) => t.type === type && t.id === id) ?? false;
  };

  return (
    <GestureHandlerRootView style={styles.container}>
      <Stack.Screen
        options={{
          title: 'Appearance',
          headerBackButtonDisplayMode: 'minimal',
        }}
      />

      <ScrollView
        style={styles.scrollView}
        contentContainerStyle={styles.content}
      >
        <TabBarConfig
          items={tabItems}
          homes={homes}
          onRemove={handleRemove}
          onReorder={handleReorder}
          onAddTab={() => setShowAddModal(true)}
          onReset={handleResetToDefault}
        />
      </ScrollView>

      <AddTabModal
        visible={showAddModal}
        onClose={() => setShowAddModal(false)}
        onSelect={handleAddTab}
        homes={homes}
        collections={collections}
        isItemAdded={isItemAdded}
      />
    </GestureHandlerRootView>
  );
}

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

  const handleBack = () => setSelectedHome(null);
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
              <Ionicons name="chevron-back" size={20} color="#007AFF" />
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
                        <Ionicons name="enter-outline" size={20} color={added ? '#ccc' : '#007AFF'} />
                        <Text style={[modalStyles.rowTitle, added && modalStyles.disabledText]}>
                          {room.name}
                        </Text>
                        {added && <Ionicons name="checkmark" size={18} color="#34C759" />}
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
                          <Ionicons name="grid" size={20} color={added ? '#ccc' : '#007AFF'} />
                          <Text style={[modalStyles.rowTitle, added && modalStyles.disabledText]}>
                            {group.name}
                          </Text>
                          {added && <Ionicons name="checkmark" size={18} color="#34C759" />}
                        </TouchableOpacity>
                      );
                    })}
                  </View>
                </>
              )}
            </>
          ) : (
            <>
              <Text style={modalStyles.sectionTitle}>HOMES</Text>
              <View style={modalStyles.card}>
                {homes.map((home, index) => {
                  const added = isItemAdded('home', home.id);
                  return (
                    <View key={home.id} style={[modalStyles.row, index > 0 && modalStyles.rowBorder]}>
                      <TouchableOpacity
                        style={modalStyles.rowMain}
                        onPress={() => !added && onSelect({ type: 'home', id: home.id, name: home.name })}
                        disabled={added}
                      >
                        <Ionicons name="home" size={20} color={added ? '#ccc' : '#007AFF'} />
                        <Text style={[modalStyles.rowTitle, added && modalStyles.disabledText]}>
                          {home.name}
                        </Text>
                        {added && <Ionicons name="checkmark" size={18} color="#34C759" />}
                      </TouchableOpacity>
                      <TouchableOpacity onPress={() => setSelectedHome(home)} style={modalStyles.chevronButton}>
                        <Ionicons name="chevron-forward" size={18} color="#C7C7CC" />
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
                          <Ionicons name="folder" size={20} color={added ? '#ccc' : '#007AFF'} />
                          <Text style={[modalStyles.rowTitle, added && modalStyles.disabledText]}>
                            {collection.name}
                          </Text>
                          {added && <Ionicons name="checkmark" size={18} color="#34C759" />}
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
  scrollView: {
    flex: 1,
  },
  content: {
    padding: 16,
  },
  section: {
    marginBottom: 24,
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: '#6D6D72',
    marginBottom: 8,
    marginLeft: 16,
    textTransform: 'uppercase',
  },
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    overflow: 'hidden',
  },
  sortableRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 12,
    paddingHorizontal: 16,
    backgroundColor: '#fff',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#C6C6C8',
    gap: 12,
  },
  sortableRowActive: {
    backgroundColor: '#f0f0f0',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.15,
    shadowRadius: 4,
    elevation: 4,
  },
  dragHandle: {
    marginRight: 4,
  },
  sortableLabel: {
    flex: 1,
    fontSize: 17,
    color: '#000',
  },
  emptyState: {
    padding: 20,
    alignItems: 'center',
  },
  emptyText: {
    fontSize: 15,
    color: '#8E8E93',
  },
  buttonRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginTop: 12,
    paddingHorizontal: 4,
  },
  addButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
  },
  addButtonText: {
    fontSize: 17,
    color: '#007AFF',
  },
  resetButton: {},
  resetButtonText: {
    fontSize: 17,
    color: '#FF3B30',
  },
  footerHint: {
    fontSize: 13,
    color: '#6D6D72',
    marginTop: 8,
    marginLeft: 4,
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
