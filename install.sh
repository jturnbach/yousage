#!/bin/bash
# Build + install + relaunch YouSage. Use this for both first install and
# updates — it cleanly replaces /Applications/YouSage.app.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="/Applications/YouSage.app"
SRC="build/YouSage.app"

echo
echo "==> Quitting running YouSage (if any)"
osascript -e 'quit app "YouSage"' >/dev/null 2>&1 || true
# Wait up to ~3s for a graceful quit, then force.
for _ in 1 2 3 4 5 6; do
    if ! pgrep -x YouSage >/dev/null; then break; fi
    sleep 0.5
done
pkill -x YouSage 2>/dev/null || true

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Launching"
open "$DEST"
echo
echo "Done. YouSage should appear in your menu bar within a second or two."
