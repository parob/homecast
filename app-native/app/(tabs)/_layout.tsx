import React from 'react';
import { Platform, TouchableOpacity } from 'react-native';
import { createNativeBottomTabNavigator } from '@react-navigation/bottom-tabs/unstable';
import { useNavigation } from '@react-navigation/native';
import { useQuery } from '@apollo/client/react';
import { MenuView } from '@react-native-menu/menu';
import Ionicons from '@expo/vector-icons/Ionicons';
import { HOMES_QUERY, COLLECTIONS_QUERY } from '@/api/graphql/queries';
import HomeScreen from './index';
import SettingsScreen from './settings';
import type { Home } from '@/types/homekit';
import type { Collection } from '@/types/api';

const Tab = createNativeBottomTabNavigator();

// Homecast logo for tab bar
const homecastIcon = require('@/assets/images/homecast-tab-icon.png');

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

// Home screen wrapper that passes homeId
function HomeTabScreen({ route }: { route: any }) {
  const { homeId } = route.params || {};
  return <HomeScreen initialHomeId={homeId} />;
}

// Collection screen wrapper
function CollectionTabScreen({ route }: { route: any }) {
  const { collectionId } = route.params || {};
  return <HomeScreen initialCollectionId={collectionId} />;
}

export default function TabLayout() {
  const { data: homesData } = useQuery<{ homes: Home[] }>(HOMES_QUERY);
  const { data: collectionsData } = useQuery<{ collections: Collection[] }>(COLLECTIONS_QUERY);

  const homes = homesData?.homes || [];
  const collections = collectionsData?.collections || [];
  const firstCollection = collections[0];

  // Loading state
  if (homes.length === 0 && !firstCollection) {
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
            tabBarIcon: () => homecastIcon,
          }}
        />
      </Tab.Navigator>
    );
  }

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
      {/* Home tabs */}
      {homes.map((home) => (
        <Tab.Screen
          key={`home-${home.id}`}
          name={`HomeTab-${home.id}`}
          component={HomeTabScreen}
          initialParams={{ homeId: home.id }}
          options={{
            title: home.name,
            tabBarIcon: () => homecastIcon,
          }}
        />
      ))}

      {/* Collection tab */}
      {firstCollection && (
        <Tab.Screen
          name={`CollectionTab-${firstCollection.id}`}
          component={CollectionTabScreen}
          initialParams={{ collectionId: firstCollection.id }}
          options={{
            title: firstCollection.name,
            tabBarIcon: () => ({ sfSymbol: 'folder.fill' }),
          }}
        />
      )}

      {/* Settings tab - hidden */}
      <Tab.Screen
        name="SettingsTab"
        component={SettingsScreen}
        options={{
          title: 'Settings',
          tabBarItemHidden: true,
          tabBarIcon: () => ({ sfSymbol: 'gear' }),
        }}
      />
    </Tab.Navigator>
  );
}
