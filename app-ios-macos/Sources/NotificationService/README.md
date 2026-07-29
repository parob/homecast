# Notification Service Extension

Attaches the icon a Notify automation chose to a remote push. Without it, APNs
notifications arrive with title and body only — Apple never fetches an image on
its own.

The source here is complete. **The Xcode target is not created**, because adding
a target touches a dozen interlinked `project.pbxproj` sections and the failure
mode is silent: the app builds, ships, and simply has no extension inside it.
Create it in Xcode.

## Creating the target

1. **File → New → Target… → Notification Service Extension**
   - Product Name: `HomecastNotificationService`
   - Team: `3HMH4559WD` (same as the app)
   - Embed in Application: `Homecast`
   - Xcode will offer to activate a new scheme — decline; the app scheme builds it.
2. Xcode generates its own `NotificationService.swift` and `Info.plist` in a new
   group. **Delete both** (move to trash), then drag in the two files from this
   directory, with target membership set to the extension only.
3. In the extension target's Build Settings:
   - `PRODUCT_BUNDLE_IDENTIFIER` = `cloud.homecast.app.NotificationService`
   - `IPHONEOS_DEPLOYMENT_TARGET` = `16.0`
   - `MACOSX_DEPLOYMENT_TARGET` = `13.0`
   - `SUPPORTS_MACCATALYST` = `YES`
   - `CODE_SIGN_STYLE` = `Automatic`, `DEVELOPMENT_TEAM` = `3HMH4559WD`
   - `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` must match the app's, or
     App Store validation rejects the upload.
4. Confirm the app target's existing **Embed PlugIns** phase (`A1000050P`, which
   already carries `MenuBarPlugin.bundle`) now also lists the `.appex`.

Automatic signing registers the App ID and provisioning profile itself. An app
extension does **not** get its own App Store Connect record — it ships inside the
app bundle.

## Verifying

The extension only runs for pushes carrying `mutable-content: 1`, which the
server sets whenever a Notify action has an icon (`homecast/apns.py`).

Rich notifications **do not render in the simulator** — test on a real device.

```
# Confirm the .appex is actually embedded in the built app
ls "$(xcodebuild -project Homecast.xcodeproj -scheme Homecast \
  -destination 'platform=macOS,variant=Mac Catalyst' -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')/Homecast.app/Contents/PlugIns"
```

An empty result means step 4 did not take, and every push will silently arrive
without its icon.

## Ordering

This is the only part of the custom-icon feature gated on App Store review. The
relay Mac's local banner, the automation editor, and Android all work without
it, so it can land on its own.
