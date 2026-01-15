import { create } from 'zustand';

interface ConnectionState {
  wsConnected: boolean;
  deviceOnline: boolean;
  lastPing: Date | null;
  reconnectAttempts: number;
  setWsConnected: (connected: boolean) => void;
  setDeviceOnline: (online: boolean) => void;
  setLastPing: (time: Date) => void;
  incrementReconnectAttempts: () => void;
  resetReconnectAttempts: () => void;
}

export const useConnectionStore = create<ConnectionState>((set) => ({
  wsConnected: false,
  deviceOnline: false,
  lastPing: null,
  reconnectAttempts: 0,
  setWsConnected: (connected) => set({ wsConnected: connected }),
  setDeviceOnline: (online) => set({ deviceOnline: online }),
  setLastPing: (time) => set({ lastPing: time }),
  incrementReconnectAttempts: () =>
    set((state) => ({ reconnectAttempts: state.reconnectAttempts + 1 })),
  resetReconnectAttempts: () => set({ reconnectAttempts: 0 }),
}));
