import { useCallback } from 'react';
import { useMutation } from '@apollo/client/react';
import * as Haptics from 'expo-haptics';

import { useHomeKit } from '@/providers/HomeKitProvider';
import { SET_CHARACTERISTIC_MUTATION, EXECUTE_SCENE_MUTATION } from '@/api/graphql/mutations';
import { useAccessoryStore } from '@/stores/accessoryStore';
import { markLocalChange } from '@/providers/WebSocketProvider';

interface ControlResult {
  success: boolean;
  accessoryId: string;
  characteristicType?: string;
  sceneId?: string;
  value?: unknown;
  error?: string;
  source: 'local' | 'remote';
}

export function useAccessoryControl() {
  const { isLocalModeEnabled, localSetCharacteristic, localExecuteScene } = useHomeKit();
  const [setCharacteristicMutation] = useMutation(SET_CHARACTERISTIC_MUTATION);
  const [executeSceneMutation] = useMutation(EXECUTE_SCENE_MUTATION);
  const { updateCharacteristic, revertOptimistic } = useAccessoryStore();

  /**
   * Set a characteristic on an accessory.
   * Uses local HomeKit if available and enabled, otherwise falls back to remote API.
   */
  const setCharacteristic = useCallback(
    async (
      accessoryId: string,
      characteristicType: string,
      value: unknown
    ): Promise<ControlResult> => {
      // Mark as local change to prevent WebSocket echo
      markLocalChange(accessoryId, characteristicType);

      // Optimistic update
      updateCharacteristic(accessoryId, characteristicType, value, true);

      // Haptic feedback
      await Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

      try {
        if (isLocalModeEnabled) {
          // Use local HomeKit
          const result = await localSetCharacteristic(accessoryId, characteristicType, value);

          if (!result.success) {
            // Local failed, try remote as fallback
            console.log('[Control] Local failed, falling back to remote');
            return await setCharacteristicRemote(accessoryId, characteristicType, value);
          }

          return {
            success: true,
            accessoryId,
            characteristicType,
            value,
            source: 'local',
          };
        } else {
          // Use remote API
          return await setCharacteristicRemote(accessoryId, characteristicType, value);
        }
      } catch (error) {
        revertOptimistic(accessoryId, characteristicType);
        console.error('[Control] Error setting characteristic:', error);
        return {
          success: false,
          accessoryId,
          characteristicType,
          error: error instanceof Error ? error.message : 'Unknown error',
          source: isLocalModeEnabled ? 'local' : 'remote',
        };
      }
    },
    [isLocalModeEnabled, localSetCharacteristic, updateCharacteristic, revertOptimistic]
  );

  const setCharacteristicRemote = async (
    accessoryId: string,
    characteristicType: string,
    value: unknown
  ): Promise<ControlResult> => {
    try {
      const { data } = await setCharacteristicMutation({
        variables: {
          accessoryId,
          characteristicType,
          value,
        },
      });

      // Type the data object from GraphQL mutation
      const result = data as { setCharacteristic?: { success: boolean } } | undefined;

      if (result?.setCharacteristic?.success) {
        return {
          success: true,
          accessoryId,
          characteristicType,
          value,
          source: 'remote',
        };
      } else {
        revertOptimistic(accessoryId, characteristicType);
        return {
          success: false,
          accessoryId,
          characteristicType,
          error: 'Remote API returned failure',
          source: 'remote',
        };
      }
    } catch (error) {
      revertOptimistic(accessoryId, characteristicType);
      throw error;
    }
  };

  /**
   * Execute a scene.
   * Uses local HomeKit if available and enabled, otherwise falls back to remote API.
   */
  const executeScene = useCallback(
    async (sceneId: string): Promise<ControlResult> => {
      // Haptic feedback
      await Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);

      try {
        if (isLocalModeEnabled) {
          // Use local HomeKit
          const result = await localExecuteScene(sceneId);

          if (!result.success) {
            // Local failed, try remote as fallback
            console.log('[Control] Local scene execution failed, falling back to remote');
            return await executeSceneRemote(sceneId);
          }

          return {
            success: true,
            accessoryId: '',
            sceneId,
            source: 'local',
          };
        } else {
          // Use remote API
          return await executeSceneRemote(sceneId);
        }
      } catch (error) {
        console.error('[Control] Error executing scene:', error);
        return {
          success: false,
          accessoryId: '',
          sceneId,
          error: error instanceof Error ? error.message : 'Unknown error',
          source: isLocalModeEnabled ? 'local' : 'remote',
        };
      }
    },
    [isLocalModeEnabled, localExecuteScene]
  );

  const executeSceneRemote = async (sceneId: string): Promise<ControlResult> => {
    const { data } = await executeSceneMutation({
      variables: { sceneId },
    });

    // Type the data object from GraphQL mutation
    const result = data as { executeScene?: { success: boolean } } | undefined;

    if (result?.executeScene?.success) {
      return {
        success: true,
        accessoryId: '',
        sceneId,
        source: 'remote',
      };
    } else {
      return {
        success: false,
        accessoryId: '',
        sceneId,
        error: 'Remote API returned failure',
        source: 'remote',
      };
    }
  };

  return {
    setCharacteristic,
    executeScene,
    isLocalMode: isLocalModeEnabled,
  };
}
