// Apple Home App Color Palette
export const AppleHomeColors = {
  // Tab bar
  tabActive: '#30D158',
  tabInactive: 'rgba(255,255,255,0.6)',

  // Category chips
  climate: '#64D2FF',
  lights: '#FFD60A',
  security: '#0A84FF',

  // Tiles - green-tinted to match gradient background
  tileOff: 'rgba(120,180,120,0.35)',
  tileOnLight: 'rgba(255,220,80,0.5)',
  tileOnLock: 'rgba(0,132,255,0.4)',
  tileOnGreen: 'rgba(48,209,88,0.5)',

  // Text
  textPrimary: '#FFFFFF',
  textSecondary: 'rgba(255,255,255,0.7)',

  // Gradient background
  gradientColors: ['#87CEEB', '#90EE90', '#F5DEB3'] as readonly [string, string, string],

  // Service-specific icon colors
  lightbulb: '#FFD60A',
  lock: '#0A84FF',
  thermostat: '#FF9F0A',
  fan: '#64D2FF',
  switch: '#BF5AF2',
  outlet: '#30D158',
  sensor: '#5E5CE6',
};

const tintColorLight = '#30D158';
const tintColorDark = '#fff';

export default {
  light: {
    text: '#000',
    background: '#fff',
    tint: tintColorLight,
    tabIconDefault: 'rgba(255,255,255,0.6)',
    tabIconSelected: tintColorLight,
  },
  dark: {
    text: '#fff',
    background: '#000',
    tint: tintColorDark,
    tabIconDefault: 'rgba(255,255,255,0.6)',
    tabIconSelected: tintColorDark,
  },
};
