import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import * as SecureStore from 'expo-secure-store';

export interface TabItem {
  type: 'home' | 'room' | 'collection' | 'serviceGroup';
  id: string;
  name: string;
  homeId?: string; // Required for rooms/serviceGroups
}

interface PreferencesState {
  tabItems: TabItem[] | null; // null = use default (all homes)
  isHydrated: boolean;
  setTabItems: (items: TabItem[]) => void;
  addTabItem: (item: TabItem) => void;
  removeTabItem: (id: string) => void;
  resetToDefault: () => void;
}

// Custom secure storage adapter for Zustand persist
const secureStorage = {
  getItem: async (name: string): Promise<string | null> => {
    try {
      return await SecureStore.getItemAsync(name);
    } catch {
      return null;
    }
  },
  setItem: async (name: string, value: string): Promise<void> => {
    try {
      await SecureStore.setItemAsync(name, value);
    } catch (error) {
      console.error('SecureStore setItem error:', error);
    }
  },
  removeItem: async (name: string): Promise<void> => {
    try {
      await SecureStore.deleteItemAsync(name);
    } catch (error) {
      console.error('SecureStore removeItem error:', error);
    }
  },
};

export const usePreferencesStore = create<PreferencesState>()(
  persist(
    (set, get) => ({
      tabItems: null,
      isHydrated: false,
      setTabItems: (items) => set({ tabItems: items.length > 0 ? items : null }),
      addTabItem: (item) => {
        const current = get().tabItems || [];
        // Don't add duplicates
        if (current.some((t) => t.id === item.id && t.type === item.type)) {
          return;
        }
        set({ tabItems: [...current, item] });
      },
      removeTabItem: (id) => {
        const current = get().tabItems || [];
        const filtered = current.filter((t) => t.id !== id);
        set({ tabItems: filtered.length > 0 ? filtered : null });
      },
      resetToDefault: () => set({ tabItems: null }),
    }),
    {
      name: 'preferences-storage',
      storage: createJSONStorage(() => secureStorage),
      partialize: (state) => ({
        tabItems: state.tabItems,
      }),
      onRehydrateStorage: () => (state) => {
        if (state) {
          state.isHydrated = true;
        }
      },
    }
  )
);
