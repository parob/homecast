import React from 'react';
import { Platform, StyleSheet, ViewStyle, StyleProp } from 'react-native';
import { BlurView } from '@react-native-community/blur';

type BlurType =
  | 'light' | 'xlight' | 'dark' | 'extraDark'
  | 'regular' | 'prominent'
  | 'systemUltraThinMaterial' | 'systemThinMaterial' | 'systemMaterial'
  | 'systemThickMaterial' | 'systemChromeMaterial'
  | 'systemUltraThinMaterialLight' | 'systemThinMaterialLight' | 'systemMaterialLight'
  | 'systemThickMaterialLight' | 'systemChromeMaterialLight'
  | 'systemUltraThinMaterialDark' | 'systemThinMaterialDark' | 'systemMaterialDark'
  | 'systemThickMaterialDark' | 'systemChromeMaterialDark';

interface CrossPlatformBlurProps {
  style?: StyleProp<ViewStyle>;
  children?: React.ReactNode;
  /**
   * Blur intensity (0-100)
   * Default: 50
   */
  intensity?: number;
  /**
   * Blur tint - maps to blurType
   * 'dark' -> 'dark', 'light' -> 'light', 'extraLight' -> 'xlight'
   */
  tint?: 'dark' | 'light' | 'extraLight' | 'default';
  /**
   * Advanced: directly specify blurType for more control
   */
  blurType?: BlurType;
  /**
   * Fallback color for reduced transparency accessibility setting
   */
  reducedTransparencyFallbackColor?: string;
}

/**
 * A cross-platform blur component using @react-native-community/blur
 */
export function CrossPlatformBlur({
  style,
  children,
  intensity = 50,
  tint = 'dark',
  blurType: blurTypeProp,
  reducedTransparencyFallbackColor,
}: CrossPlatformBlurProps) {
  // Map tint to blurType if not explicitly provided
  const getBlurType = (): BlurType => {
    if (blurTypeProp) return blurTypeProp;

    switch (tint) {
      case 'light':
        return 'light';
      case 'extraLight':
        return 'xlight';
      case 'dark':
        return Platform.OS === 'ios' ? 'systemThinMaterialDark' : 'dark';
      default:
        return 'regular';
    }
  };

  // Map intensity (0-100) to blurAmount
  const blurAmount = Math.min(100, Math.max(0, intensity));

  const flatStyle = StyleSheet.flatten(style);

  return (
    <BlurView
      style={flatStyle}
      blurType={getBlurType()}
      blurAmount={blurAmount}
      reducedTransparencyFallbackColor={reducedTransparencyFallbackColor || 'rgba(25, 25, 25, 0.95)'}
    >
      {children}
    </BlurView>
  );
}
