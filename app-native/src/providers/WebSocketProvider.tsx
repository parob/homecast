import { createContext, useContext, useEffect, useCallback, useRef, ReactNode } from 'react';
import { useApolloClient } from '@apollo/client/react';
import { webSocketClient } from '@/api/websocket/client';
import { useAuthStore } from '@/stores/authStore';
import { useAccessoryStore } from '@/stores/accessoryStore';
import { useConnectionStore } from '@/stores/connectionStore';
import { useHomeStore } from '@/stores/homeStore';
import { ACCESSORIES_QUERY } from '@/api/graphql/queries';
import type { WebSocketMessage, CharacteristicUpdateMessage, ReachabilityUpdateMessage } from '@/api/websocket/types';
import type { Accessory } from '@/types/homekit';

interface WebSocketContextType {
  isConnected: boolean;
}

const WebSocketContext = createContext<WebSocketContextType>({ isConnected: false });

interface Props {
  children: ReactNode;
}

// Module-level map to track recent local changes (prevents echo updates)
const recentLocalChanges = new Map<string, number>();

// Pending cache updates - batched for performance
interface PendingCharUpdate {
  accessoryId: string;
  characteristicType: string;
  value: unknown;
}
interface PendingReachUpdate {
  accessoryId: string;
  isReachable: boolean;
}

/**
 * Mark a characteristic as recently changed locally.
 * WebSocket updates for this characteristic will be ignored for a short period.
 */
export function markLocalChange(accessoryId: string, characteristicType: string) {
  const key = `${accessoryId}:${characteristicType}`;
  recentLocalChanges.set(key, Date.now());
  // Clean up after 2 seconds
  setTimeout(() => {
    recentLocalChanges.delete(key);
  }, 2000);
}

/**
 * Clear a local change marker after mutation succeeds.
 * This allows WebSocket updates to come through again.
 */
export function clearLocalChange(accessoryId: string, characteristicType: string) {
  const key = `${accessoryId}:${characteristicType}`;
  recentLocalChanges.delete(key);
}

export function WebSocketProvider({ children }: Props) {
  const client = useApolloClient();
  const { token, isAuthenticated } = useAuthStore();
  const { updateCharacteristic, updateReachability } = useAccessoryStore();
  const wsConnected = useConnectionStore((state) => state.wsConnected);
  const selectedHomeId = useHomeStore((state) => state.selectedHomeId);

  // Refs for batching cache updates
  const pendingCharUpdates = useRef<PendingCharUpdate[]>([]);
  const pendingReachUpdates = useRef<PendingReachUpdate[]>([]);
  const flushTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const homeIdRef = useRef(selectedHomeId);

  // Keep homeId ref in sync
  useEffect(() => {
    homeIdRef.current = selectedHomeId;
  }, [selectedHomeId]);

  // Flush all pending updates to Apollo cache in one batch
  const flushCacheUpdates = useCallback(() => {
    const homeId = homeIdRef.current;
    if (!homeId) return;

    const charUpdates = pendingCharUpdates.current;
    const reachUpdates = pendingReachUpdates.current;

    if (charUpdates.length === 0 && reachUpdates.length === 0) return;

    // Clear pending queues
    pendingCharUpdates.current = [];
    pendingReachUpdates.current = [];

    // Single cache update for all pending changes
    client.cache.updateQuery<{ accessories: Accessory[] }>(
      { query: ACCESSORIES_QUERY, variables: { homeId } },
      (data) => {
        if (!data?.accessories) return data;

        // Build lookup maps for efficient updates
        const charUpdateMap = new Map<string, Map<string, unknown>>();
        for (const update of charUpdates) {
          if (!charUpdateMap.has(update.accessoryId)) {
            charUpdateMap.set(update.accessoryId, new Map());
          }
          charUpdateMap.get(update.accessoryId)!.set(update.characteristicType, update.value);
        }

        const reachUpdateMap = new Map<string, boolean>();
        for (const update of reachUpdates) {
          reachUpdateMap.set(update.accessoryId, update.isReachable);
        }

        const newAccessories = data.accessories.map((acc) => {
          const charChanges = charUpdateMap.get(acc.id);
          const reachChange = reachUpdateMap.get(acc.id);

          if (!charChanges && reachChange === undefined) return acc;

          let newAcc = acc;

          // Apply reachability change
          if (reachChange !== undefined && acc.isReachable !== reachChange) {
            newAcc = { ...newAcc, isReachable: reachChange };
          }

          // Apply characteristic changes
          if (charChanges && charChanges.size > 0) {
            newAcc = {
              ...newAcc,
              services: acc.services.map((service) => ({
                ...service,
                characteristics: service.characteristics.map((char) => {
                  const newValue = charChanges.get(char.characteristicType);
                  if (newValue === undefined) return char;
                  return { ...char, value: JSON.stringify(newValue) };
                }),
              })),
            };
          }

          return newAcc;
        });

        console.log(`[WS] Batch updated cache: ${charUpdates.length} chars, ${reachUpdates.length} reachability`);
        return { accessories: newAccessories };
      }
    );
  }, [client]);

  // Schedule a flush (debounced)
  const scheduleFlush = useCallback(() => {
    if (flushTimeoutRef.current) {
      clearTimeout(flushTimeoutRef.current);
    }
    // Flush after 100ms of inactivity
    flushTimeoutRef.current = setTimeout(() => {
      flushCacheUpdates();
      flushTimeoutRef.current = null;
    }, 100);
  }, [flushCacheUpdates]);

  const handleMessage = useCallback(
    (message: WebSocketMessage) => {
      switch (message.type) {
        case 'characteristic_update': {
          const msg = message as CharacteristicUpdateMessage;
          const key = `${msg.accessoryId}:${msg.characteristicType}`;
          const now = Date.now();

          // Skip if this characteristic was recently changed locally (within 1.5s)
          const localChangeTime = recentLocalChanges.get(key);
          if (localChangeTime && now - localChangeTime < 1500) {
            return;
          }

          // Update Zustand store for immediate UI update
          updateCharacteristic(msg.accessoryId, msg.characteristicType, msg.value, false);

          // Queue cache update (batched)
          pendingCharUpdates.current.push({
            accessoryId: msg.accessoryId,
            characteristicType: msg.characteristicType,
            value: msg.value,
          });
          scheduleFlush();
          break;
        }

        case 'reachability_update': {
          const msg = message as ReachabilityUpdateMessage;

          // Update Zustand store
          updateReachability(msg.accessoryId, msg.isReachable);

          // Queue cache update (batched)
          pendingReachUpdates.current.push({
            accessoryId: msg.accessoryId,
            isReachable: msg.isReachable,
          });
          scheduleFlush();
          break;
        }
      }
    },
    [updateCharacteristic, updateReachability, scheduleFlush]
  );

  // Connect WebSocket when authenticated
  useEffect(() => {
    if (isAuthenticated && token) {
      webSocketClient.connect(token);
      const unsubscribe = webSocketClient.subscribe(handleMessage);

      return () => {
        unsubscribe();
        // Flush any pending updates on unmount
        if (flushTimeoutRef.current) {
          clearTimeout(flushTimeoutRef.current);
          flushCacheUpdates();
        }
      };
    } else {
      webSocketClient.disconnect();
    }
  }, [isAuthenticated, token, handleMessage, flushCacheUpdates]);

  return (
    <WebSocketContext.Provider value={{ isConnected: wsConnected }}>
      {children}
    </WebSocketContext.Provider>
  );
}

export function useWebSocket() {
  return useContext(WebSocketContext);
}
