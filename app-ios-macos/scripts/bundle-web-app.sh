#!/bin/bash
# Bundle the web app into the Mac app's Resources for Community mode.
# Run this before building in Xcode, or add as a build phase script.
#
# Usage: ./scripts/bundle-web-app.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WEB_APP_DIR="$PROJECT_DIR/../app-web"
DEST_DIR="$PROJECT_DIR/Resources/web-dist"

echo "[bundle-web-app] Building web app..."
cd "$WEB_APP_DIR"
npm run build

echo "[bundle-web-app] Copying dist/ to Resources/web-dist/..."
rm -rf "$DEST_DIR"
cp -r "$WEB_APP_DIR/dist" "$DEST_DIR"

# Remove unnecessary files from the bundle
rm -rf "$DEST_DIR/.DS_Store"

echo "[bundle-web-app] Done. Web app bundled at: $DEST_DIR"
ls -lh "$DEST_DIR/assets/"
