import React, {
  createContext,
  useContext,
  useEffect,
  useState,
  useCallback,
  ReactNode,
} from 'react';
import { Platform } from 'react-native';
import type {
  HomeKitHome,
  HomeKitRoom,
  HomeKitAccessory,
  HomeKitScene,
  HomeKitZone,
  HomeKitServiceGroup,
  SetCharacteristicResult,
  ExecuteSceneResult,
  AuthorizationStatus,
} from '../../modules/expo-homekit/src/types';

// Lazy load the module to avoid blocking app startup
let ExpoHomeKitModule: typeof import('../../modules/expo-homekit/src') | null = null;

function getHomeKitModule() {
  if (Platform.OS !== 'ios') {
    return null;
  }
  if (!ExpoHomeKitModule) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      ExpoHomeKitModule = require('../../modules/expo-homekit/src');
    } catch (e) {
      console.warn('[HomeKit] Failed to load native module:', e);
      return null;
    }
  }
  return ExpoHomeKitModule;
}

interface HomeKitContextType {
  // State
  isAvailable: boolean;
  isAuthorized: boolean;
  authorizationStatus: AuthorizationStatus;
  isLocalModeEnabled: boolean;
  homes: HomeKitHome[];

  // Actions
  enableLocalMode: () => Promise<boolean>;
  disableLocalMode: () => void;
  requestAuthorization: () => Promise<AuthorizationStatus>;

  // Local HomeKit operations
  localListHomes: () => Promise<HomeKitHome[]>;
  localListRooms: (homeId: string) => Promise<HomeKitRoom[]>;
  localListAccessories: (homeId?: string, roomId?: string) => Promise<HomeKitAccessory[]>;
  localGetAccessory: (accessoryId: string) => Promise<HomeKitAccessory | null>;
  localReadCharacteristic: (accessoryId: string, characteristicType: string) => Promise<unknown>;
  localSetCharacteristic: (
    accessoryId: string,
    characteristicType: string,
    value: unknown
  ) => Promise<SetCharacteristicResult>;
  localListScenes: (homeId: string) => Promise<HomeKitScene[]>;
  localExecuteScene: (sceneId: string) => Promise<ExecuteSceneResult>;
  localListZones: (homeId: string) => Promise<HomeKitZone[]>;
  localListServiceGroups: (homeId: string) => Promise<HomeKitServiceGroup[]>;
}

const HomeKitContext = createContext<HomeKitContextType | null>(null);

interface HomeKitProviderProps {
  children: ReactNode;
}

export function HomeKitProvider({ children }: HomeKitProviderProps) {
  const [isAvailable, setIsAvailable] = useState(false);
  const [authorizationStatus, setAuthorizationStatus] = useState<AuthorizationStatus>('unavailable');
  const [isLocalModeEnabled, setIsLocalModeEnabled] = useState(false);
  const [homes, setHomes] = useState<HomeKitHome[]>([]);

  const isAuthorized = authorizationStatus === 'authorized';

  // Check availability and authorization status on mount (delayed to avoid blocking)
  useEffect(() => {
    // Delay module loading to avoid blocking app startup
    const timer = setTimeout(() => {
      const module = getHomeKitModule();
      if (module) {
        try {
          const available = module.isAvailable();
          setIsAvailable(available);
          if (available) {
            module.getAuthorizationStatus().then(setAuthorizationStatus).catch(() => {});
          }
        } catch (e) {
          console.warn('[HomeKit] Error checking availability:', e);
          setIsAvailable(false);
        }
      }
    }, 100);
    return () => clearTimeout(timer);
  }, []);

  // Set up event listeners when local mode is enabled
  useEffect(() => {
    if (!isLocalModeEnabled || !isAvailable) return;

    const module = getHomeKitModule();
    if (!module) return;

    // Start observing HomeKit changes
    module.startObserving();

    // Add event listeners
    const homesSubscription = module.addHomesUpdatedListener((event) => {
      setHomes(event.homes);
    });

    const characteristicSubscription = module.addCharacteristicChangeListener((event) => {
      console.log('[HomeKit] Characteristic changed:', event);
    });

    const reachabilitySubscription = module.addReachabilityChangeListener((event) => {
      console.log('[HomeKit] Reachability changed:', event);
    });

    // Load initial homes
    module.listHomes().then(setHomes).catch(() => {});

    return () => {
      module.stopObserving();
      homesSubscription.remove();
      characteristicSubscription.remove();
      reachabilitySubscription.remove();
    };
  }, [isLocalModeEnabled, isAvailable]);

  const requestAuthorization = useCallback(async () => {
    const module = getHomeKitModule();
    if (!isAvailable || !module) return 'unavailable' as const;
    const status = await module.requestAuthorization();
    setAuthorizationStatus(status);
    return status;
  }, [isAvailable]);

  const enableLocalMode = useCallback(async () => {
    if (!isAvailable) return false;

    // Request authorization if not already authorized
    if (!isAuthorized) {
      const status = await requestAuthorization();
      if (status !== 'authorized') {
        return false;
      }
    }

    setIsLocalModeEnabled(true);
    return true;
  }, [isAvailable, isAuthorized, requestAuthorization]);

  const disableLocalMode = useCallback(() => {
    setIsLocalModeEnabled(false);
    setHomes([]);
  }, []);

  // Local HomeKit operations
  const localListHomes = useCallback(async () => {
    const module = getHomeKitModule();
    if (!isAvailable || !isLocalModeEnabled || !module) return [];
    return module.listHomes();
  }, [isAvailable, isLocalModeEnabled]);

  const localListRooms = useCallback(
    async (homeId: string) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) return [];
      return module.listRooms(homeId);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const localListAccessories = useCallback(
    async (homeId?: string, roomId?: string) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) return [];
      return module.listAccessories(homeId, roomId);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const localGetAccessory = useCallback(
    async (accessoryId: string) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) return null;
      return module.getAccessory(accessoryId);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const localReadCharacteristic = useCallback(
    async (accessoryId: string, characteristicType: string) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) {
        throw new Error('HomeKit is not available or local mode is disabled');
      }
      return module.readCharacteristic(accessoryId, characteristicType);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const localSetCharacteristic = useCallback(
    async (accessoryId: string, characteristicType: string, value: unknown) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) {
        return { success: false, accessoryId, characteristicType };
      }
      return module.setCharacteristic(accessoryId, characteristicType, value);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const localListScenes = useCallback(
    async (homeId: string) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) return [];
      return module.listScenes(homeId);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const localExecuteScene = useCallback(
    async (sceneId: string) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) {
        return { success: false, sceneId };
      }
      return module.executeScene(sceneId);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const localListZones = useCallback(
    async (homeId: string) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) return [];
      return module.listZones(homeId);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const localListServiceGroups = useCallback(
    async (homeId: string) => {
      const module = getHomeKitModule();
      if (!isAvailable || !isLocalModeEnabled || !module) return [];
      return module.listServiceGroups(homeId);
    },
    [isAvailable, isLocalModeEnabled]
  );

  const value: HomeKitContextType = {
    isAvailable,
    isAuthorized,
    authorizationStatus,
    isLocalModeEnabled,
    homes,
    enableLocalMode,
    disableLocalMode,
    requestAuthorization,
    localListHomes,
    localListRooms,
    localListAccessories,
    localGetAccessory,
    localReadCharacteristic,
    localSetCharacteristic,
    localListScenes,
    localExecuteScene,
    localListZones,
    localListServiceGroups,
  };

  return <HomeKitContext.Provider value={value}>{children}</HomeKitContext.Provider>;
}

export function useHomeKit() {
  const context = useContext(HomeKitContext);
  if (!context) {
    throw new Error('useHomeKit must be used within a HomeKitProvider');
  }
  return context;
}
