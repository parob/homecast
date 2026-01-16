import React from 'react';
import { TabView, TabBarPosition } from '@bottom-tabs/react-navigation';
import type { Home } from '@/types/homekit';
import type { Collection } from '@/types/api';

interface NativeBottomTabsProps {
  homes: Home[];
  collections: Collection[];
  selectedHomeId: string | null;
  selectedCollectionId: string | null;
  onSelectHome: (homeId: string) => void;
  onSelectCollection: (collectionId: string) => void;
}

export function NativeBottomTabs({
  homes,
  collections,
  selectedHomeId,
  selectedCollectionId,
  onSelectHome,
  onSelectCollection,
}: NativeBottomTabsProps) {
  // Build routes from homes and collections
  const routes = React.useMemo(() => {
    const homeRoutes = homes.map((home) => ({
      key: `home-${home.id}`,
      title: home.name,
      focusedIcon: { sfSymbol: 'house.fill' },
      unfocusedIcon: { sfSymbol: 'house' },
    }));

    const collectionRoutes = collections.map((collection) => ({
      key: `collection-${collection.id}`,
      title: collection.name,
      focusedIcon: { sfSymbol: 'folder.fill' },
      unfocusedIcon: { sfSymbol: 'folder' },
    }));

    return [...homeRoutes, ...collectionRoutes];
  }, [homes, collections]);

  // Determine current index
  const currentIndex = React.useMemo(() => {
    if (selectedCollectionId) {
      const collectionIndex = collections.findIndex(c => c.id === selectedCollectionId);
      if (collectionIndex !== -1) {
        return homes.length + collectionIndex;
      }
    }
    if (selectedHomeId) {
      const homeIndex = homes.findIndex(h => h.id === selectedHomeId);
      if (homeIndex !== -1) {
        return homeIndex;
      }
    }
    return 0;
  }, [homes, collections, selectedHomeId, selectedCollectionId]);

  const handleIndexChange = (index: number) => {
    if (index < homes.length) {
      // Selected a home
      onSelectHome(homes[index].id);
    } else {
      // Selected a collection
      const collectionIndex = index - homes.length;
      onSelectCollection(collections[collectionIndex].id);
    }
  };

  if (routes.length === 0) {
    return null;
  }

  return (
    <TabView
      navigationState={{ index: currentIndex, routes }}
      onIndexChange={handleIndexChange}
      tabBarPosition={TabBarPosition.Bottom}
      renderScene={() => null}
      ignoresTopSafeArea
      translucent
    />
  );
}
