import { create } from 'zustand';
import { immer } from 'zustand/middleware/immer';

interface CharacteristicState {
  value: unknown;
  lastUpdated: Date;
  isOptimistic: boolean;
  previousValue?: unknown;
}

interface AccessoryState {
  characteristics: Record<string, CharacteristicState>;
  reachability: Record<string, boolean>;

  // Actions
  updateCharacteristic: (
    accessoryId: string,
    charType: string,
    value: unknown,
    isOptimistic?: boolean
  ) => void;
  confirmOptimistic: (accessoryId: string, charType: string) => void;
  revertOptimistic: (accessoryId: string, charType: string) => void;
  updateReachability: (accessoryId: string, isReachable: boolean) => void;
  getCharacteristicValue: (accessoryId: string, charType: string) => unknown | null;
  isCharacteristicPending: (accessoryId: string, charType: string) => boolean;
  isAccessoryPending: (accessoryId: string) => boolean;
  clearAll: () => void;
}

const makeKey = (accessoryId: string, charType: string) => `${accessoryId}:${charType}`;

export const useAccessoryStore = create<AccessoryState>()(
  immer((set, get) => ({
    characteristics: {},
    reachability: {},

    updateCharacteristic: (accessoryId, charType, value, isOptimistic = false) => {
      const key = makeKey(accessoryId, charType);
      set((state) => {
        const existing = state.characteristics[key];
        state.characteristics[key] = {
          value,
          lastUpdated: new Date(),
          isOptimistic,
          previousValue: isOptimistic ? existing?.value : undefined,
        };
      });
    },

    confirmOptimistic: (accessoryId, charType) => {
      const key = makeKey(accessoryId, charType);
      set((state) => {
        if (state.characteristics[key]) {
          state.characteristics[key].isOptimistic = false;
          state.characteristics[key].previousValue = undefined;
        }
      });
    },

    revertOptimistic: (accessoryId, charType) => {
      const key = makeKey(accessoryId, charType);
      set((state) => {
        const existing = state.characteristics[key];
        if (existing && existing.previousValue !== undefined) {
          state.characteristics[key] = {
            value: existing.previousValue,
            lastUpdated: new Date(),
            isOptimistic: false,
            previousValue: undefined,
          };
        }
      });
    },

    updateReachability: (accessoryId, isReachable) => {
      set((state) => {
        state.reachability[accessoryId] = isReachable;
      });
    },

    getCharacteristicValue: (accessoryId, charType) => {
      const key = makeKey(accessoryId, charType);
      return get().characteristics[key]?.value ?? null;
    },

    isCharacteristicPending: (accessoryId, charType) => {
      const key = makeKey(accessoryId, charType);
      return get().characteristics[key]?.isOptimistic ?? false;
    },

    isAccessoryPending: (accessoryId) => {
      const chars = get().characteristics;
      return Object.keys(chars).some(
        (key) => key.startsWith(`${accessoryId}:`) && chars[key].isOptimistic
      );
    },

    clearAll: () => {
      set((state) => {
        state.characteristics = {};
        state.reachability = {};
      });
    },
  }))
);
