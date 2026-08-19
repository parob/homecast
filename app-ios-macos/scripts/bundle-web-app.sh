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

# Finder junk, at every depth — the old rm only caught the top-level one.
find "$DEST_DIR" -name '.DS_Store' -delete

# cp -r carries extended attributes across, and files written under
# ~/Documents pick up com.apple.provenance from the sync daemon. codesign
# rejects a bundle carrying them ("resource fork, Finder information, or
# similar detritus not allowed"), so strip them rather than ship a bundle that
# might refuse to sign.
#
# Note this is not the whole story for that error: the same message comes from
# iCloud stamping com.apple.FinderInfo on build products, which is why
# -derivedDataPath must point outside ~/Documents. See CLAUDE.md.
xattr -cr "$DEST_DIR"

echo "[bundle-web-app] Done. Web app bundled at: $DEST_DIR"
ls -lh "$DEST_DIR/assets/"
