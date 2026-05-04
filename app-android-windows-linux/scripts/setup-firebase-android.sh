#!/usr/bin/env bash
#
# One-shot setup: register the Android app in Firebase and download the
# generated google-services.json into the Tauri Android source tree.
#
# Run this once per workstation (or whenever google-services.json is missing).
# Requires `firebase` CLI (already installed at /opt/homebrew/bin/firebase).
#
# Idempotent: skips creation if the Android app is already registered.
set -euo pipefail

PROJECT_ID="homecast-483609"
PACKAGE_NAME="cloud.homecast.app"
APP_DISPLAY_NAME="Homecast Android"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_PATH="${REPO_ROOT}/src-tauri/gen/android/app/google-services.json"

echo "==> Looking up Firebase Android app for ${PACKAGE_NAME}…"
APP_ID="$(firebase apps:list ANDROID --project "${PROJECT_ID}" --json 2>/dev/null \
  | python3 -c "
import json, sys
apps = json.load(sys.stdin).get('result', [])
for a in apps:
    if a.get('packageName') == '${PACKAGE_NAME}':
        print(a['appId'])
        break
" || true)"

if [[ -z "${APP_ID}" ]]; then
  echo "==> Not found — creating Android app…"
  APP_ID="$(firebase apps:create ANDROID "${APP_DISPLAY_NAME}" \
    --package-name "${PACKAGE_NAME}" \
    --project "${PROJECT_ID}" --json \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['appId'])")"
  echo "==> Created app ${APP_ID}"
else
  echo "==> Found existing app ${APP_ID}"
fi

echo "==> Writing ${OUT_PATH}…"
mkdir -p "$(dirname "${OUT_PATH}")"
firebase apps:sdkconfig ANDROID "${APP_ID}" \
  --project "${PROJECT_ID}" --out "${OUT_PATH}"

echo "==> Done. ${OUT_PATH}"
