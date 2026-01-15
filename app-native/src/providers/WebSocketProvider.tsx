import { createContext, useContext, useEffect, useCallback, ReactNode } from 'react';
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

export function WebSocketProvider({ children }: Props) {
  const client = useApolloClient();
  const { token, isAuthenticated } = useAuthStore();
  const { updateCharacteristic, updateReachability } = useAccessoryStore();
  const wsConnected = useConnectionStore((state) => state.wsConnected);
  const selectedHomeId = useHomeStore((state) => state.selectedHomeId);

  // Update characteristic in Apollo cache
  const updateCharacteristicInCache = useCallback((
    accessoryId: string,
    characteristicType: string,
    newValue: unknown
  ) => {
    const homeId = selectedHomeId;
    if (!homeId) return;

    // JSON-stringify the value to match GraphQL format
    const jsonEncodedValue = JSON.stringify(newValue);

    client.cache.updateQuery<{ accessories: Accessory[] }>(
      { query: ACCESSORIES_QUERY, variables: { homeId } },
      (data) => {
        if (!data?.accessories) return data;

        let updated = false;

        const newAccessories = data.accessories.map((acc) => {
          if (acc.id !== accessoryId) return acc;
          return {
            ...acc,
            services: acc.services.map((service) => ({
              ...service,
              characteristics: service.characteristics.map((char) => {
                if (char.characteristicType !== characteristicType) return char;
                updated = true;
                return { ...char, value: jsonEncodedValue };
              }),
            })),
          };
        });

        if (updated) {
          console.log(`[WS] Updated cache: ${accessoryId.slice(0, 8)}... ${characteristicType} = ${newValue}`);
        }

        return { accessories: newAccessories };
      }
    );
  }, [client, selectedHomeId]);

  // Update reachability in Apollo cache
  const updateReachabilityInCache = useCallback((
    accessoryId: string,
    isReachable: boolean
  ) => {
    const homeId = selectedHomeId;
    if (!homeId) return;

    client.cache.updateQuery<{ accessories: Accessory[] }>(
      { query: ACCESSORIES_QUERY, variables: { homeId } },
      (data) => {
        if (!data?.accessories) return data;

        let updated = false;

        const newAccessories = data.accessories.map((acc) => {
          if (acc.id !== accessoryId) return acc;
          if (acc.isReachable === isReachable) return acc;
          updated = true;
          return { ...acc, isReachable };
        });

        if (updated) {
          console.log(`[WS] Reachability: ${accessoryId.slice(0, 8)}... → ${isReachable ? 'reachable' : 'unreachable'}`);
        }

        return { accessories: newAccessories };
      }
    );
  }, [client, selectedHomeId]);

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
            console.log(`[WS] Skipped (local change pending): ${msg.accessoryId.slice(0, 8)}... ${msg.characteristicType}`);
            return;
          }

          console.log(`[WS] Update received: ${msg.accessoryId.slice(0, 8)}... ${msg.characteristicType} = ${msg.value}`);

          // Update Zustand store for immediate UI update
          updateCharacteristic(msg.accessoryId, msg.characteristicType, msg.value, false);

          // Update Apollo cache for data consistency
          updateCharacteristicInCache(msg.accessoryId, msg.characteristicType, msg.value);
          break;
        }

        case 'reachability_update': {
          const msg = message as ReachabilityUpdateMessage;
          console.log(`[WS] Reachability received: ${msg.accessoryId.slice(0, 8)}... → ${msg.isReachable ? 'reachable' : 'unreachable'}`);

          // Update Zustand store
          updateReachability(msg.accessoryId, msg.isReachable);

          // Update Apollo cache
          updateReachabilityInCache(msg.accessoryId, msg.isReachable);
          break;
        }
      }
    },
    [updateCharacteristic, updateReachability, updateCharacteristicInCache, updateReachabilityInCache]
  );

  // Connect WebSocket when authenticated
  useEffect(() => {
    if (isAuthenticated && token) {
      webSocketClient.connect(token);
      const unsubscribe = webSocketClient.subscribe(handleMessage);

      return () => {
        unsubscribe();
      };
    } else {
      webSocketClient.disconnect();
    }
  }, [isAuthenticated, token, handleMessage]);

  return (
    <WebSocketContext.Provider value={{ isConnected: wsConnected }}>
      {children}
    </WebSocketContext.Provider>
  );
}

export function useWebSocket() {
  return useContext(WebSocketContext);
}
