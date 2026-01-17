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
import FontAwesome from '@expo/vector-icons/FontAwesome';
import Ionicons from '@expo/vector-icons/Ionicons';
import { Stack } from 'expo-router';
import Animated, {
  useAnimatedStyle,
  useSharedValue,
  runOnJS,
  SharedValue,
} from 'react-native-reanimated';
import {
  GestureDetector,
  Gesture,
  GestureHandlerRootView,
} from 'react-native-gesture-handler';

import { Text } from '@/components/Themed';
import { HOMES_QUERY, ROOMS_QUERY, COLLECTIONS_QUERY, SERVICE_GROUPS_QUERY } from '@/api/graphql/queries';
import { usePreferencesStore, TabItem } from '@/stores/preferencesStore';
import type { Collection } from '@/types/api';
import type { Home, Room, ServiceGroup } from '@/types/homekit';

const TAB_PREVIEW_HEIGHT = 80;
const TAB_ITEM_SIZE = 60;
const TAB_ITEM_MARGIN = 4;
const ITEM_WIDTH = TAB_ITEM_SIZE + TAB_ITEM_MARGIN * 2;

const tabTypeIcons: Record<TabItem['type'], string> = {
  home: 'home',
  room: 'cube',
  collection: 'folder',
  serviceGroup: 'th-large',
};

function DraggableTabItem({
  item,
  index,
  totalItems,
  onRemove,
  onReorder,
  draggedIndex,
  draggedTranslateX,
}: {
  item: TabItem;
  index: number;
  totalItems: number;
  onRemove: (id: string) => void;
  onReorder: (from: number, to: number) => void;
  draggedIndex: SharedValue<number>;
  draggedTranslateX: SharedValue<number>;
}) {
  const translateX = useSharedValue(0);
  const scale = useSharedValue(1);
  const isDragging = useSharedValue(false);

  const gesture = Gesture.Pan()
    .onStart(() => {
      isDragging.value = true;
      draggedIndex.value = index;
      scale.value = 1.05;
    })
    .onUpdate((event) => {
      translateX.value = event.translationX;
      draggedTranslateX.value = event.translationX;
    })
    .onEnd((event) => {
      const offset = Math.round(event.translationX / ITEM_WIDTH);
      const newIndex = Math.max(0, Math.min(totalItems - 1, index + offset));
      const didMove = newIndex !== index;

      // Reset all animation state immediately
      scale.value = 1;
      isDragging.value = false;
      draggedIndex.value = -1;
      draggedTranslateX.value = 0;
      translateX.value = 0;

      if (didMove) {
        runOnJS(onReorder)(index, newIndex);
      }
    });

  const animatedStyle = useAnimatedStyle(() => {
    // When this item is being dragged
    if (isDragging.value) {
      return {
        transform: [
          { translateX: translateX.value },
          { scale: scale.value },
        ],
        zIndex: 100,
      };
    }

    // When another item is being dragged, maybe shift this one
    if (draggedIndex.value !== -1 && draggedIndex.value !== index) {
      const draggedTo = draggedIndex.value + Math.round(draggedTranslateX.value / ITEM_WIDTH);
      const clampedDraggedTo = Math.max(0, Math.min(totalItems - 1, draggedTo));

      let shift = 0;
      if (draggedIndex.value < index && clampedDraggedTo >= index) {
        shift = -ITEM_WIDTH;
      } else if (draggedIndex.value > index && clampedDraggedTo <= index) {
        shift = ITEM_WIDTH;
      }

      return {
        transform: [
          { translateX: shift },
          { scale: 1 },
        ],
        zIndex: 1,
      };
    }

    // Default state
    return {
      transform: [
        { translateX: 0 },
        { scale: 1 },
      ],
      zIndex: 1,
    };
  });

  return (
    <GestureDetector gesture={gesture}>
      <Animated.View style={[styles.tabPreviewItem, animatedStyle]}>
        <TouchableOpacity
          style={styles.removeButton}
          onPress={() => onRemove(item.id)}
          hitSlop={{ top: 5, bottom: 5, left: 5, right: 5 }}
        >
          <View style={styles.removeButtonCircle}>
            <FontAwesome name="times" size={10} color="#fff" />
          </View>
        </TouchableOpacity>
        <View style={styles.tabIconContainer}>
          <FontAwesome
            name={tabTypeIcons[item.type] as any}
            size={22}
            color="#007AFF"
          />
        </View>
        <Text style={styles.tabPreviewLabel} numberOfLines={1}>
          {item.name}
        </Text>
      </Animated.View>
    </GestureDetector>
  );
}

function TabBarPreview({
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
  onReorder: (from: number, to: number) => void;
  onAddTab: () => void;
  onReset: () => void;
}) {
  const draggedIndex = useSharedValue(-1);
  const draggedTranslateX = useSharedValue(0);

  const handleReorder = useCallback((from: number, to: number) => {
    onReorder(from, to);
  }, [onReorder]);

  const displayItems = items && items.length > 0
    ? items
    : homes.map((h) => ({ type: 'home' as const, id: h.id, name: h.name }));

  const hasCustomTabs = items && items.length > 0;

  return (
    <View style={styles.tabPreviewContainer}>
      <Text style={styles.sectionTitle}>TAB BAR</Text>
      <View style={styles.tabBarMockup}>
        {hasCustomTabs ? (
          <View style={styles.tabPreviewScroll}>
            {displayItems.map((item, index) => (
              <DraggableTabItem
                key={`${index}-${item.type}-${item.id}`}
                item={item}
                index={index}
                totalItems={displayItems.length}
                onRemove={onRemove}
                onReorder={handleReorder}
                draggedIndex={draggedIndex}
                draggedTranslateX={draggedTranslateX}
              />
            ))}
          </View>
        ) : (
          <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            contentContainerStyle={styles.tabPreviewScroll}
          >
            {displayItems.map((item) => (
              <View key={`${item.type}-${item.id}`} style={styles.tabPreviewItem}>
                <View style={styles.tabIconContainer}>
                  <FontAwesome
                    name={tabTypeIcons[item.type] as any}
                    size={22}
                    color="#8E8E93"
                  />
                </View>
                <Text style={[styles.tabPreviewLabel, styles.defaultLabel]} numberOfLines={1}>
                  {item.name}
                </Text>
              </View>
            ))}
          </ScrollView>
        )}
      </View>

      {hasCustomTabs ? (
        <Text style={styles.dragHint}>
          Drag tabs to reorder • Tap × to remove
        </Text>
      ) : (
        <Text style={styles.defaultHint}>
          Default view showing all homes
        </Text>
      )}

      <View style={styles.previewActions}>
        <TouchableOpacity style={styles.actionButton} onPress={onAddTab}>
          <FontAwesome name="plus" size={14} color="#34C759" />
          <Text style={[styles.actionButtonText, { color: '#34C759' }]}>Add Tab</Text>
        </TouchableOpacity>
        {hasCustomTabs && (
          <TouchableOpacity style={styles.actionButton} onPress={onReset}>
            <FontAwesome name="refresh" size={14} color="#FF3B30" />
            <Text style={[styles.actionButtonText, { color: '#FF3B30' }]}>Reset</Text>
          </TouchableOpacity>
        )}
      </View>
    </View>
  );
}

export default function AppearanceScreen() {
  const { data: homesData } = useQuery<{ homes: Home[] }>(HOMES_QUERY);
  const { data: collectionsData } = useQuery<{ collections: Collection[] }>(COLLECTIONS_QUERY);

  const { tabItems, addTabItem, removeTabItem, reorderTabItems, resetToDefault } = usePreferencesStore();
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

  const handleReorder = useCallback((fromIndex: number, toIndex: number) => {
    reorderTabItems(fromIndex, toIndex);
  }, [reorderTabItems]);

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
        <View style={styles.centeredContent}>
          <TabBarPreview
            items={tabItems}
            homes={homes}
            onRemove={handleRemove}
            onReorder={handleReorder}
            onAddTab={() => setShowAddModal(true)}
            onReset={handleResetToDefault}
          />

          <View style={styles.infoCard}>
            <FontAwesome name="info-circle" size={16} color="#8E8E93" />
            <Text style={styles.infoText}>
              Maximum of 5 tabs in the navigation bar.
            </Text>
          </View>
        </View>
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
                        <FontAwesome name="cube" size={20} color={added ? '#ccc' : '#007AFF'} />
                        <Text style={[modalStyles.rowTitle, added && modalStyles.disabledText]}>
                          {room.name}
                        </Text>
                        {added && <FontAwesome name="check" size={16} color="#34C759" />}
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
                          <FontAwesome name="th-large" size={20} color={added ? '#ccc' : '#007AFF'} />
                          <Text style={[modalStyles.rowTitle, added && modalStyles.disabledText]}>
                            {group.name}
                          </Text>
                          {added && <FontAwesome name="check" size={16} color="#34C759" />}
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
                        <FontAwesome name="home" size={20} color={added ? '#ccc' : '#007AFF'} />
                        <Text style={[modalStyles.rowTitle, added && modalStyles.disabledText]}>
                          {home.name}
                        </Text>
                        {added && <FontAwesome name="check" size={16} color="#34C759" />}
                      </TouchableOpacity>
                      <TouchableOpacity onPress={() => setSelectedHome(home)} style={modalStyles.chevronButton}>
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
                          <FontAwesome name="folder" size={20} color={added ? '#ccc' : '#007AFF'} />
                          <Text style={[modalStyles.rowTitle, added && modalStyles.disabledText]}>
                            {collection.name}
                          </Text>
                          {added && <FontAwesome name="check" size={16} color="#34C759" />}
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
    flexGrow: 1,
    justifyContent: 'center',
    padding: 16,
  },
  centeredContent: {
    width: '100%',
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: '#888',
    marginBottom: 12,
  },
  tabPreviewContainer: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 16,
    marginBottom: 24,
  },
  tabBarMockup: {
    backgroundColor: '#f8f8f8',
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#e5e5ea',
    minHeight: TAB_PREVIEW_HEIGHT,
    justifyContent: 'center',
  },
  tabPreviewScroll: {
    flexDirection: 'row',
    paddingHorizontal: 8,
    paddingVertical: 8,
    alignItems: 'center',
    minHeight: TAB_PREVIEW_HEIGHT,
  },
  tabPreviewItem: {
    alignItems: 'center',
    width: TAB_ITEM_SIZE,
    marginHorizontal: TAB_ITEM_MARGIN,
  },
  tabIconContainer: {
    width: 36,
    height: 36,
    borderRadius: 8,
    backgroundColor: '#fff',
    justifyContent: 'center',
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.1,
    shadowRadius: 2,
    elevation: 2,
  },
  tabPreviewLabel: {
    fontSize: 10,
    color: '#007AFF',
    marginTop: 4,
    textAlign: 'center',
    fontWeight: '500',
  },
  defaultLabel: {
    color: '#8E8E93',
  },
  removeButton: {
    position: 'absolute',
    top: -4,
    right: 2,
    zIndex: 10,
  },
  removeButtonCircle: {
    width: 18,
    height: 18,
    borderRadius: 9,
    backgroundColor: '#FF3B30',
    justifyContent: 'center',
    alignItems: 'center',
    borderWidth: 2,
    borderColor: '#fff',
  },
  defaultHint: {
    fontSize: 12,
    color: '#8E8E93',
    textAlign: 'center',
    marginTop: 12,
  },
  dragHint: {
    fontSize: 12,
    color: '#8E8E93',
    textAlign: 'center',
    marginTop: 12,
  },
  previewActions: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 16,
    marginTop: 16,
    paddingTop: 16,
    borderTopWidth: 1,
    borderTopColor: '#e5e5ea',
  },
  actionButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingVertical: 8,
    paddingHorizontal: 16,
    borderRadius: 8,
    backgroundColor: '#f8f8f8',
  },
  actionButtonText: {
    fontSize: 14,
    fontWeight: '600',
  },
  infoCard: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    padding: 12,
    gap: 8,
    backgroundColor: '#f8f8f8',
    borderRadius: 8,
  },
  infoText: {
    flex: 1,
    fontSize: 13,
    color: '#8E8E93',
    lineHeight: 18,
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
