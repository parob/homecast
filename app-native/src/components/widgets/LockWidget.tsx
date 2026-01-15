import React, { useState, useEffect, useRef } from 'react';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { WidgetCard, getIconColor } from './WidgetCard';
import { WidgetProps, getCharacteristic } from './types';
import { useCharacteristicValue } from '@/hooks/useCharacteristicValue';

// Normalize lock state: 0=Unlocked, 1=Locked, 2=Jammed, 3=Unknown
function normalizeLockState(value: unknown): number {
  if (typeof value === 'number') return value;
  if (value === true || value === 'true' || value === 1 || value === '1') return 1;
  if (value === false || value === 'false' || value === 0 || value === '0') return 0;
  return 3;
}

export function LockWidget({
  accessory,
  displayName,
  onToggle,
  onCardPress,
}: WidgetProps) {
  const currentStateChar = getCharacteristic(accessory, 'lock_current_state');
  const targetStateChar = getCharacteristic(accessory, 'lock_target_state');

  // Subscribe to store value for optimistic updates
  const rawCurrentState = useCharacteristicValue(
    accessory.id,
    'lock_current_state',
    currentStateChar?.value ?? 3
  );
  const currentState = normalizeLockState(rawCurrentState);

  const isLocked = currentState === 1;
  const isJammed = currentState === 2;
  const hasControls = targetStateChar?.isWritable;
  const iconColors = getIconColor('lock', isLocked);

  // Track pending state
  const [isPending, setIsPending] = useState(false);
  const lastStateRef = useRef(currentState);

  useEffect(() => {
    if (currentState !== lastStateRef.current) {
      setIsPending(false);
      lastStateRef.current = currentState;
    }
  }, [currentState]);

  useEffect(() => {
    if (isPending) {
      const timeout = setTimeout(() => setIsPending(false), 15000);
      return () => clearTimeout(timeout);
    }
  }, [isPending]);

  const handleToggle = () => {
    setIsPending(true);
    onToggle(accessory.id, 'lock_target_state', isLocked);
  };

  const getSubtitle = () => {
    if (isJammed) return 'Jammed';
    if (isPending) return isLocked ? 'Unlocking...' : 'Locking...';
    return isLocked ? 'Locked' : 'Unlocked';
  };

  return (
    <WidgetCard
      title={displayName}
      subtitle={getSubtitle()}
      icon={<FontAwesome name={isLocked ? 'lock' : 'unlock'} size={16} color={iconColors.icon} />}
      isOn={isLocked}
      isReachable={accessory.isReachable}
      serviceType="lock"
      onIconPress={hasControls ? handleToggle : undefined}
      onCardPress={onCardPress}
    />
  );
}
