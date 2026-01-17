import React, { useCallback } from 'react';
import { Platform, TouchableOpacity, ActionSheetIOS } from 'react-native';
import { createNativeBottomTabNavigator } from '@react-navigation/bottom-tabs/unstable';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { useNavigationState } from '@react-navigation/native';
import { useRouter } from 'expo-router';
import { useQuery } from '@apollo/client/react';
import { MenuView } from '@react-native-menu/menu';
import Ionicons from '@expo/vector-icons/Ionicons';
import { HOMES_QUERY, ROOMS_QUERY, COLLECTIONS_QUERY } from '@/api/graphql/queries';
import { usePreferencesStore, TabItem } from '@/stores/preferencesStore';
import HomeScreen from './index';
import type { Home, Room } from '@/types/homekit';
import type { Collection } from '@/types/api';

const Tab = createNativeBottomTabNavigator();
const Stack = createNativeStackNavigator();

// Tab bar icons
const homecastIcon = require('@/assets/images/homecast-tab-icon.png');

// Icon mapping for tab types
const getTabIcon = (type: TabItem['type']) => {
  const icons: Record<TabItem['type'], any> = {
    home: Platform.select({
      ios: { type: 'image', source: { uri: 'HomecastTabIcon' } },
      default: { type: 'image', source: homecastIcon },
    }),
    room: Platform.select({
      ios: { type: 'sfSymbol', name: 'door.left.hand.closed' },
      default: { type: 'image', source: homecastIcon },
    }),
    collection: Platform.select({
      ios: { type: 'sfSymbol', name: 'folder.fill' },
      default: { type: 'image', source: homecastIcon },
    }),
    serviceGroup: Platform.select({
      ios: { type: 'sfSymbol', name: 'square.grid.2x2.fill' },
      default: { type: 'image', source: homecastIcon },
    }),
  };
  return icons[type];
};

// Header menu button
function HeaderMenuButton() {
  const router = useRouter();

  return (
    <MenuView
      title=""
      onPressAction={({ nativeEvent }) => {
        if (nativeEvent.event === 'settings') {
          router.push('/settings');
        }
      }}
      actions={[
        {
          id: 'settings',
          title: 'Homecast Settings',
          image: Platform.select({
            ios: 'gear',
            android: 'ic_menu_preferences',
          }),
        },
      ]}
    >
      <TouchableOpacity style={{ padding: 8 }}>
        <Ionicons name="ellipsis-horizontal" size={22} color="#000" />
      </TouchableOpacity>
    </MenuView>
  );
}

// Parse collection payload to get groups
function parseCollectionPayload(payloadStr: string): { groups: Array<{ id: string; name: string }> } {
  try {
    const parsed = JSON.parse(payloadStr || '{"items":[],"groups":[]}');
    return {
      groups: parsed.groups || [],
    };
  } catch {
    return { groups: [] };
  }
}

// Home screen component (shows all rooms)
function HomeMainScreen({ route, navigation }: { route: any; navigation: any }) {
  const { homeId, collectionId, groupId } = route.params || {};

  return (
    <HomeScreen
      initialHomeId={homeId}
      initialCollectionId={collectionId}
      initialGroupId={groupId}
      onRoomPress={(roomId: string, roomName: string) => {
        navigation.push('Room', { homeId, roomId, roomName });
      }}
    />
  );
}

// Room screen component (shows single room)
function RoomScreen({ route }: { route: any }) {
  const { homeId, roomId } = route.params || {};

  return (
    <HomeScreen
      initialHomeId={homeId}
      initialRoomId={roomId}
    />
  );
}

// Stack navigator for each tab (enables push navigation for rooms)
function TabStackNavigator({ route, navigation }: { route: any; navigation: any }) {
  const { homeId, roomId, collectionId, groupId, tabName } = route.params || {};
  const stackNavRef = React.useRef<any>(null);

  // Fetch rooms for this home
  const { data: roomsData } = useQuery<{ rooms: Room[] }>(ROOMS_QUERY, {
    variables: { homeId },
    skip: !homeId || !!collectionId,
  });
  const rooms = roomsData?.rooms || [];

  // Fetch collections for group picker
  const { data: collectionsData } = useQuery<{ collections: Collection[] }>(COLLECTIONS_QUERY, {
    skip: !collectionId,
  });
  const collection = collectionsData?.collections?.find(c => c.id === collectionId);
  const collectionGroups = collection ? parseCollectionPayload(collection.payload).groups : [];

  // Get current state for navigation
  const currentState = useNavigationState(state => state);
  const currentRouteName = currentState?.routes[currentState.index]?.name;
  const isCurrentTab = currentRouteName === route.name;

  // Show room picker using ActionSheetIOS
  const showRoomPicker = useCallback(() => {
    if (Platform.OS !== 'ios') return;

    const options = ['All Rooms', ...rooms.map(r => r.name), 'Cancel'];
    const cancelButtonIndex = options.length - 1;

    ActionSheetIOS.showActionSheetWithOptions(
      {
        options,
        cancelButtonIndex,
      },
      (buttonIndex) => {
        if (buttonIndex === 0) {
          stackNavRef.current?.navigate('HomeMain');
        } else if (buttonIndex < cancelButtonIndex) {
          const room = rooms[buttonIndex - 1];
          stackNavRef.current?.navigate('Room', { homeId, roomId: room.id, roomName: room.name });
        }
      }
    );
  }, [rooms, homeId]);

  // Show group picker using ActionSheetIOS
  const showGroupPicker = useCallback(() => {
    if (Platform.OS !== 'ios') return;

    const options = ['All Items', ...collectionGroups.map(g => g.name), 'Cancel'];
    const cancelButtonIndex = options.length - 1;

    ActionSheetIOS.showActionSheetWithOptions(
      {
        options,
        cancelButtonIndex,
      },
      (buttonIndex) => {
        if (buttonIndex === 0) {
          navigation.setParams({ groupId: undefined });
        } else if (buttonIndex < cancelButtonIndex) {
          const group = collectionGroups[buttonIndex - 1];
          navigation.setParams({ groupId: group.id });
        }
      }
    );
  }, [collectionGroups, navigation]);

  // Listen for tab press when already focused
  React.useEffect(() => {
    const unsubscribe = navigation.addListener('tabPress', () => {
      if (isCurrentTab) {
        if (homeId && !collectionId && rooms.length > 0) {
          showRoomPicker();
        } else if (collectionId && collectionGroups.length > 0) {
          showGroupPicker();
        }
      }
    });

    return unsubscribe;
  }, [navigation, isCurrentTab, homeId, collectionId, rooms.length, collectionGroups.length, showRoomPicker, showGroupPicker]);

  // If this is a room tab, show a simple stack with just the room
  if (roomId && !collectionId) {
    return (
      <Stack.Navigator
        screenOptions={{
          headerShown: true,
          headerLargeTitle: true,
          headerTransparent: true,
          headerBackButtonDisplayMode: 'minimal',
          headerRight: () => <HeaderMenuButton />,
        }}
      >
        <Stack.Screen
          name="RoomDirect"
          component={RoomScreen}
          initialParams={{ homeId, roomId }}
          options={{ headerTitle: tabName || 'Room' }}
        />
      </Stack.Navigator>
    );
  }

  return (
    <>
      <Stack.Navigator
        screenOptions={{
          headerShown: true,
          headerLargeTitle: true,
          headerTransparent: true,
          headerBackButtonDisplayMode: 'minimal',
          headerRight: () => <HeaderMenuButton />,
        }}
      >
        <Stack.Screen
          name="HomeMain"
          component={HomeMainScreen}
          initialParams={{ homeId, collectionId, groupId }}
          options={{
            headerTitle: tabName || 'Home',
          }}
        />
        <Stack.Screen
          name="Room"
          component={RoomScreen}
          options={({ route: roomRoute }: { route: any }) => ({
            headerTitle: roomRoute.params?.roomName || 'Room',
          })}
        />
      </Stack.Navigator>
    </>
  );
}

export default function TabLayout() {
  const { data: homesData } = useQuery<{ homes: Home[] }>(HOMES_QUERY);
  const { tabItems, isHydrated } = usePreferencesStore();

  const homes = homesData?.homes || [];

  // Wait for preferences to hydrate
  if (!isHydrated) {
    return null;
  }

  // Loading state - no data yet
  if (homes.length === 0 && !tabItems) {
    return (
      <Tab.Navigator
        screenOptions={{
          headerShown: false,
          tabBarMinimizeBehavior: 'onScrollDown',
        }}
      >
        <Tab.Screen
          name="LoadingTab"
          component={TabStackNavigator}
          initialParams={{ tabName: 'Home' }}
          options={{
            title: 'Home',
            tabBarIcon: getTabIcon('home'),
          }}
        />
      </Tab.Navigator>
    );
  }

  // Determine which tabs to show
  const hasCustomTabs = tabItems && tabItems.length > 0;

  return (
    <Tab.Navigator
      screenOptions={{
        headerShown: false, // Stack Navigator manages headers
        tabBarMinimizeBehavior: 'onScrollDown',
      }}
    >
      {hasCustomTabs ? (
        // Custom configured tabs
        tabItems.map((item) => (
          <Tab.Screen
            key={`${item.type}-${item.id}`}
            name={`Tab-${item.type}-${item.id}`}
            component={TabStackNavigator}
            initialParams={{
              homeId: item.type === 'home' ? item.id : item.homeId,
              roomId: item.type === 'room' ? item.id : undefined,
              collectionId: item.type === 'collection' ? item.id : undefined,
              groupId: item.type === 'serviceGroup' ? item.id : undefined,
              tabName: item.name,
            }}
            options={{
              title: item.name,
              tabBarIcon: getTabIcon(item.type),
            }}
          />
        ))
      ) : (
        // Default: show all homes
        homes.map((home) => (
          <Tab.Screen
            key={`home-${home.id}`}
            name={`HomeTab-${home.id}`}
            component={TabStackNavigator}
            initialParams={{ homeId: home.id, tabName: home.name }}
            options={{
              title: home.name,
              tabBarIcon: getTabIcon('home'),
            }}
          />
        ))
      )}

    </Tab.Navigator>
  );
}

