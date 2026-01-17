import React from 'react';
import { Platform, TouchableOpacity } from 'react-native';
import { createNativeBottomTabNavigator } from '@react-navigation/bottom-tabs/unstable';
import { useNavigation } from '@react-navigation/native';
import { useQuery } from '@apollo/client/react';
import { MenuView } from '@react-native-menu/menu';
import Ionicons from '@expo/vector-icons/Ionicons';
import { HOMES_QUERY } from '@/api/graphql/queries';
import { usePreferencesStore, TabItem } from '@/stores/preferencesStore';
import HomeScreen from './index';
import SettingsScreen from './settings';
import type { Home } from '@/types/homekit';

const Tab = createNativeBottomTabNavigator();

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
  const navigation = useNavigation<any>();

  return (
    <MenuView
      title=""
      onPressAction={({ nativeEvent }) => {
        if (nativeEvent.event === 'settings') {
          navigation.navigate('SettingsTab');
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

// Screen wrapper that handles all tab types
function TabScreen({ route }: { route: any }) {
  const { homeId, roomId, collectionId, groupId } = route.params || {};
  return (
    <HomeScreen
      initialHomeId={homeId}
      initialRoomId={roomId}
      initialCollectionId={collectionId}
      initialGroupId={groupId}
    />
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
          headerShown: true,
          headerLargeTitleEnabled: true,
          headerTransparent: true,
          headerBlurEffect: 'none',
          headerRight: () => <HeaderMenuButton />,
          tabBarMinimizeBehavior: 'onScrollDown',
        }}
      >
        <Tab.Screen
          name="LoadingTab"
          component={HomeScreen}
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
        headerShown: true,
        headerLargeTitleEnabled: true,
        headerTransparent: true,
        headerBlurEffect: 'none',
        headerRight: () => <HeaderMenuButton />,
        tabBarMinimizeBehavior: 'onScrollDown',
      }}
    >
      {hasCustomTabs ? (
        // Custom configured tabs
        tabItems.map((item) => (
          <Tab.Screen
            key={`${item.type}-${item.id}`}
            name={`Tab-${item.type}-${item.id}`}
            component={TabScreen}
            initialParams={{
              homeId: item.type === 'home' ? item.id : item.homeId,
              roomId: item.type === 'room' ? item.id : undefined,
              collectionId: item.type === 'collection' ? item.id : undefined,
              groupId: item.type === 'serviceGroup' ? item.id : undefined,
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
            component={TabScreen}
            initialParams={{ homeId: home.id }}
            options={{
              title: home.name,
              tabBarIcon: getTabIcon('home'),
            }}
          />
        ))
      )}

      {/* Settings tab - always hidden in tab bar, accessible via menu */}
      <Tab.Screen
        name="SettingsTab"
        component={SettingsScreen}
        options={{
          title: 'Settings',
          tabBarItemHidden: true,
          tabBarIcon: Platform.select({
            ios: { type: 'sfSymbol', name: 'gear' },
            default: { type: 'image', source: homecastIcon },
          }),
        }}
      />
    </Tab.Navigator>
  );
}
