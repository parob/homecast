#!/usr/bin/env bash
# Build a signed Android release AAB and upload it to a Play Store track.
#
# Required env:
#   PLAY_JSON_KEY    path to the service-account JSON for the Play Developer API
#
# Optional env:
#   PLAY_TRACK       internal | alpha | beta | production (default: internal)
#   PLAY_NOTES       release notes string (default: "")
#
# Usage:
#   PLAY_JSON_KEY=~/.config/play/key.json ./scripts/play/release.sh
#   PLAY_JSON_KEY=~/.config/play/key.json PLAY_TRACK=beta ./scripts/play/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TRACK="${PLAY_TRACK:-internal}"
NOTES="${PLAY_NOTES:-}"
KEY="${PLAY_JSON_KEY:?set PLAY_JSON_KEY to your service-account JSON path}"
VENV="${PLAY_VENV:-$ROOT/scripts/play/.venv}"

if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -r "$ROOT/scripts/play/requirements.txt"
fi

echo ">> Building signed release AAB..."
cd "$ROOT"
npx tauri android build --aab

AAB="$ROOT/src-tauri/gen/android/app/build/outputs/bundle/universalRelease/app-universal-release.aab"
[ -f "$AAB" ] || { echo "AAB missing at $AAB"; exit 1; }

echo ">> Uploading to Play (track=$TRACK)..."
"$VENV/bin/python" "$ROOT/scripts/play/upload.py" \
  --json-key "$KEY" \
  --package cloud.homecast.app \
  --aab "$AAB" \
  --track "$TRACK" \
  ${NOTES:+--release-notes "$NOTES"}
