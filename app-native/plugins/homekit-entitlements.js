const { withEntitlementsPlist, withInfoPlist } = require('@expo/config-plugins');

/**
 * Expo config plugin to add required iOS HomeKit entitlements and usage description.
 *
 * This plugin:
 * 1. Adds the com.apple.developer.homekit entitlement
 * 2. Adds NSHomeKitUsageDescription to Info.plist
 *
 * Usage in app.json/app.config.ts:
 * {
 *   "plugins": ["./plugins/homekit-entitlements"]
 * }
 */
function withHomeKit(config) {
  // Add HomeKit entitlement
  config = withEntitlementsPlist(config, (config) => {
    config.modResults['com.apple.developer.homekit'] = true;
    return config;
  });

  // Add usage description
  config = withInfoPlist(config, (config) => {
    config.modResults.NSHomeKitUsageDescription =
      'Homecast needs access to your HomeKit devices to control them locally.';
    return config;
  });

  return config;
}

module.exports = withHomeKit;
