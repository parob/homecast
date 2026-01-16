import { useAccessoryStore } from '@/stores/accessoryStore';

/**
 * Hook to subscribe to a characteristic value from the Zustand store.
 * Returns the store value if it exists (for optimistic updates), otherwise returns the server value.
 * This hook properly subscribes to store changes and will trigger re-renders.
 */
export function useCharacteristicValue(
  accessoryId: string,
  characteristicType: string | undefined,
  serverValue: unknown
): unknown {
  const storeValue = useAccessoryStore((state) => {
    if (!characteristicType) return undefined;
    const key = `${accessoryId}:${characteristicType}`;
    return state.characteristics[key]?.value;
  });

  return storeValue !== undefined ? storeValue : serverValue;
}

/**
 * Hook to check if any characteristic of an accessory has a pending (optimistic) update.
 * Useful for showing loading states on widget cards.
 */
export function useAccessoryPending(accessoryId: string): boolean {
  return useAccessoryStore((state) => {
    return Object.keys(state.characteristics).some(
      (key) => key.startsWith(`${accessoryId}:`) && state.characteristics[key].isOptimistic
    );
  });
}
