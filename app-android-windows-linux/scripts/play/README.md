# Play Store release scripts

Direct Google Play Developer API integration. No fastlane, no gradle plugins,
just the REST API with a service-account JSON key.

## One-time setup

1. Create a service account in GCP project `homecast-483609` and download its JSON key.
2. In Play Console → Setup → API access: link the project, then grant the SA
   **Release manager** rights on the Homecast app.
3. Enable the API: `gcloud services enable androidpublisher.googleapis.com --project=homecast-483609`
4. Put the JSON key somewhere safe and set `PLAY_JSON_KEY` to its path.

## Build + upload to Internal track

```bash
cd app-android-windows-linux
export PLAY_JSON_KEY=~/.config/play/homecast-play-publisher.json
PLAY_NOTES="What's new in this release" npm run play:release
```

To target a different track: `PLAY_TRACK=beta npm run play:release`.

## Promote between tracks

```bash
PLAY_JSON_KEY=~/.config/play/homecast-play-publisher.json \
PLAY_VERSION_CODE=1001001 \
PLAY_FROM=internal PLAY_TO=production \
PLAY_NOTES="What's new" \
npm run play:promote
```

If the app is still in **Draft state** (initial launch hasn't been approved yet),
add `PLAY_DRAFT=1` — releases will be staged as `draft` until the app exits draft.

Staged rollout: add `PLAY_FRACTION=0.2` for 20%.

## Push store listing metadata + images

```bash
$VENV/bin/python scripts/play/listing.py \
  --json-key $PLAY_JSON_KEY \
  --package cloud.homecast.app
```

Listing copy lives inside `listing.py`. Images come from:
- icon-512 + feature-1024x500: `/tmp/play-assets/`
- screenshots: `app-ios-macos/screenshots/` (first 8 PNGs alphabetically)

## What you still have to do in the Play Console web UI

The Publisher API does NOT cover these — must be done manually:

- Content rating (IARC questionnaire)
- Data safety form
- Target audience & content (age, ads disclosure)
- App access (reviewer credentials for sign-in flows)
- Pre-launch testing requirement (12+ testers / 14 days for first-time launchers)
- Submit-for-review flow
