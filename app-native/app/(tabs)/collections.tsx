import { useCallback, useState, useMemo } from 'react';
import {
  StyleSheet,
  RefreshControl,
  TouchableOpacity,
  ActivityIndicator,
  FlatList,
  SectionList,
  ScrollView,
  View,
} from 'react-native';
import { useQuery, useMutation } from '@apollo/client/react';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';

import { Text } from '@/components/Themed';
import { COLLECTIONS_QUERY, ACCESSORIES_QUERY } from '@/api/graphql/queries';
import { SET_CHARACTERISTIC_MUTATION } from '@/api/graphql/mutations';
import { useAccessoryStore } from '@/stores/accessoryStore';
import { stringifyCharacteristicValue } from '@/types/homekit';
import { AccessoryWidget, COLORS } from '@/components/widgets';
import { ExpandedWidgetModal } from '@/components/widgets/ExpandedWidgetModal';
import type { Collection, SetCharacteristicResult } from '@/types/api';
import type { Accessory } from '@/types/homekit';

interface CollectionPayload {
  items: Array<{
    home_id: string;
    accessory_id?: string;
    service_group_id?: string;
    group_id?: string;
  }>;
  groups: Array<{
    id: string;
    name: string;
  }>;
}

function parsePayload(payloadStr: string): CollectionPayload {
  try {
    const parsed = JSON.parse(payloadStr || '{"items":[],"groups":[]}');
    // Handle old format (array of items)
    if (Array.isArray(parsed)) {
      return { items: parsed, groups: [] };
    }
    return {
      items: parsed.items || [],
      groups: parsed.groups || [],
    };
  } catch {
    return { items: [], groups: [] };
  }
}

// Helper to chunk array into pairs for 2-column layout
function chunkArray<T>(arr: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < arr.length; i += size) {
    chunks.push(arr.slice(i, i + size));
  }
  return chunks;
}

export default function CollectionsScreen() {
  const [selectedCollection, setSelectedCollection] = useState<Collection | null>(null);
  const [selectedGroupId, setSelectedGroupId] = useState<string | null>(null);
  const [expandedAccessory, setExpandedAccessory] = useState<Accessory | null>(null);

  const { updateCharacteristic, getCharacteristicValue, revertOptimistic } = useAccessoryStore();
  const [setCharacteristic] = useMutation<{ setCharacteristic: SetCharacteristicResult }>(SET_CHARACTERISTIC_MUTATION);

  const { data, loading, refetch } = useQuery<{ collections: Collection[] }>(COLLECTIONS_QUERY);
  const { data: accessoriesData } = useQuery<{ accessories: Accessory[] }>(ACCESSORIES_QUERY, {
    skip: !selectedCollection,
  });

  const collections = data?.collections || [];
  const accessories = accessoriesData?.accessories || [];

  const onRefresh = useCallback(async () => {
    await refetch();
  }, [refetch]);

  // Parse selected collection payload
  const collectionPayload = useMemo(() => {
    if (!selectedCollection) return null;
    return parsePayload(selectedCollection.payload);
  }, [selectedCollection]);

  // Get accessories in collection grouped by their collection groups
  const groupedAccessories = useMemo(() => {
    if (!collectionPayload) return [];

    const accessoryMap = new Map(accessories.map(a => [a.id, a]));

    // Filter items by selected group if any
    const filteredItems = selectedGroupId
      ? collectionPayload.items.filter(item => item.group_id === selectedGroupId)
      : collectionPayload.items;

    // Group by collection group
    const groups: Record<string, Accessory[]> = {};
    const ungrouped: Accessory[] = [];

    for (const item of filteredItems) {
      if (!item.accessory_id) continue;
      const accessory = accessoryMap.get(item.accessory_id);
      if (!accessory) continue;

      if (item.group_id && !selectedGroupId) {
        const group = collectionPayload.groups.find(g => g.id === item.group_id);
        const groupName = group?.name || 'Other';
        if (!groups[groupName]) {
          groups[groupName] = [];
        }
        groups[groupName].push(accessory);
      } else {
        ungrouped.push(accessory);
      }
    }

    // Convert to section data
    const sections = Object.entries(groups)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([title, data]) => ({
        title,
        data: chunkArray(data, 2),
      }));

    if (ungrouped.length > 0) {
      if (selectedGroupId) {
        // When filtering by group, show items without a header
        sections.unshift({
          title: '',
          data: chunkArray(ungrouped, 2),
        });
      } else {
        sections.push({
          title: 'Ungrouped',
          data: chunkArray(ungrouped, 2),
        });
      }
    }

    return sections;
  }, [collectionPayload, accessories, selectedGroupId]);

  // Handle toggle
  const handleToggle = async (accessoryId: string, characteristicType: string, currentValue: boolean) => {
    const newValue = !currentValue;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    updateCharacteristic(accessoryId, characteristicType, newValue, true);

    try {
      const { data } = await setCharacteristic({
        variables: {
          accessoryId,
          characteristicType,
          value: stringifyCharacteristicValue(newValue),
        },
      });
      if (data?.setCharacteristic?.success) {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      } else {
        revertOptimistic(accessoryId, characteristicType);
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      }
    } catch {
      revertOptimistic(accessoryId, characteristicType);
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
    }
  };

  // Handle slider
  const handleSlider = async (accessoryId: string, characteristicType: string, value: number) => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    updateCharacteristic(accessoryId, characteristicType, value, true);

    try {
      const { data } = await setCharacteristic({
        variables: {
          accessoryId,
          characteristicType,
          value: stringifyCharacteristicValue(value),
        },
      });
      if (!data?.setCharacteristic?.success) {
        revertOptimistic(accessoryId, characteristicType);
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      }
    } catch {
      revertOptimistic(accessoryId, characteristicType);
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
    }
  };

  // Get effective value
  const getEffectiveValue = (accessoryId: string, characteristicType: string, serverValue: any) => {
    const storeValue = getCharacteristicValue(accessoryId, characteristicType);
    return storeValue !== null ? storeValue : serverValue;
  };

  // Collection detail view
  if (selectedCollection) {
    const groups = collectionPayload?.groups || [];
    const itemCount = collectionPayload?.items.filter(i => i.accessory_id).length || 0;

    return (
      <View style={styles.container}>
        {/* Header */}
        <View style={styles.header}>
          <TouchableOpacity
            style={styles.backButton}
            onPress={() => {
              setSelectedCollection(null);
              setSelectedGroupId(null);
            }}
          >
            <FontAwesome name="chevron-left" size={18} color={COLORS.primary} />
            <Text style={styles.backText}>Collections</Text>
          </TouchableOpacity>
          <Text style={styles.headerTitle}>{selectedCollection.name}</Text>
          <View style={styles.headerRight} />
        </View>

        {/* Group filter tabs */}
        {groups.length > 0 && (
          <ScrollView
            horizontal
            showsHorizontalScrollIndicator={false}
            style={styles.groupTabs}
            contentContainerStyle={styles.groupTabsContent}
          >
            <TouchableOpacity
              style={[styles.groupTab, !selectedGroupId && styles.groupTabSelected]}
              onPress={() => setSelectedGroupId(null)}
            >
              <Text style={[styles.groupTabText, !selectedGroupId && styles.groupTabTextSelected]}>
                All ({itemCount})
              </Text>
            </TouchableOpacity>
            {groups.map((group) => {
              const groupItemCount = collectionPayload?.items.filter(
                i => i.group_id === group.id && i.accessory_id
              ).length || 0;
              return (
                <TouchableOpacity
                  key={group.id}
                  style={[styles.groupTab, selectedGroupId === group.id && styles.groupTabSelected]}
                  onPress={() => setSelectedGroupId(group.id)}
                >
                  <Text style={[styles.groupTabText, selectedGroupId === group.id && styles.groupTabTextSelected]}>
                    {group.name} ({groupItemCount})
                  </Text>
                </TouchableOpacity>
              );
            })}
          </ScrollView>
        )}

        {/* Accessories grouped */}
        {groupedAccessories.length === 0 ? (
          <View style={styles.emptyAccessories}>
            <FontAwesome name="lightbulb-o" size={48} color="#666" />
            <Text style={styles.emptyText}>No accessories in this collection</Text>
          </View>
        ) : (
          <SectionList
            sections={groupedAccessories}
            keyExtractor={(item, index) => `row-${index}`}
            renderSectionHeader={({ section: { title } }) =>
              title ? (
                <View style={styles.sectionHeader}>
                  <Text style={styles.sectionTitle}>{title}</Text>
                </View>
              ) : null
            }
            renderItem={({ item: row }) => (
              <View style={styles.row}>
                {row.map((accessory) => (
                  <TouchableOpacity
                    key={accessory.id}
                    onPress={() => setExpandedAccessory(accessory)}
                    activeOpacity={0.8}
                  >
                    <AccessoryWidget accessory={accessory} />
                  </TouchableOpacity>
                ))}
                {row.length === 1 && <View style={styles.placeholder} />}
              </View>
            )}
            contentContainerStyle={styles.listContent}
            refreshControl={
              <RefreshControl refreshing={loading} onRefresh={onRefresh} />
            }
            ListFooterComponent={<View style={{ height: 20 }} />}
            stickySectionHeadersEnabled={false}
          />
        )}

        {/* Expanded widget modal */}
        <ExpandedWidgetModal
          accessory={expandedAccessory}
          visible={!!expandedAccessory}
          onClose={() => setExpandedAccessory(null)}
          onToggle={handleToggle}
          onSlider={handleSlider}
          getEffectiveValue={getEffectiveValue}
        />
      </View>
    );
  }

  // Collections list view
  if (loading && collections.length === 0) {
    return (
      <View style={styles.centerContainer}>
        <ActivityIndicator size="large" />
        <Text style={styles.loadingText}>Loading collections...</Text>
      </View>
    );
  }

  if (collections.length === 0) {
    return (
      <View style={styles.centerContainer}>
        <FontAwesome name="folder-open" size={64} color="#666" />
        <Text style={styles.emptyTitle}>No Collections</Text>
        <Text style={styles.emptyText}>
          Create collections to organize your accessories and share access with others.
        </Text>
        <TouchableOpacity style={styles.createButton}>
          <FontAwesome name="plus" size={16} color="#fff" />
          <Text style={styles.createButtonText}>Create Collection</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <FlatList
        data={collections}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => {
          const payload = parsePayload(item.payload);
          const itemCount = payload.items.filter(i => i.accessory_id).length;
          const groupCount = payload.groups.length;

          return (
            <TouchableOpacity
              style={styles.collectionCard}
              onPress={() => setSelectedCollection(item)}
            >
              <View style={styles.collectionIcon}>
                <FontAwesome name="folder" size={24} color={COLORS.primary} />
              </View>
              <View style={styles.collectionInfo}>
                <Text style={styles.collectionName}>{item.name}</Text>
                <Text style={styles.collectionMeta}>
                  {itemCount} {itemCount === 1 ? 'accessory' : 'accessories'}
                  {groupCount > 0 && ` · ${groupCount} ${groupCount === 1 ? 'group' : 'groups'}`}
                </Text>
              </View>
              <FontAwesome name="chevron-right" size={16} color="#888" />
            </TouchableOpacity>
          );
        }}
        contentContainerStyle={styles.listContent}
        refreshControl={
          <RefreshControl refreshing={loading} onRefresh={onRefresh} />
        }
      />

      <TouchableOpacity style={styles.fab}>
        <FontAwesome name="plus" size={24} color="#fff" />
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f2f2f7',
  },
  centerContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 24,
    backgroundColor: '#fff',
  },
  loadingText: {
    marginTop: 16,
    color: '#888',
  },
  emptyTitle: {
    fontSize: 20,
    fontWeight: '600',
    marginTop: 16,
    marginBottom: 8,
    color: '#000',
  },
  emptyText: {
    fontSize: 14,
    color: '#888',
    textAlign: 'center',
    marginBottom: 24,
  },
  createButton: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: COLORS.primary,
    paddingHorizontal: 20,
    paddingVertical: 12,
    borderRadius: 8,
    gap: 8,
  },
  createButtonText: {
    color: '#fff',
    fontWeight: '600',
  },
  listContent: {
    padding: 16,
  },
  collectionCard: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#fff',
    padding: 16,
    borderRadius: 12,
    marginBottom: 12,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.05,
    shadowRadius: 2,
    elevation: 1,
  },
  collectionIcon: {
    width: 48,
    height: 48,
    borderRadius: 12,
    backgroundColor: 'rgba(59, 130, 246, 0.1)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  collectionInfo: {
    flex: 1,
    marginLeft: 12,
  },
  collectionName: {
    fontSize: 16,
    fontWeight: '600',
    color: '#000',
  },
  collectionMeta: {
    fontSize: 13,
    color: '#888',
    marginTop: 2,
  },
  fab: {
    position: 'absolute',
    bottom: 24,
    right: 24,
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: COLORS.primary,
    justifyContent: 'center',
    alignItems: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.25,
    shadowRadius: 4,
    elevation: 5,
  },
  // Detail view styles
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingVertical: 12,
    backgroundColor: '#fff',
    borderBottomWidth: 1,
    borderBottomColor: '#e5e5ea',
  },
  backButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
  },
  backText: {
    fontSize: 16,
    color: COLORS.primary,
  },
  headerTitle: {
    fontSize: 17,
    fontWeight: '600',
    color: '#000',
    flex: 1,
    textAlign: 'center',
  },
  headerRight: {
    width: 80, // Balance the back button
  },
  groupTabs: {
    maxHeight: 44,
    backgroundColor: '#fff',
    borderBottomWidth: 1,
    borderBottomColor: '#e5e5ea',
  },
  groupTabsContent: {
    paddingHorizontal: 12,
    paddingVertical: 8,
    gap: 8,
  },
  groupTab: {
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: 16,
    backgroundColor: '#e5e5ea',
  },
  groupTabSelected: {
    backgroundColor: COLORS.primary,
  },
  groupTabText: {
    fontSize: 13,
    color: '#3c3c43',
    fontWeight: '500',
  },
  groupTabTextSelected: {
    color: '#fff',
  },
  sectionHeader: {
    paddingHorizontal: 16,
    paddingTop: 20,
    paddingBottom: 8,
    backgroundColor: '#f2f2f7',
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: '#6b7280',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  row: {
    flexDirection: 'row',
    paddingHorizontal: 8,
  },
  placeholder: {
    flex: 1,
    margin: 4,
  },
  emptyAccessories: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 24,
  },
});
