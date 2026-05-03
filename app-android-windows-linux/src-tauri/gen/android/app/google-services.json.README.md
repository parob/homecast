# google-services.json (FCM)

This directory must contain `google-services.json` for FCM push notifications
to work in the Android build.

## How to generate it

1. Open the Firebase console: <https://console.firebase.google.com/project/homecast-483609/settings/general>
2. Add an Android app with package name `cloud.homecast.app` (skip if already
   added).
3. Download the generated `google-services.json` and save it next to this file:
   `src-tauri/gen/android/app/google-services.json`.

The file is **not a secret** — it embeds public Firebase project keys — but it
is auto-generated per-project, so it's not checked in. The build will fail
without it because the `com.google.gms.google-services` Gradle plugin enforces
its presence.
