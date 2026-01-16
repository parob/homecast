import { useCallback, useState, useMemo, useEffect } from 'react';
import {
  StyleSheet,
  RefreshControl,
  TouchableOpacity,
  ActivityIndicator,
  SectionList,
  View,
  Dimensions,
  Image,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { useSafeAreaInsets, SafeAreaView } from 'react-native-safe-area-context';
import { BlurView } from '@react-native-community/blur';
import { useQuery, useMutation } from '@apollo/client/react';
import FontAwesome from '@expo/vector-icons/FontAwesome';
import * as Haptics from 'expo-haptics';

import { Text } from '@/components/Themed';
import { HOMES_QUERY, ACCESSORIES_QUERY, ROOMS_QUERY, SERVICE_GROUPS_QUERY, COLLECTIONS_QUERY } from '@/api/graphql/queries';
import { SET_CHARACTERISTIC_MUTATION, SET_SERVICE_GROUP_MUTATION } from '@/api/graphql/mutations';
import { useWebSocket, markLocalChange } from '@/providers/WebSocketProvider';
import { useAccessoryStore } from '@/stores/accessoryStore';
import { useHomeStore } from '@/stores/homeStore';
import { stringifyCharacteristicValue } from '@/types/homekit';
import { AccessoryWidget, ServiceGroupWidget, getPrimaryServiceType, getCharacteristic, DeviceControlModal } from '@/components/widgets';
import { CategoryChips } from '@/components/home/CategoryChips';
import { SectionHeader } from '@/components/home/SectionHeader';
import { AppleHomeColors } from '@/constants/Colors';
import type { Home, Accessory, Room, ServiceGroup } from '@/types/homekit';
import type { SetCharacteristicResult, SetServiceGroupResult, Collection } from '@/types/api';

const SCREEN_WIDTH = Dimensions.get('window').width;

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

function parseCollectionPayload(payloadStr: string): CollectionPayload {
  try {
    const parsed = JSON.parse(payloadStr || '{"items":[],"groups":[]}');
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

interface HomeScreenProps {
  initialHomeId?: string;
  initialCollectionId?: string;
}

export default function HomeScreen({ initialHomeId, initialCollectionId }: HomeScreenProps = {}) {
  const insets = useSafeAreaInsets();
  const { isConnected } = useWebSocket();
  const { selectedHomeId: globalSelectedHomeId, setSelectedHomeId } = useHomeStore();

  // Use initial props if provided, otherwise fall back to global state
  const selectedHomeId = initialHomeId || globalSelectedHomeId;
  const selectedCollectionId = initialCollectionId || null;

  const [expandedAccessory, setExpandedAccessory] = useState<Accessory | null>(null);
  const [expandedGroup, setExpandedGroup] = useState<ServiceGroup | null>(null);
  const [selectedRoomId, setSelectedRoomId] = useState<string | null>(null);
  const [selectedGroupId, setSelectedGroupId] = useState<string | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);

  const { updateCharacteristic, getCharacteristicValue, revertOptimistic } = useAccessoryStore();
  const [setCharacteristic] = useMutation<{ setCharacteristic: SetCharacteristicResult }>(SET_CHARACTERISTIC_MUTATION);
  const [setServiceGroup] = useMutation<{ setServiceGroup: SetServiceGroupResult }>(SET_SERVICE_GROUP_MUTATION);

  // Fetch homes
  const {
    data: homesData,
    loading: homesLoading,
    error: homesError,
    refetch: refetchHomes,
  } = useQuery<{ homes: Home[] }>(HOMES_QUERY);

  // Fetch rooms for selected home
  const {
    data: roomsData,
    refetch: refetchRooms,
  } = useQuery<{ rooms: Room[] }>(ROOMS_QUERY, {
    variables: { homeId: selectedHomeId },
    skip: !selectedHomeId,
  });

  // Fetch accessories for selected home (or all if viewing collection)
  const {
    data: accessoriesData,
    loading: accessoriesLoading,
    refetch: refetchAccessories,
  } = useQuery<{ accessories: Accessory[] }>(ACCESSORIES_QUERY, {
    variables: selectedCollectionId ? {} : { homeId: selectedHomeId },
    skip: !selectedHomeId && !selectedCollectionId,
  });

  // Fetch service groups for selected home
  const {
    data: serviceGroupsData,
    refetch: refetchServiceGroups,
  } = useQuery<{ serviceGroups: ServiceGroup[] }>(SERVICE_GROUPS_QUERY, {
    variables: { homeId: selectedHomeId },
    skip: !selectedHomeId,
  });

  // Fetch collections
  const {
    data: collectionsData,
    refetch: refetchCollections,
  } = useQuery<{ collections: Collection[] }>(COLLECTIONS_QUERY);

  const homes = homesData?.homes || [];
  const rooms = roomsData?.rooms || [];
  const accessories = accessoriesData?.accessories || [];
  const serviceGroups = serviceGroupsData?.serviceGroups || [];
  const collections = collectionsData?.collections || [];

  // Get set of accessory IDs that are in groups (to hide them)
  const groupedAccessoryIds = useMemo(() => {
    const ids = new Set<string>();
    for (const group of serviceGroups) {
      for (const accId of group.accessoryIds) {
        ids.add(accId);
      }
    }
    return ids;
  }, [serviceGroups]);

  // Get accessories for a specific group
  const getGroupAccessories = useCallback((group: ServiceGroup): Accessory[] => {
    return accessories.filter(acc => group.accessoryIds.includes(acc.id));
  }, [accessories]);

  // Auto-select first home if none selected
  useEffect(() => {
    if (!selectedHomeId && homes.length > 0) {
      setSelectedHomeId(homes[0].id);
    }
  }, [selectedHomeId, homes, setSelectedHomeId]);

  const selectedHome = homes.find(h => h.id === selectedHomeId);
  const selectedRoom = rooms.find(r => r.id === selectedRoomId);
  const selectedCollection = collections.find(c => c.id === selectedCollectionId);

  // Parse selected collection payload
  const collectionPayload = useMemo(() => {
    if (!selectedCollection) return null;
    return parseCollectionPayload(selectedCollection.payload);
  }, [selectedCollection]);

  // Get the selected collection group name
  const selectedCollectionGroup = useMemo(() => {
    if (!collectionPayload || !selectedGroupId) return null;
    return collectionPayload.groups.find(g => g.id === selectedGroupId);
  }, [collectionPayload, selectedGroupId]);

  // Item type for rendering (either accessory or group)
  type RenderItem = { type: 'accessory'; accessory: Accessory } | { type: 'group'; group: ServiceGroup };

  // Determine the room for a service group based on its accessories
  const getGroupRoom = useCallback((group: ServiceGroup): string | null => {
    const groupAccessories = accessories.filter(acc => group.accessoryIds.includes(acc.id));
    if (groupAccessories.length === 0) return null;

    // Use the room of the first accessory, or find the most common room
    const roomCounts: Record<string, number> = {};
    for (const acc of groupAccessories) {
      if (acc.roomName) {
        roomCounts[acc.roomName] = (roomCounts[acc.roomName] || 0) + 1;
      }
    }

    let maxRoom: string | null = null;
    let maxCount = 0;
    for (const [room, count] of Object.entries(roomCounts)) {
      if (count > maxCount) {
        maxCount = count;
        maxRoom = room;
      }
    }
    return maxRoom;
  }, [accessories]);

  // Filter and group accessories based on current selection
  const groupedAccessories = useMemo(() => {
    let filteredAccessories = accessories;
    let filteredServiceGroups = serviceGroups;
    let showRoomSections = true;

    // Filter by collection if selected
    if (selectedCollectionId && collectionPayload) {
      const collectionAccessoryIds = new Set(
        collectionPayload.items
          .filter(item => {
            if (!item.accessory_id) return false;
            // If a group is selected, only show items from that group
            if (selectedGroupId) {
              return item.group_id === selectedGroupId;
            }
            return true;
          })
          .map(item => item.accessory_id!)
      );

      filteredAccessories = accessories.filter(acc => collectionAccessoryIds.has(acc.id));
      // Don't show service groups when viewing a collection
      filteredServiceGroups = [];
      // Show room sections for collections (group by room within collection)
      showRoomSections = true;
    }
    // Filter by room if selected (only when not viewing a collection)
    else if (selectedRoomId && selectedRoom) {
      filteredAccessories = accessories.filter(acc => acc.roomId === selectedRoomId);
      // Filter service groups to only those with accessories in this room
      filteredServiceGroups = serviceGroups.filter(group => {
        const groupRoom = getGroupRoom(group);
        return groupRoom === selectedRoom.name;
      });
      // Don't show room sections when viewing a single room
      showRoomSections = false;
    }

    const roomGroups: Record<string, RenderItem[]> = {};
    const noRoom: RenderItem[] = [];

    // Add service groups to their respective rooms
    for (const group of filteredServiceGroups) {
      const room = getGroupRoom(group);
      const item: RenderItem = { type: 'group', group };

      if (room && showRoomSections) {
        if (!roomGroups[room]) {
          roomGroups[room] = [];
        }
        roomGroups[room].unshift(item);
      } else {
        noRoom.unshift(item);
      }
    }

    // Then add ungrouped accessories
    for (const acc of filteredAccessories) {
      // Skip accessories that are in a service group (unless viewing collection)
      if (!selectedCollectionId && groupedAccessoryIds.has(acc.id)) continue;

      const item: RenderItem = { type: 'accessory', accessory: acc };

      if (acc.roomName && showRoomSections) {
        if (!roomGroups[acc.roomName]) {
          roomGroups[acc.roomName] = [];
        }
        roomGroups[acc.roomName].push(item);
      } else {
        noRoom.push(item);
      }
    }

    // Convert to section data
    const sections: Array<{ title: string; data: RenderItem[][] }> = [];

    // Add room sections
    const roomSections = Object.entries(roomGroups)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([title, data]) => ({
        title,
        data: chunkArray(data, 2),
      }));
    sections.push(...roomSections);

    if (noRoom.length > 0) {
      sections.push({
        title: showRoomSections ? 'Other' : '',
        data: chunkArray(noRoom, 2),
      });
    }

    return sections;
  }, [accessories, serviceGroups, groupedAccessoryIds, getGroupRoom, selectedRoomId, selectedRoom, selectedCollectionId, collectionPayload, selectedGroupId]);

  const onRefresh = useCallback(async () => {
    setIsRefreshing(true);
    try {
      await refetchHomes();
      await refetchCollections();
      if (selectedHomeId) {
        await Promise.all([refetchRooms(), refetchAccessories(), refetchServiceGroups()]);
      }
    } finally {
      setIsRefreshing(false);
    }
  }, [refetchHomes, refetchRooms, refetchAccessories, refetchServiceGroups, refetchCollections, selectedHomeId]);

  // Handle toggle
  const handleToggle = async (accessoryId: string, characteristicType: string, currentValue: boolean) => {
    const newValue = !currentValue;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    markLocalChange(accessoryId, characteristicType);
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
    markLocalChange(accessoryId, characteristicType);
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

  // Handle service group toggle
  const handleGroupToggle = async (groupId: string, characteristicType: string, currentValue: boolean) => {
    const newValue = !currentValue;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);

    // Find the group and optimistically update all its accessories
    const group = serviceGroups.find(g => g.id === groupId);
    if (group) {
      for (const accId of group.accessoryIds) {
        markLocalChange(accId, characteristicType);
        updateCharacteristic(accId, characteristicType, newValue, true);
      }
    }

    try {
      const { data } = await setServiceGroup({
        variables: {
          homeId: selectedHomeId,
          groupId,
          characteristicType,
          value: stringifyCharacteristicValue(newValue),
        },
      });
      if (data?.setServiceGroup?.success) {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      } else {
        // Revert all accessories in group
        if (group) {
          for (const accId of group.accessoryIds) {
            revertOptimistic(accId, characteristicType);
          }
        }
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      }
    } catch {
      if (group) {
        for (const accId of group.accessoryIds) {
          revertOptimistic(accId, characteristicType);
        }
      }
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
    }
  };

  const isLoading = homesLoading || accessoriesLoading;

  // Determine the page title based on selection (moved before early returns for hooks consistency)
  const pageTitle = useMemo(() => {
    if (selectedCollectionId && selectedCollection) {
      if (selectedGroupId && selectedCollectionGroup) {
        return selectedCollectionGroup.name;
      }
      return selectedCollection.name;
    }
    if (selectedRoomId && selectedRoom) {
      return selectedRoom.name;
    }
    return selectedHome?.name || 'Home';
  }, [selectedCollectionId, selectedCollection, selectedGroupId, selectedCollectionGroup, selectedRoomId, selectedRoom, selectedHome]);

  // Get accessories for category chips (filtered to current view)
  const displayedAccessories = useMemo(() => {
    if (selectedCollectionId && collectionPayload) {
      const collectionAccessoryIds = new Set(
        collectionPayload.items
          .filter(item => {
            if (!item.accessory_id) return false;
            if (selectedGroupId) {
              return item.group_id === selectedGroupId;
            }
            return true;
          })
          .map(item => item.accessory_id!)
      );
      return accessories.filter(acc => collectionAccessoryIds.has(acc.id));
    }
    if (selectedRoomId) {
      return accessories.filter(acc => acc.roomId === selectedRoomId);
    }
    return accessories;
  }, [accessories, selectedCollectionId, collectionPayload, selectedGroupId, selectedRoomId]);

  // Loading state
  if (homesLoading && homes.length === 0) {
    return (
      <View style={styles.container}>
        <View style={styles.centerContainer}>
          <ActivityIndicator size="large" color="#000" />
          <Text style={styles.loadingText}>Loading homes...</Text>
        </View>
      </View>
    );
  }

  // Empty state
  if (homes.length === 0) {
    return (
      <View style={styles.container}>
        <View style={styles.centerContainer}>
          <FontAwesome name="home" size={64} color="rgba(0,0,0,0.3)" />
          <Text style={styles.emptyTitle}>No Homes Found</Text>
          {homesError ? (
            <Text style={styles.errorText}>Error: {homesError.message}</Text>
          ) : (
            <Text style={styles.emptyText}>
              Make sure your Mac app is connected and has access to HomeKit.
            </Text>
          )}
          <TouchableOpacity style={styles.refreshButton} onPress={onRefresh}>
            <Text style={styles.refreshButtonText}>Refresh</Text>
          </TouchableOpacity>
        </View>
      </View>
    );
  }

  // List header component (scrolls with content)
  const headerHeight = insets.top + 52;
  const ListHeader = () => (
    <View style={[styles.listHeader, { paddingTop: headerHeight + 8 }]}>
      {/* Page title */}
      <Text style={styles.homeTitle}>{pageTitle}</Text>
      {/* Category chips */}
      <CategoryChips accessories={displayedAccessories} />
    </View>
  );

  return (
    <View style={styles.container}>
      {/* Fixed header - logo and controls with blur */}
      <BlurView
        blurType="light"
        blurAmount={20}
        style={[styles.fixedHeader, { height: insets.top + 52 }]}
      >
        <View style={[styles.headerTop, { marginTop: insets.top }]}>
          <Image
            source={require('@/assets/images/icon.png')}
            style={styles.headerLogo}
          />
          <Text style={styles.headerTitle}>Homecast</Text>
          <View style={styles.headerTopSpacer} />
          <TouchableOpacity style={styles.menuButton}>
            <FontAwesome name="ellipsis-h" size={18} color="#000000" />
          </TouchableOpacity>
        </View>
      </BlurView>

      {/* Scrollable content */}
      {groupedAccessories.length === 0 && !accessoriesLoading ? (
        <View style={[styles.emptyAccessories, { marginTop: insets.top + 60 }]}>
          <Text style={styles.emptyText}>
            {selectedCollectionId
              ? 'No accessories in this collection'
              : selectedRoomId
              ? 'No accessories in this room'
              : 'No accessories in this home'}
          </Text>
        </View>
      ) : (
        <SectionList
          key={`${selectedHomeId}-${selectedCollectionId}-${selectedRoomId}`}
          sections={groupedAccessories}
          ListHeaderComponent={ListHeader}
          keyExtractor={(item, index) => `row-${index}`}
          scrollsToTop={false}
          scrollIndicatorInsets={{ top: 60 }}
          renderSectionHeader={({ section: { title } }) => (
            <SectionHeader title={title} />
          )}
          renderItem={({ item: row }) => (
            <View style={styles.row}>
              {row.map((item, idx) => {
                if (item.type === 'group') {
                  const groupAccessories = getGroupAccessories(item.group);
                  return (
                    <ServiceGroupWidget
                      key={item.group.id}
                      groupId={item.group.id}
                      groupName={item.group.name}
                      accessories={groupAccessories}
                      onToggle={handleGroupToggle}
                      onCardPress={() => {
                        setExpandedGroup(item.group);
                      }}
                    />
                  );
                } else {
                  return (
                    <AccessoryWidget
                      key={item.accessory.id}
                      accessory={item.accessory}
                      onCardPress={() => setExpandedAccessory(item.accessory)}
                    />
                  );
                }
              })}
              {row.length === 1 && <View style={styles.placeholder} />}
            </View>
          )}
          contentContainerStyle={styles.listContent}
          refreshControl={
            <RefreshControl
              refreshing={isRefreshing}
              onRefresh={onRefresh}
              tintColor="#000"
            />
          }
          ListFooterComponent={<View style={{ height: 100 }} />}
          stickySectionHeadersEnabled={false}
        />
      )}

      {/* Device control modal - single accessory */}
      {expandedAccessory && !expandedGroup && (() => {
        const serviceType = getPrimaryServiceType(expandedAccessory);

        // Power state - check multiple possible characteristic types
        const powerChar = getCharacteristic(expandedAccessory, 'power_state') ||
                          getCharacteristic(expandedAccessory, 'on') ||
                          getCharacteristic(expandedAccessory, 'active');
        const powerType = powerChar?.type || 'power_state';
        const powerValue = getEffectiveValue(expandedAccessory.id, powerType, powerChar?.value);
        const isOn = powerValue === true || powerValue === 1;

        // Light characteristics
        const brightnessChar = getCharacteristic(expandedAccessory, 'brightness');
        const colorTempChar = getCharacteristic(expandedAccessory, 'color_temperature');
        const hueChar = getCharacteristic(expandedAccessory, 'hue');
        const saturationChar = getCharacteristic(expandedAccessory, 'saturation');
        const brightness = getEffectiveValue(expandedAccessory.id, 'brightness', brightnessChar?.value);
        const colorTemp = getEffectiveValue(expandedAccessory.id, 'color_temperature', colorTempChar?.value);
        const hue = getEffectiveValue(expandedAccessory.id, 'hue', hueChar?.value);
        const saturation = getEffectiveValue(expandedAccessory.id, 'saturation', saturationChar?.value);

        // Debug: log available characteristics for lights
        if (serviceType === 'lightbulb') {
          const allChars = expandedAccessory.services?.flatMap(s => s.characteristics?.map(c => c.characteristicType) || []) || [];
          console.log('[Light]', expandedAccessory.name, 'chars:', allChars.filter(c => !['firmware_revision', 'serial_number', 'hardware_revision', 'manufacturer', 'identify', 'model', 'name'].includes(c)));
        }

        // Thermostat characteristics
        const currentTempChar = getCharacteristic(expandedAccessory, 'current_temperature');
        const targetTempChar = getCharacteristic(expandedAccessory, 'target_temperature') ||
                               getCharacteristic(expandedAccessory, 'heating_threshold');
        const heatingModeChar = getCharacteristic(expandedAccessory, 'target_heating_cooling_state');
        const currentTemp = currentTempChar?.value;
        const targetTemp = targetTempChar?.value;
        const heatingMode = heatingModeChar?.value;

        // Get thermostat mode
        const getThermostatMode = (): 'heat' | 'cool' | 'auto' | 'off' => {
          if (heatingMode === 0) return 'off';
          if (heatingMode === 1) return 'heat';
          if (heatingMode === 2) return 'cool';
          if (heatingMode === 3) return 'auto';
          return 'heat';  // Default
        };

        // Fan characteristics
        const fanSpeedChar = getCharacteristic(expandedAccessory, 'rotation_speed');
        const fanSpeed = fanSpeedChar?.value;

        // Lock characteristics
        const lockTargetChar = getCharacteristic(expandedAccessory, 'lock_target_state');
        const lockCurrentChar = getCharacteristic(expandedAccessory, 'lock_current_state');
        const isLocked = lockCurrentChar?.value === 1;

        return (
          <DeviceControlModal
            visible={!!expandedAccessory}
            accessory={expandedAccessory}
            serviceType={serviceType}
            isOn={serviceType === 'lock' ? isLocked : isOn}
            // Light props
            brightness={brightness !== null && brightness !== undefined ? Number(brightness) : undefined}
            colorTemperature={colorTemp !== null && colorTemp !== undefined ? Number(colorTemp) : undefined}
            hue={hue !== null && hue !== undefined ? Number(hue) : undefined}
            saturation={saturation !== null && saturation !== undefined ? Number(saturation) : undefined}
            onBrightnessChange={brightnessChar ? (value) => handleSlider(expandedAccessory.id, 'brightness', value) : undefined}
            onBrightnessChangeLive={brightnessChar ? (value) => handleSlider(expandedAccessory.id, 'brightness', value) : undefined}
            onColorTemperatureChange={colorTempChar ? (value) => handleSlider(expandedAccessory.id, 'color_temperature', value) : undefined}
            onHueChange={hueChar ? (value) => handleSlider(expandedAccessory.id, 'hue', value) : undefined}
            onSaturationChange={saturationChar ? (value) => handleSlider(expandedAccessory.id, 'saturation', value) : undefined}
            // Thermostat props
            currentTemperature={currentTemp !== null && currentTemp !== undefined ? Number(currentTemp) : undefined}
            targetTemperature={targetTemp !== null && targetTemp !== undefined ? Number(targetTemp) : undefined}
            thermostatMode={getThermostatMode()}
            onTargetTemperatureChange={targetTempChar ? (value) => handleSlider(expandedAccessory.id, targetTempChar.type, value) : undefined}
            onModeChange={heatingModeChar?.isWritable ? (mode) => {
              const modeMap: Record<string, number> = { off: 0, heat: 1, cool: 2, auto: 3 };
              handleSlider(expandedAccessory.id, 'target_heating_cooling_state', modeMap[mode] ?? 1);
            } : undefined}
            // Fan props
            fanSpeed={fanSpeed !== null && fanSpeed !== undefined ? Number(fanSpeed) : undefined}
            onFanSpeedChange={fanSpeedChar ? (value) => handleSlider(expandedAccessory.id, 'rotation_speed', value) : undefined}
            onFanSpeedChangeLive={fanSpeedChar ? (value) => handleSlider(expandedAccessory.id, 'rotation_speed', value) : undefined}
            // Common
            onClose={() => setExpandedAccessory(null)}
            onToggle={() => {
              if (serviceType === 'lock' && lockTargetChar) {
                handleToggle(expandedAccessory.id, 'lock_target_state', isLocked);
              } else if (powerChar) {
                handleToggle(expandedAccessory.id, powerChar.type, isOn);
              }
            }}
          />
        );
      })()}

      {/* Device control modal - service group */}
      {expandedGroup && (() => {
        const groupAccessories = accessories.filter(acc => expandedGroup.accessoryIds.includes(acc.id));
        if (groupAccessories.length === 0) return null;

        // Determine group service type (most common among members)
        const typeCounts: Record<string, number> = {};
        for (const acc of groupAccessories) {
          const type = getPrimaryServiceType(acc);
          if (type) typeCounts[type] = (typeCounts[type] || 0) + 1;
        }
        let serviceType: string | null = null;
        let maxCount = 0;
        for (const [type, count] of Object.entries(typeCounts)) {
          if (count > maxCount) { maxCount = count; serviceType = type; }
        }

        // Aggregate power state - any on = group on (use effective values)
        let onCount = 0;
        for (const acc of groupAccessories) {
          const powerChar = getCharacteristic(acc, 'power_state') || getCharacteristic(acc, 'on');
          const powerType = powerChar?.type || 'power_state';
          const powerValue = getEffectiveValue(acc.id, powerType, powerChar?.value);
          if (powerValue === true || powerValue === 1) onCount++;
        }
        const isOn = onCount > 0;

        // Aggregate brightness - average of on lights (use effective values from store)
        let totalBrightness = 0;
        let brightnessCount = 0;
        for (const acc of groupAccessories) {
          const powerChar = getCharacteristic(acc, 'power_state') || getCharacteristic(acc, 'on');
          const brightnessChar = getCharacteristic(acc, 'brightness');
          const powerType = powerChar?.type || 'power_state';
          const powerValue = getEffectiveValue(acc.id, powerType, powerChar?.value);
          const accIsOn = powerValue === true || powerValue === 1;
          if (accIsOn && brightnessChar) {
            const effectiveBrightness = getEffectiveValue(acc.id, 'brightness', brightnessChar.value);
            if (effectiveBrightness !== undefined && effectiveBrightness !== null) {
              totalBrightness += Number(effectiveBrightness);
              brightnessCount++;
            }
          }
        }
        const avgBrightness = brightnessCount > 0 ? Math.round(totalBrightness / brightnessCount) : 100;

        // Check if any accessory supports color temperature/hue/saturation
        const hasColorTempSupport = groupAccessories.some(acc => getCharacteristic(acc, 'color_temperature'));
        const hasHueSupport = groupAccessories.some(acc => getCharacteristic(acc, 'hue'));
        const hasSaturationSupport = groupAccessories.some(acc => getCharacteristic(acc, 'saturation'));

        // Get initial color temperature from first accessory that has it
        let groupColorTemp: number | undefined;
        for (const acc of groupAccessories) {
          const colorTempChar = getCharacteristic(acc, 'color_temperature');
          if (colorTempChar && groupColorTemp === undefined) {
            groupColorTemp = getEffectiveValue(acc.id, 'color_temperature', colorTempChar.value) as number;
            break;
          }
        }

        // Get initial hue/saturation from first accessory that has it
        let groupHue: number | undefined;
        let groupSaturation: number | undefined;
        for (const acc of groupAccessories) {
          const hueChar = getCharacteristic(acc, 'hue');
          const satChar = getCharacteristic(acc, 'saturation');
          if (hueChar && groupHue === undefined) {
            groupHue = getEffectiveValue(acc.id, 'hue', hueChar.value) as number;
          }
          if (satChar && groupSaturation === undefined) {
            groupSaturation = getEffectiveValue(acc.id, 'saturation', satChar.value) as number;
          }
        }

        // Handle group brightness change - use setServiceGroup mutation (updates all at once)
        const handleGroupBrightnessChange = async (value: number) => {
          // Optimistically update all accessories
          for (const acc of groupAccessories) {
            const brightnessChar = getCharacteristic(acc, 'brightness');
            if (brightnessChar) {
              markLocalChange(acc.id, 'brightness');
              updateCharacteristic(acc.id, 'brightness', value, true);
            }
          }

          try {
            const { data } = await setServiceGroup({
              variables: {
                homeId: selectedHomeId,
                groupId: expandedGroup.id,
                characteristicType: 'brightness',
                value: stringifyCharacteristicValue(value),
              },
            });
            if (!data?.setServiceGroup?.success) {
              // Revert all on failure
              for (const acc of groupAccessories) {
                revertOptimistic(acc.id, 'brightness');
              }
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
            }
          } catch {
            for (const acc of groupAccessories) {
              revertOptimistic(acc.id, 'brightness');
            }
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
          }
        };

        // Handle group hue change
        const handleGroupHueChange = async (value: number) => {
          for (const acc of groupAccessories) {
            const hueChar = getCharacteristic(acc, 'hue');
            if (hueChar) {
              markLocalChange(acc.id, 'hue');
              updateCharacteristic(acc.id, 'hue', value, true);
            }
          }
          try {
            const { data } = await setServiceGroup({
              variables: {
                homeId: selectedHomeId,
                groupId: expandedGroup.id,
                characteristicType: 'hue',
                value: stringifyCharacteristicValue(value),
              },
            });
            if (!data?.setServiceGroup?.success) {
              for (const acc of groupAccessories) {
                revertOptimistic(acc.id, 'hue');
              }
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
            }
          } catch {
            for (const acc of groupAccessories) {
              revertOptimistic(acc.id, 'hue');
            }
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
          }
        };

        // Handle group saturation change
        const handleGroupSaturationChange = async (value: number) => {
          for (const acc of groupAccessories) {
            const satChar = getCharacteristic(acc, 'saturation');
            if (satChar) {
              markLocalChange(acc.id, 'saturation');
              updateCharacteristic(acc.id, 'saturation', value, true);
            }
          }
          try {
            const { data } = await setServiceGroup({
              variables: {
                homeId: selectedHomeId,
                groupId: expandedGroup.id,
                characteristicType: 'saturation',
                value: stringifyCharacteristicValue(value),
              },
            });
            if (!data?.setServiceGroup?.success) {
              for (const acc of groupAccessories) {
                revertOptimistic(acc.id, 'saturation');
              }
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
            }
          } catch {
            for (const acc of groupAccessories) {
              revertOptimistic(acc.id, 'saturation');
            }
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
          }
        };

        // Handle group color temperature change
        const handleGroupColorTempChange = async (value: number) => {
          for (const acc of groupAccessories) {
            const colorTempChar = getCharacteristic(acc, 'color_temperature');
            if (colorTempChar) {
              markLocalChange(acc.id, 'color_temperature');
              updateCharacteristic(acc.id, 'color_temperature', value, true);
            }
          }
          try {
            const { data } = await setServiceGroup({
              variables: {
                homeId: selectedHomeId,
                groupId: expandedGroup.id,
                characteristicType: 'color_temperature',
                value: stringifyCharacteristicValue(value),
              },
            });
            if (!data?.setServiceGroup?.success) {
              for (const acc of groupAccessories) {
                revertOptimistic(acc.id, 'color_temperature');
              }
              Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
            }
          } catch {
            for (const acc of groupAccessories) {
              revertOptimistic(acc.id, 'color_temperature');
            }
            Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
          }
        };

        // Handle group toggle - toggle all accessories
        const handleGroupToggleModal = () => {
          handleGroupToggle(expandedGroup.id, 'power_state', isOn);
        };

        // Create a fake accessory for the modal display
        // Get room name from first accessory that has one (for display name stripping)
        const groupRoomName = groupAccessories.find(acc => acc.roomName)?.roomName;
        const fakeAccessory: Accessory = {
          id: expandedGroup.id,
          name: expandedGroup.name,
          roomName: groupRoomName,
          category: 'lightbulb',
          isReachable: groupAccessories.some(acc => acc.isReachable),
          services: [],
        };

        return (
          <DeviceControlModal
            visible={!!expandedGroup}
            accessory={fakeAccessory}
            serviceType={serviceType as any}
            isOn={isOn}
            brightness={avgBrightness}
            colorTemperature={groupColorTemp}
            hue={groupHue}
            saturation={groupSaturation}
            onBrightnessChange={handleGroupBrightnessChange}
            onBrightnessChangeLive={handleGroupBrightnessChange}
            onColorTemperatureChange={hasColorTempSupport ? handleGroupColorTempChange : undefined}
            onHueChange={hasHueSupport ? handleGroupHueChange : undefined}
            onSaturationChange={hasSaturationSupport ? handleGroupSaturationChange : undefined}
            onClose={() => setExpandedGroup(null)}
            onToggle={handleGroupToggleModal}
          />
        );
      })()}

    </View>
  );
}

// Helper to chunk array into pairs for 2-column layout
function chunkArray<T>(arr: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < arr.length; i += size) {
    chunks.push(arr.slice(i, i + size));
  }
  return chunks;
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#FFFFFF',
  },
  centerContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 24,
  },
  fixedHeader: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    zIndex: 10,
  },
  listHeader: {
    paddingBottom: 8,
  },
  headerTop: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 16,
    height: 52,
  },
  headerLogo: {
    width: 28,
    height: 28,
    borderRadius: 6,
  },
  headerTitle: {
    fontSize: 17,
    fontWeight: '600',
    color: '#000000',
    marginLeft: 8,
  },
  headerTopSpacer: {
    flex: 1,
  },
  menuButton: {
    padding: 8,
  },
  homeTitle: {
    fontSize: 34,
    fontWeight: '700',
    color: '#000000',
    paddingHorizontal: 16,
    marginTop: 8,
  },
  row: {
    flexDirection: 'row',
    paddingHorizontal: 16,
  },
  placeholder: {
    flex: 1,
    margin: 4,
  },
  loadingText: {
    marginTop: 16,
    color: 'rgba(0,0,0,0.5)',
    fontSize: 16,
  },
  emptyTitle: {
    fontSize: 24,
    fontWeight: '600',
    marginTop: 16,
    marginBottom: 8,
    color: '#000000',
  },
  emptyText: {
    fontSize: 16,
    color: 'rgba(0,0,0,0.5)',
    textAlign: 'center',
  },
  errorText: {
    fontSize: 14,
    color: '#FF3B30',
    textAlign: 'center',
    marginTop: 8,
    paddingHorizontal: 16,
  },
  emptyAccessories: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  refreshButton: {
    marginTop: 24,
    backgroundColor: 'rgba(0,0,0,0.06)',
    paddingHorizontal: 24,
    paddingVertical: 12,
    borderRadius: 20,
  },
  refreshButtonText: {
    color: '#000000',
    fontWeight: '600',
    fontSize: 16,
  },
  listContent: {
    paddingTop: 8,
  },
});
