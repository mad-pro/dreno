#!/bin/bash
# Builds Dreno.app (release, ad-hoc signed) and installs it to ~/Applications.
# Usage: scripts/build-app.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Dreno"
APP="$ROOT/build/$APP_NAME.app"
DEST="${DEST:-$HOME/Applications}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/processes.json "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
sed "s|__PROJECT_DIR__|$ROOT|g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"

if [ "${1:-}" = "--no-install" ]; then
  echo "Built: $APP"
  exit 0
fi

# Quit the running copy gracefully so an active recording is closed properly.
if pgrep -x "$APP_NAME" >/dev/null; then
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  sleep 1
  pkill -x "$APP_NAME" 2>/dev/null || true
fi
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP" "$DEST/"
echo "Installed: $DEST/$APP_NAME.app"
