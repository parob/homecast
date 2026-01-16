import React from 'react';
import { createNativeBottomTabNavigator } from '@bottom-tabs/react-navigation';
import { useQuery } from '@apollo/client/react';
import { HOMES_QUERY, COLLECTIONS_QUERY } from '@/api/graphql/queries';
import HomeScreen from './index';
import type { Home } from '@/types/homekit';
import type { Collection } from '@/types/api';

const Tab = createNativeBottomTabNavigator();

export default function TabLayout() {
  // Fetch homes and collections for dynamic tabs
  const { data: homesData } = useQuery<{ homes: Home[] }>(HOMES_QUERY);
  const { data: collectionsData } = useQuery<{ collections: Collection[] }>(COLLECTIONS_QUERY);

  const homes = homesData?.homes || [];
  const collections = collectionsData?.collections || [];

  return (
    <Tab.Navigator
      tabBarPosition="bottom"
      translucent={true}
      ignoresTopSafeArea={true}
      screenOptions={{
        headerShown: false,
      }}
    >
      {/* Home tabs */}
      {homes.map((home) => (
        <Tab.Screen
          key={`home-${home.id}`}
          name={`home-${home.id}`}
          options={{
            title: home.name,
            tabBarIcon: ({ focused }) => ({
              sfSymbol: focused ? 'house.fill' : 'house',
            }),
          }}
        >
          {() => <HomeScreen initialHomeId={home.id} />}
        </Tab.Screen>
      ))}

      {/* Collection tabs */}
      {collections.map((collection) => (
        <Tab.Screen
          key={`collection-${collection.id}`}
          name={`collection-${collection.id}`}
          options={{
            title: collection.name,
            tabBarIcon: ({ focused }) => ({
              sfSymbol: focused ? 'folder.fill' : 'folder',
            }),
          }}
        >
          {() => <HomeScreen initialCollectionId={collection.id} />}
        </Tab.Screen>
      ))}

      {/* Fallback if no data yet */}
      {homes.length === 0 && collections.length === 0 && (
        <Tab.Screen
          name="loading"
          options={{
            title: 'Home',
            tabBarIcon: () => ({ sfSymbol: 'house' }),
          }}
        >
          {() => <HomeScreen />}
        </Tab.Screen>
      )}
    </Tab.Navigator>
  );
}
