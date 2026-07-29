# Notification Service Extension

Attaches the icon a Notify automation chose to a remote push. Without it, APNs
notifications arrive with title and body only — Apple never fetches an image on
its own, whatever the payload says.

The target exists (`HomecastNotificationService`, bundle id
`cloud.homecast.app.NotificationService`) and is embedded in the app's
**Embed PlugIns** phase alongside `MenuBarPlugin.bundle`.

## How it fires

The server sets `mutable-content: 1` and an `icon_url` on the APNs payload
whenever a Notify action has an icon (`homecast-cloud/server/homecast/apns.py`).
That flag is what wakes this extension for a few seconds before the banner is
shown; whatever it puts on the content is what the user sees.

Pushes with no icon carry no `mutable-content`, so the extension isn't invoked
at all — and a build without the extension ignores both the flag and the unread
custom key, which is why the server change could ship ahead of the app.

## The two rules in the code

1. The system allows roughly 30 seconds and then shows the notification whether
   we are finished or not. The download is bounded to 10s, and
   `serviceExtensionTimeWillExpire()` delivers whatever we have.
2. A notification without its icon beats no notification. Every failure path —
   bad URL, wrong scheme, non-image content type, oversized body, rejected
   attachment — still calls the content handler with usable content.

## Verifying after any project change

Adding a target touches a dozen interlinked `project.pbxproj` sections and the
failure mode is silent: the app builds, ships, and simply has no extension
inside it. So check the artifact, not the build log.

```bash
BP=$(xcodebuild -project Homecast.xcodeproj -scheme Homecast \
  -destination 'platform=macOS,variant=Mac Catalyst' -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
ls "$BP/Homecast.app/Contents/PlugIns"
plutil -p "$BP/Homecast.app/Contents/PlugIns/HomecastNotificationService.appex/Contents/Info.plist" \
  | grep -A3 NSExtension
```

Expect `HomecastNotificationService.appex` in the listing, and
`NSExtensionPointIdentifier => com.apple.usernotifications.service`. An empty or
missing PlugIns entry means every push will silently arrive without its icon.

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` must stay equal to the app's,
or App Store validation rejects the upload. They are set per-configuration in
the extension target, so a version bump has to touch them too — the app's
version is bumped in four places in `project.pbxproj`, and this target adds two
more.

## Still untested

Rich notifications **do not render in the simulator**. Nothing here has been
exercised against a real APNs delivery — that needs a signed build on a real
device, so treat the icon-on-push path as unverified until someone has seen one.
