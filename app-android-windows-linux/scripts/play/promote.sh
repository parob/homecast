#!/usr/bin/env bash
# Promote an existing versionCode from one Play track to another.
#
# Required env:
#   PLAY_JSON_KEY       service-account JSON path
#   PLAY_VERSION_CODE   versionCode to promote (e.g. 1001001)
#   PLAY_TO             destination track (alpha, beta, production)
#
# Optional env:
#   PLAY_FROM           source track (default: internal) — informational, used to verify
#   PLAY_FRACTION       staged rollout 0 < f < 1 (e.g. 0.2 for 20%)
#   PLAY_DRAFT          set to 1 if the app itself is in draft state
#   PLAY_NOTES          release notes
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENV="${PLAY_VENV:-$ROOT/scripts/play/.venv}"
KEY="${PLAY_JSON_KEY:?set PLAY_JSON_KEY}"
VC="${PLAY_VERSION_CODE:?set PLAY_VERSION_CODE}"
TO="${PLAY_TO:?set PLAY_TO (alpha|beta|production)}"
FROM="${PLAY_FROM:-internal}"

if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -r "$ROOT/scripts/play/requirements.txt"
fi

ARGS=(--json-key "$KEY" --package cloud.homecast.app --version-code "$VC" --from-track "$FROM" --to-track "$TO")
[ -n "${PLAY_FRACTION:-}" ] && ARGS+=(--user-fraction "$PLAY_FRACTION")
[ "${PLAY_DRAFT:-0}" = "1" ] && ARGS+=(--draft)
[ -n "${PLAY_NOTES:-}" ] && ARGS+=(--release-notes "$PLAY_NOTES")

"$VENV/bin/python" "$ROOT/scripts/play/promote.py" "${ARGS[@]}"
